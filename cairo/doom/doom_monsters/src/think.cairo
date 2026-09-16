// SPDX-License-Identifier: GPL-2.0-only
//! `P_MobjThinker` for the things this crate owns, and the D3 scheduler
//! around it.
//!
//! One tic of one monster, in Doom's order: `P_XYMovement`, `P_ZMovement`,
//! then the state machine (`fsm::advance`) and — when the countdown entered
//! a new state — that state's **action id**, dispatched by a single `match`
//! (D15: Cairo has no function pointers, and an `if`-tree over ids costs 18
//! bytecode words per value against 1 for a table, S1 §5.9).

use doom_physics::maputl::{inc, opaque_zero, rd32};
use doom_physics::{
    Blocker, KIND_NONE, MAX_MOBJS, MF_COUNTKILL, MF_MISSILE, MF_SOLID, Mobj, MoveEvent, NO_MOBJ,
    PlayerDefense, ThingGrid, World, XyOutcome, explode_missile, maputl, removed_mobj,
    unset_thing_position, xy_movement, z_movement,
};
use doom_things::tables::{
    A_CHASE, A_FACETARGET, A_LOOK, A_POSATTACK, A_SARGATTACK, A_SPOSATTACK, A_TROOPATTACK,
    MI_DAMAGE,
};
use prng::Prng;
use super::actions::{
    a_chase_in, a_look_in, a_pos_attack_in, a_sarg_attack_in, a_spos_attack_in, a_troop_attack_in,
    face_boxed, hurt_in, run_passive,
};
use super::actors::{ACTOR, Actors, class_of, linked, patches_keep_classes, scan};
use super::event::{MonsterEvent, drain, missile_hit};
use super::{Ctx, Env, EnvData, Noise, Patch, WINDOW, env_of, read_boxed, read_mobj};

/// D3 fixes the look cadence at four: its phase is exactly the low two bits
/// for every u32, including the full clock range. See the paired divmod/mask
/// measurements in the crate README; this does not change the cadence.
#[inline(always)]
fn look_phase(value: u32) -> u32 {
    value & 3
}

/// How many actions may chain off one state change before the dispatcher
/// gives up. Doom's `P_SetMobjState` runs the action of every state it
/// enters, so `A_Look` → `seestate` → `A_Chase` → `missilestate` →
/// `A_FaceTarget` is a real (and the longest) chain on E1M1: three deep.
/// Four is the bound; nothing on the proving path may loop freely (D15).
pub const MAX_ACTION_CHAIN: u32 = 4;

/// True for a mobj this crate ticks: a monster (alive, dying or a corpse
/// still animating) or a missile in flight.
fn is_ours(mo: @Mobj) -> bool {
    let f = *mo.flags;
    doom_physics::has(f, MF_COUNTKILL) || doom_physics::has(f, MF_MISSILE)
}

/// A monster is **dormant** while the action of its current state is
/// `A_Look` — which is exactly `info.c`'s two-frame idle loop, for every one
/// of the five kinds. One `Span` read, no extra state, and it cannot be
/// fooled by `A_Look` having set `target` from a sound it then refused
/// (`MF_AMBUSH`).
pub fn is_dormant(w: World, mo: @Mobj) -> bool {
    rd32(w.states.action_id, *mo.state) == A_LOOK
}

/// A monster the round-robin window has to visit: alive, countable, awake.
pub fn is_awake(w: World, mo: @Mobj) -> bool {
    doom_physics::has(*mo.flags, MF_COUNTKILL) && *mo.health > 0 && !is_dormant(w, mo)
}

/// How many monsters the window has to share this tic. One pass over the
/// list reading three fields per slot; the ticker needs the total before it
/// can place anyone in the window, and the alternative (threading a cursor
/// through the state) would make the schedule depend on history rather than
/// on `tic` alone.
pub fn awake_count(w: World, mobjs: Span<Box<Mobj>>) -> u32 {
    // The action column is hoisted out of the loop and `is_awake` is spelled
    // out here (D24): passing the ~20-span `World` through a call boundary
    // once per mobj costs more than the test itself.
    let actions = w.states.action_id;
    let mut remaining = mobjs;
    let mut c: u32 = opaque_zero(mobjs.len());
    while let Option::Some(boxed) = remaining.pop_front() {
        let m = boxed.as_snapshot().unbox();
        if doom_physics::has(*m.flags, MF_COUNTKILL)
            && rd32(actions, *m.state) != A_LOOK
            && *m.health > 0 {
            c = inc(c);
        }
    }
    c
}

/// [`awake_count`] reading only the actor slots of the derived index (O1):
/// a monster is `MF_COUNTKILL`, so every awake monster is an actor, and a
/// removed slot is canonical (`removed_mobj`, enforced by the state reader)
/// so it never carries the flag. Same three fields, ~30 slots instead of 210.
pub fn awake_count_in(w: World, mobjs: Span<Box<Mobj>>, mut indices: Span<u32>) -> u32 {
    let actions = w.states.action_id;
    let mut c: u32 = opaque_zero(mobjs.len());
    while let Option::Some(bi) = indices.pop_front() {
        match mobjs.get(*bi) {
            Option::Some(b) => {
                let m = b.unbox().as_snapshot().unbox();
                if doom_physics::has(*m.flags, MF_COUNTKILL)
                    && rd32(actions, *m.state) != A_LOOK
                    && *m.health > 0 {
                    c = inc(c);
                }
            },
            Option::None => {},
        }
    }
    c
}

/// D3's round-robin: on tic `t`, the window is the [`WINDOW`] awake
/// monsters of rank `8t, 8t+1, … (mod n)` in list order.
///
/// Deterministic and stateless — it is a function of `tic` and of the awake
/// set at the **start** of the tic, so a segment restarted from a state hash
/// schedules exactly as the continuous run. Every awake monster is visited
/// within `ceil(n / 8)` tics, and when `n <= 8` everyone is visited every
/// tic (the window covers the whole set), i.e. vanilla.
pub fn in_window(rank: u32, tic: u32, n: u32) -> bool {
    if n <= WINDOW {
        return true;
    }
    // `n > WINDOW >= 1`, so the `NonZero` conversion always succeeds; the
    // `match` is what keeps the function without a panic site, and `8 t` is
    // folded in the field rather than through `u32`'s overflow-checked
    // multiplication (S7 §8 rule 1).
    let wide_n: u128 = n.into();
    let nz: NonZero<u128> = match wide_n.try_into() {
        Option::Some(v) => v,
        Option::None => 1,
    };
    let (_, start) = DivRem::div_rem(doom_physics::maputl::to_u128(WINDOW.into() * tic.into()), nz);
    let distance = doom_physics::maputl::to_u128(rank.into() + n.into() - start.into());
    let (_, k) = DivRem::div_rem(distance, nz);
    k < WINDOW.into()
}

/// Run one action id on `mo`, and return the action of the state it entered
/// (Doom's `P_SetMobjState` runs that one too), or `fsm::NO_ACTION`.
///
/// `may_look` and `may_chase` are the D3 gates: an `A_Look` that is not due
/// this tic and an `A_Chase` outside the window are skipped, and the monster
/// keeps counting down its idle or run frames as it would have.
fn dispatch(
    e: Env,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    action: u32,
    may_look: bool,
    may_chase: bool,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
    ref spawn_at: u32,
    ref defense: Box<PlayerDefense>,
) -> u32 {
    if action == A_CHASE {
        if !may_chase {
            return fsm::NO_ACTION;
        }
        return a_chase_in(e, mobjs, ref g, ref rng, ref mo, me, patches.span(), ref ev);
    }
    if action == A_LOOK {
        if !may_look {
            return fsm::NO_ACTION;
        }
        return a_look_in(e, mobjs, ref rng, ref mo, me, ref ev);
    }
    // The four attacks and `A_FaceTarget` need a target that is still in
    // the list; the read is hoisted out of their five arms.
    let target = mo.unbox().target;
    let aimed = target != NO_MOBJ && target < mobjs.len();
    if action == A_FACETARGET {
        if aimed {
            let t = read_boxed(mobjs, patches.span(), target);
            let mut m = mo.unbox();
            face_boxed(e.w.unbox().rndtable, ref rng, ref m, t);
            mo = BoxTrait::new(m);
        }
        return fsm::NO_ACTION;
    }
    if action == A_POSATTACK {
        if aimed {
            a_pos_attack_in(e, mobjs, ref g, ref rng, ref mo, me, ref patches, ref ev, ref defense);
        }
        return fsm::NO_ACTION;
    }
    if action == A_SPOSATTACK {
        if aimed {
            a_spos_attack_in(
                e, mobjs, ref g, ref rng, ref mo, me, ref patches, ref ev, ref defense,
            );
        }
        return fsm::NO_ACTION;
    }
    if action == A_TROOPATTACK {
        if aimed {
            a_troop_attack_in(
                e,
                mobjs,
                ref g,
                ref rng,
                ref mo,
                me,
                ref patches,
                ref ev,
                ref spawn_at,
                ref defense,
            );
        }
        return fsm::NO_ACTION;
    }
    if action == A_SARGATTACK {
        if aimed {
            a_sarg_attack_in(e, mobjs, ref rng, ref mo, me, ref patches, ref ev, ref defense);
        }
        return fsm::NO_ACTION;
    }
    // `A_Pain`, `A_Scream`, `A_XScream`, `A_Fall`: none of them changes the
    // state again. Everything else (the weapon and flash actions) belongs to
    // `doom_player` and is ignored here.
    let m = mo.unbox();
    if run_passive(e.w.unbox().rndtable, ref rng, m.kind, me, action, ref ev) {
        // `A_Fall`, the one passive action that writes anything.
        mo = BoxTrait::new(Mobj { flags: doom_physics::without(m.flags, MF_SOLID), ..m });
    }
    fsm::NO_ACTION
}

/// `P_SetMobjState`'s chain: run `action`, then the action of whatever state
/// it entered, up to [`MAX_ACTION_CHAIN`] deep.
fn run_chain(
    e: Env,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    action: u32,
    may_look: bool,
    may_chase: bool,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
    ref spawn_at: u32,
    ref defense: Box<PlayerDefense>,
) {
    let mut a = action;
    let mut depth: u32 = opaque_zero(action);
    while a != fsm::NO_ACTION && depth != MAX_ACTION_CHAIN {
        a =
            dispatch(
                e,
                mobjs,
                ref g,
                ref rng,
                ref mo,
                me,
                a,
                may_look,
                may_chase,
                ref patches,
                ref ev,
                ref spawn_at,
                ref defense,
            );
        depth = inc(depth);
    }
}

/// The state half of `P_MobjThinker`: one tic of countdown, the action of a
/// state it entered, and the single zero-tic hop `doom_things`'
/// `MAX_ZERO_TIC_CHAIN` allows.
fn think_state(
    e: Env,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    may_look: bool,
    may_chase: bool,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
    ref spawn_at: u32,
    ref defense: Box<PlayerDefense>,
) {
    let m0 = mo.unbox();
    if m0.tics == fsm::FOREVER {
        return;
    }
    let (state, tics, action) = fsm::advance(e.w.unbox().states, m0.state, m0.tics);
    mo = BoxTrait::new(Mobj { state, tics, ..m0 });
    run_chain(
        e,
        mobjs,
        ref g,
        ref rng,
        ref mo,
        me,
        action,
        may_look,
        may_chase,
        ref patches,
        ref ev,
        ref spawn_at,
        ref defense,
    );
    let m1 = mo.unbox();
    if m1.tics == 0 {
        let (s2, t2, a2) = fsm::advance(e.w.unbox().states, m1.state, 0);
        mo = BoxTrait::new(Mobj { state: s2, tics: t2, ..m1 });
        run_chain(
            e,
            mobjs,
            ref g,
            ref rng,
            ref mo,
            me,
            a2,
            may_look,
            may_chase,
            ref patches,
            ref ev,
            ref spawn_at,
            ref defense,
        );
    }
}

/// `P_MobjThinker` for one monster or missile: movement always, then the
/// state machine. Returns `false` when the mobj removed itself (`S_NULL`).
pub fn mobj_thinker(
    ctx: Ctx,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Mobj,
    me: u32,
    may_look: bool,
    may_chase: bool,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
    ref spawn_at: u32,
) -> bool {
    let mut defense = BoxTrait::new(doom_physics::no_player_defense());
    let mut b = BoxTrait::new(mo);
    let alive = mobj_thinker_in(
        env_of(ctx),
        mobjs,
        ref g,
        ref rng,
        ref b,
        me,
        may_look,
        may_chase,
        ref patches,
        ref ev,
        ref spawn_at,
        ref defense,
    );
    mo = b.unbox();
    alive
}

/// [`mobj_thinker`] on the narrow [`Env`].
pub(crate) fn mobj_thinker_in(
    e: Env,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    may_look: bool,
    may_chase: bool,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
    ref spawn_at: u32,
    ref defense: Box<PlayerDefense>,
) -> bool {
    let mut m = mo.unbox();
    let missile = doom_physics::has(m.flags, MF_MISSILE);
    // Momentum, in `P_MobjThinker`'s order and under its two guards: Doom
    // calls `P_XYMovement` only when there is momentum to spend (or a lost
    // soul in flight) and `P_ZMovement` only when the thing is off its floor
    // or moving vertically. D3 caps the *thinking*, never the physics — a
    // de-scheduled monster must not freeze in mid-fall — but a monster
    // standing still has no physics to run, and the guards are what keep a
    // dormant monster off `xy_movement`'s ~740 steps of argument plumbing on
    // every one of the 700 tics it spends asleep.
    let mut moves: Array<MoveEvent> = array![];
    let moving = m.momx != fixed::ZERO
        || m.momy != fixed::ZERO
        || doom_physics::has(m.flags, doom_physics::MF_SKULLFLY);
    let mut xy = XyOutcome::Moved;
    if moving {
        xy = xy_movement(e.w.unbox(), mobjs, ref g, ref m, me, false, false, ref moves);
        drain(moves.span(), me, ref ev);
    }
    let mut exploded = false;
    if missile {
        let hit = missile_hit(moves.span());
        if hit != NO_MOBJ {
            // `PIT_CheckThing` damages inline in C; the crate reports it, so
            // the draw happens here — still before anything else draws.
            let dmg_per: u32 = rd32(MI_DAMAGE.span(), m.kind);
            let eight: NonZero<u8> = 8;
            let draw = doom_physics::spawn::roll(ref rng, e.w.unbox().rndtable);
            let (_, low) = DivRem::div_rem(draw, eight);
            let r: u32 = low.into();
            // `hurt_in` writes a *patch* on another mobj, never on us, so
            // the actor need not be boxed around it.
            hurt_in(
                e,
                mobjs,
                ref rng,
                hit,
                me,
                m.target,
                scale(r, dmg_per),
                ref patches,
                ref ev,
                ref defense,
            );
        }
        match xy {
            XyOutcome::MissileHit(b) => {
                let _: Blocker = b;
                explode_missile(e.w.unbox(), ref rng, ref m);
                exploded = true;
            },
            _ => {},
        }
    }
    if !exploded && (m.z != m.floorz || m.momz != fixed::ZERO) {
        let z = z_movement(ref m, Option::None);
        if missile && z.missile_hit {
            explode_missile(e.w.unbox(), ref rng, ref m);
        }
    }
    mo = BoxTrait::new(m);
    // The state machine, with `A_Look` held back (see below).
    think_state(
        e,
        mobjs,
        ref g,
        ref rng,
        ref mo,
        me,
        false,
        may_chase,
        ref patches,
        ref ev,
        ref spawn_at,
        ref defense,
    );
    // **`A_Look` runs on the cadence, not on the frame.** Vanilla only
    // reaches `A_Look` when the two-frame idle loop turns over, which on
    // E1M1's roster is one tic in ten; gating *that* on `tic % 4 == id % 4`
    // as well would be worse than useless, because ten and four share a
    // factor — the transitions of a given monster only ever land on two of
    // the four phases, and half the roster would never look at all. D3 and
    // R2-A3 describe the S1 prototype's shape instead (`A_Look` attempted
    // every tic, run one tic in four, phased by id), so that is what the
    // cadence means here: a dormant monster looks on its own phase whatever
    // frame it is showing, and never twice on one tic. It is *more*
    // responsive than vanilla (every 4 tics rather than every 10) for a
    // quarter of the cost of looking every tic, and it draws no `P_Random`
    // unless it actually wakes, so the RNG stream is untouched.
    if may_look {
        run_chain(
            e,
            mobjs,
            ref g,
            ref rng,
            ref mo,
            me,
            A_LOOK,
            true,
            may_chase,
            ref patches,
            ref ev,
            ref spawn_at,
            ref defense,
        );
    }
    // `S_NULL` with `FOREVER` is Doom's "remove me".
    let done = mo.unbox();
    if done.state == 0 && done.tics == fsm::FOREVER {
        unset_thing_position(ref g, @done, me);
        return false;
    }
    true
}

/// Mutable data of a monster pass. Inactive slots carry only this pointer;
/// the full record is opened only when an actor actually runs its thinker.
#[derive(Destruct)]
struct Pass {
    grid: ThingGrid,
    rng: Prng,
    patches: Array<Patch>,
    events: Array<MonsterEvent>,
    spawn_at: u32,
    defense: Box<PlayerDefense>,
}

// Box has no built-in Destruct forwarding. Preserve ThingGrid's dictionary
// squash if a panic destroys a pass; the successful path unpacks it once.
impl BoxPassDestruct of Destruct<Box<Pass>> {
    fn destruct(self: Box<Pass>) nopanic {
        Destruct::destruct(self.unbox());
    }
}

fn tick_actor(
    e: Env,
    mobjs: Span<Box<Mobj>>,
    ref pass: Box<Pass>,
    mut mo: Box<Mobj>,
    me: u32,
    may_look: bool,
    may_chase: bool,
    look_only: bool,
) -> Box<Mobj> {
    let Pass {
        mut grid, mut rng, mut patches, mut events, mut spawn_at, mut defense,
    } = pass.unbox();
    if look_only {
        run_chain(
            e,
            mobjs,
            ref grid,
            ref rng,
            ref mo,
            me,
            A_LOOK,
            true,
            may_chase,
            ref patches,
            ref events,
            ref spawn_at,
            ref defense,
        );
    } else {
        let alive = mobj_thinker_in(
            e,
            mobjs,
            ref grid,
            ref rng,
            ref mo,
            me,
            may_look,
            may_chase,
            ref patches,
            ref events,
            ref spawn_at,
            ref defense,
        );
        if !alive {
            mo = BoxTrait::new(removed_mobj());
        }
    }
    pass = BoxTrait::new(Pass { grid, rng, patches, events, spawn_at, defense });
    mo
}

/// Copy the passive run `[from, to)` — the front of `remaining` is slot
/// `from` — with only the cursor and the output live: one pointer per slot,
/// no classification (the index already did it). `Span::slice` would be a
/// panic site; this loop has none, and it stops at the end of the list.
#[inline(never)]
fn copy_run(ref remaining: Span<Box<Mobj>>, ref out: Array<Box<Mobj>>, from: u32, to: u32) {
    let mut k = from;
    while k != to {
        match remaining.pop_front() {
            Option::Some(b) => { out.append(*b); },
            Option::None => { break; },
        }
        k = inc(k);
    }
}

// Copy a passive run with only its cursor and output live.
// Return the next actor without changing its slot index or record.
//
// This is the **definition** of the actor set (`is_ours` on a live slot)
// that `actors::scan` derives and the tests compare it with; the ticker
// itself no longer classifies the list (O1).
#[inline(never)]
pub(crate) fn next_actor(
    ref remaining: Span<Box<Mobj>>, ref out: Array<Box<Mobj>>,
) -> Option<@Box<Mobj>> {
    loop {
        match remaining.pop_front() {
            Option::Some(boxed) => {
                if boxed.kind == KIND_NONE
                    || !doom_physics::has(boxed.flags, MF_COUNTKILL + MF_MISSILE) {
                    out.append(*boxed);
                } else {
                    break Option::Some(boxed);
                }
            },
            Option::None => { break Option::None; },
        }
    }
}

/// One tic of every monster and missile in `mobjs`, under the D3 schedule.
///
/// `actors` is the derived index of `mobjs` (O1): the ticker visits only
/// its slots, in order, and copies the passive runs between them by
/// pointer. Returns the rebuilt list, the advanced RNG, the tic's events
/// and the index of the rebuilt list — the same index when no slot changed
/// class, a fresh [`scan`] otherwise. The thing grid is updated in place;
/// its canonical order is hashed (schema 2).
fn monsters_ticker_in(
    w: World,
    mobjs: Span<Box<Mobj>>,
    actors: Actors,
    ref g: ThingGrid,
    players: Span<u32>,
    noise: Noise,
    tic: u32,
    rng: Prng,
    ref defense: Box<PlayerDefense>,
) -> (Array<Box<Mobj>>, Prng, Array<MonsterEvent>, Actors) {
    let e = BoxTrait::new(EnvData { w: BoxTrait::new(w), players, noise, tic });
    let mut out: Array<Box<Mobj>> = array![];
    let n = mobjs.len();
    let awake = awake_count_in(w, mobjs, actors.indices);
    // Where a missile spawned this tic goes: a freed slot if there is one,
    // otherwise the end of the list. Only an awake monster can fire; the
    // free slot is read off the index (it used to be a scan of the list).
    let mut spawn_at = n;
    if awake != 0 && actors.first_free != NO_MOBJ {
        spawn_at = actors.first_free;
    }
    let mut pass = BoxTrait::new(
        Pass { grid: g, rng, patches: array![], events: array![], spawn_at, defense },
    );
    let phase_now = look_phase(tic);
    // The classification below is `is_awake` and `is_dormant` spelled out
    // (D24), reading the two state columns *through the boxed world*: a
    // `let` here would put the twelve felts of `StateTables` and its action
    // column in the loop's live set, and a loop is a function whose live
    // set is pushed and returned on every iteration (S7 §8 rule 4). A read
    // through the box is free.
    let mut rank: u32 = opaque_zero(n);
    let mut remaining = mobjs;
    let mut indices = actors.indices;
    let mut from: u32 = opaque_zero(n);
    // Set once an actor left its class this tic (removed itself, or a
    // missile exploded): the index is rebuilt from the final list.
    let mut dirty = false;
    // Keep the one-felt box live across branches and calls. A named @Mobj
    // snapshot here makes Cairo preserve 27 felts even on unchanged slots.
    while let Option::Some(bi) = indices.pop_front() {
        let i = *bi;
        copy_run(ref remaining, ref out, from, i);
        // The actor's own record; an index past the list ends the pass.
        let boxed = match remaining.pop_front() {
            Option::Some(b) => b,
            Option::None => { break; },
        };
        from = inc(i);
        let flags = boxed.flags;
        let countkill = doom_physics::has(flags, MF_COUNTKILL);
        let dormant = countkill && rd32(e.w.unbox().states.action_id, boxed.state) == A_LOOK;
        let mut may_chase = true;
        if countkill && !dormant && boxed.health > 0 {
            may_chase = in_window(rank, tic, awake);
            rank = inc(rank);
        }
        let phase = look_phase(i);
        let may_look = dormant && phase == phase_now;
        // **The dormant fast path.** A monster asleep with no momentum, on
        // its floor and not due to look has exactly one thing left to do
        // this tic: count its idle frame down. Doing it here rather than
        // through `mobj_thinker` skips four call boundaries that each copy
        // the ~60-felt `World` inside `Ctx` (the same argument-plumbing tax
        // the `doom_physics` README measures at ~740 steps a call), and it
        // is the path 29 of E1M1's 30 monsters are on for most of a run.
        // The suppressed action can only be `A_Look` — that *is* what makes
        // the monster dormant — so nothing is lost.
        if dormant
            && boxed.momx == fixed::ZERO
            && boxed.momy == fixed::ZERO
            && boxed.momz == fixed::ZERO
            && boxed.z == boxed.floorz {
            let (st, tc) = if boxed.tics != fsm::FOREVER {
                let (st, tc, _) = fsm::advance(e.w.unbox().states, boxed.state, boxed.tics);
                (st, tc)
            } else {
                (boxed.state, boxed.tics)
            };
            if !may_look {
                // Reuse an unchanged record (including FOREVER). A changed
                // countdown still allocates its 27 fields, then one pointer.
                out
                    .append(
                        if st == boxed.state && tc == boxed.tics {
                            *boxed
                        } else {
                            BoxTrait::new(Mobj { state: st, tics: tc, ..boxed.unbox() })
                        },
                    );
                continue;
            }
            let b = tick_actor(
                e,
                mobjs,
                ref pass,
                BoxTrait::new(Mobj { state: st, tics: tc, ..boxed.unbox() }),
                i,
                true,
                may_chase,
                true,
            );
            if !keeps_class(@b, flags, boxed.cell) {
                dirty = true;
            }
            out.append(b);
            continue;
        }
        let b = tick_actor(e, mobjs, ref pass, *boxed, i, may_look, may_chase, false);
        if !keeps_class(@b, flags, boxed.cell) {
            dirty = true;
        }
        out.append(b);
    }
    copy_run(ref remaining, ref out, from, n);
    let Pass { grid, rng, patches, events, spawn_at: _, defense: final_defense } = pass.unbox();
    g = grid;
    defense = final_defense;
    let final_list = apply(out, patches.span(), n);
    // The index survives the tic iff every visited actor is still one and
    // every patch (a damaged mobj, a spawned missile) kept its slot's class.
    let index = if !dirty && patches_keep_classes(mobjs, patches.span()) {
        actors
    } else {
        scan(final_list.span())
    };
    (final_list, rng, events, index)
}

/// Whether a ticked actor kept its slot class: it is still an actor — it
/// may have removed itself (`S_NULL`) or, for a missile, exploded
/// (`P_ExplodeMissile` clears `MF_MISSILE`) — and it is linked in the
/// blockmap iff it was before the tic (`flags`, `cell`: it may have walked
/// off the grid). Three field reads through the box.
#[inline(always)]
fn keeps_class(b: @Box<Mobj>, flags: u32, cell: u32) -> bool {
    class_of(b.kind, b.flags) == ACTOR && linked(b.flags, b.cell) == linked(flags, cell)
}

/// Write the tic's backward patches (damaged mobjs, spawned missiles) into
/// the rebuilt list in one pass — the physics README's "batch such patches
/// and apply them in one rebuild at the end of the tic" — and append the
/// ones that claimed a new slot. A tic with no patch pays nothing.
fn apply(out: Array<Box<Mobj>>, patches: Span<Patch>, n: u32) -> Array<Box<Mobj>> {
    let np = patches.len();
    if np == 0 {
        return out;
    }
    let src = out.span();
    let mut res: Array<Box<Mobj>> = array![];
    let mut i: u32 = opaque_zero(n);
    // The per-slot scan *is* `read_mobj`'s (S7 §8 rule 6: one shared helper
    // out of line rather than the same loop written twice).
    while i != n {
        res.append(read_mobj(src, patches, i));
        i = inc(i);
    }
    let mut k: u32 = opaque_zero(np);
    while k != np {
        match patches.get(k) {
            Option::Some(b) => {
                let p = *b.unbox();
                if p.idx >= n && res.len() < MAX_MOBJS {
                    res.append(p.mo);
                }
            },
            Option::None => {},
        }
        k = inc(k);
    }
    res
}

/// `(r + 1) * mul`, the shape of every damage roll of `p_enemy.c`, in the
/// field: `u32`'s `+` and `*` both carry an overflow panic path, and both
/// operands here are bounded by a table (S7 §8 rule 1).
#[inline(always)]
pub(crate) fn scale(r: u32, mul: u32) -> u32 {
    maputl::low32(doom_physics::maputl::to_u128((r.into() + 1) * mul.into()))
}

/// Compatibility entry point: no player-specific damage bookkeeping, and
/// the actor index derived from the list on the spot.
#[inline(always)]
pub fn monsters_ticker(
    w: World,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    players: Span<u32>,
    noise: Noise,
    tic: u32,
    rng: Prng,
) -> (Array<Box<Mobj>>, Prng, Array<MonsterEvent>) {
    let mut defense = BoxTrait::new(doom_physics::no_player_defense());
    let (list, rng, events, _) = monsters_ticker_in(
        w, mobjs, scan(mobjs), ref g, players, noise, tic, rng, ref defense,
    );
    (list, rng, events)
}

/// The same ordered ticker with player armor applied before each health,
/// pain and death decision. Its patches expose the net health to later actors.
#[inline(always)]
pub fn monsters_ticker_with_defense(
    w: World,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    players: Span<u32>,
    noise: Noise,
    tic: u32,
    rng: Prng,
    ref defense: PlayerDefense,
) -> (Array<Box<Mobj>>, Prng, Array<MonsterEvent>) {
    let (list, rng, events, _) = monsters_ticker_indexed(
        w, mobjs, scan(mobjs), ref g, players, noise, tic, rng, ref defense,
    );
    (list, rng, events)
}

/// [`monsters_ticker_with_defense`] carrying the derived actor index across
/// tics (O1): `actors` must be `scan(mobjs)`, and the returned index is the
/// one of the returned list. This is `doom_game`'s entry point.
#[inline(always)]
pub fn monsters_ticker_indexed(
    w: World,
    mobjs: Span<Box<Mobj>>,
    actors: Actors,
    ref g: ThingGrid,
    players: Span<u32>,
    noise: Noise,
    tic: u32,
    rng: Prng,
    ref defense: PlayerDefense,
) -> (Array<Box<Mobj>>, Prng, Array<MonsterEvent>, Actors) {
    let mut boxed = BoxTrait::new(defense);
    let out = monsters_ticker_in(w, mobjs, actors, ref g, players, noise, tic, rng, ref boxed);
    defense = boxed.unbox();
    out
}

#[cfg(test)]
mod passive_run_tests {
    use super::{KIND_NONE, MF_COUNTKILL, MF_MISSILE, Mobj, next_actor, removed_mobj};

    #[test]
    fn interleaved_runs_keep_original_actor_slots_and_all_records() {
        let passive = BoxTrait::new(Mobj { kind: 17, flags: 0, ..removed_mobj() });
        // Removed slots must stay passive even for a direct, noncanonical caller.
        let removed = BoxTrait::new(Mobj { flags: MF_COUNTKILL, ..removed_mobj() });
        let missile = BoxTrait::new(Mobj { kind: 1, flags: MF_MISSILE, ..removed_mobj() });
        let monster = BoxTrait::new(Mobj { kind: 2, flags: MF_COUNTKILL, ..removed_mobj() });
        let original = array![passive, removed, missile, passive, monster, passive];
        let mut remaining = original.span();
        let mut out = array![];
        let first = next_actor(ref remaining, ref out).unwrap();
        assert_eq!(out.len(), 2);
        assert_eq!(first.unbox(), missile.unbox());
        out.append(*first);
        let second = next_actor(ref remaining, ref out).unwrap();
        assert_eq!(out.len(), 4);
        assert_eq!(second.unbox(), monster.unbox());
        out.append(*second);
        assert!(next_actor(ref remaining, ref out).is_none());
        assert_eq!(out.len(), original.len());
        let mut expected = original.span();
        let mut actual = out.span();
        while let Option::Some(e) = expected.pop_front() {
            assert_eq!(actual.pop_front().unwrap().unbox(), e.unbox());
        }
        assert!(actual.is_empty());
    }

    #[test]
    fn empty_and_fully_passive_rosters_are_copied_without_an_actor() {
        let mut remaining = array![].span();
        let mut out: Array<Box<Mobj>> = array![];
        assert!(next_actor(ref remaining, ref out).is_none());
        assert!(out.is_empty());
        let removed = BoxTrait::new(removed_mobj());
        remaining = array![removed, removed].span();
        assert!(next_actor(ref remaining, ref out).is_none());
        assert_eq!(out.len(), 2);
        assert_eq!(out.at(0).kind, KIND_NONE);
        assert_eq!(out.at(1).kind, KIND_NONE);
    }
}

#[cfg(test)]
mod phase_tests {
    use core::num::traits::{WrappingAdd, WrappingSub};
    use super::look_phase;

    #[test]
    fn phase_matches_division_across_slot_and_clock_boundaries() {
        assert_eq!(crate::LOOK_CADENCE, 4);
        // Every roster index, plus every phase around each u32 power of two.
        // The reference uses integer division, independently of the mask.
        let mut value: u32 = 0;
        while value <= 256 {
            assert_eq!(look_phase(value), value % 4);
            value += 1;
        }
        let mut power: u32 = 1;
        let mut bit: u32 = 0;
        while bit < 32 {
            let mut offset: u32 = 0;
            while offset < 8 {
                let below = power.wrapping_sub(offset);
                let above = power.wrapping_add(offset);
                assert_eq!(look_phase(below), below % 4);
                assert_eq!(look_phase(above), above % 4);
                offset += 1;
            }
            power = power.wrapping_add(power);
            bit += 1;
        }
    }
}

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
    ThingGrid, World, XyOutcome, explode_missile, first_free, maputl, removed_mobj,
    unset_thing_position, xy_movement, z_movement,
};
use doom_things::tables::{
    A_CHASE, A_FACETARGET, A_LOOK, A_POSATTACK, A_SARGATTACK, A_SPOSATTACK, A_TROOPATTACK,
    MI_DAMAGE,
};
use prng::Prng;
use super::actions::{
    a_chase_in, a_look_in, a_pos_attack_in, a_sarg_attack_in, a_spos_attack_in, a_troop_attack_in,
    face_target, hurt_in, run_passive,
};
use super::event::{MonsterEvent, drain, missile_hit};
use super::{Ctx, Env, Noise, Patch, WINDOW, env_of, mobj_at, read_mobj};

/// [`super::LOOK_CADENCE`] as a `NonZero` literal: `%` on a `u32` keeps a "division
/// by zero" panic path that the compiler does not fold away, even against a
/// constant divisor (S7 §8 rule 1).
const CADENCE: NonZero<u32> = 4;

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
pub fn awake_count(w: World, mobjs: Span<Mobj>) -> u32 {
    // The action column is hoisted out of the loop and `is_awake` is spelled
    // out here (D24): passing the ~20-span `World` through a call boundary
    // once per mobj costs more than the test itself.
    let actions = w.states.action_id;
    let n = mobjs.len();
    // `opaque_zero`, not `0`: a literal as a loop-carried start makes the
    // compiler emit a second, specialised copy of the loop body (S7 §8
    // rule 4). `get` + `match` and `inc` keep the pass panic-free (rule 1).
    let mut i: u32 = opaque_zero(n);
    let mut c: u32 = opaque_zero(n);
    while i != n {
        match mobjs.get(i) {
            Option::Some(b) => {
                let m = b.unbox();
                // In this order: the bit test is the cheapest and rejects
                // everything that is not a monster, the state test rejects
                // every sleeper (the common case), and the signed `health`
                // comparison — the dear one — runs only for the few that
                // are left.
                if doom_physics::has(*m.flags, MF_COUNTKILL)
                    && rd32(actions, *m.state) != A_LOOK
                    && *m.health > 0 {
                    c = inc(c);
                }
            },
            Option::None => {},
        }
        i = inc(i);
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
    let nz: NonZero<u32> = match n.try_into() {
        Option::Some(v) => v,
        Option::None => 1,
    };
    let (_, start) = DivRem::div_rem(maputl::low32(fixed::to_u128(WINDOW.into() * tic.into())), nz);
    let (_, k) = DivRem::div_rem(maputl::add32(maputl::sub32(rank, start), n), nz);
    k < WINDOW
}

/// Run one action id on `mo`, and return the action of the state it entered
/// (Doom's `P_SetMobjState` runs that one too), or `fsm::NO_ACTION`.
///
/// `may_look` and `may_chase` are the D3 gates: an `A_Look` that is not due
/// this tic and an `A_Chase` outside the window are skipped, and the monster
/// keeps counting down its idle or run frames as it would have.
fn dispatch(
    e: Env,
    mobjs: Span<Mobj>,
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
            let t = read_mobj(mobjs, patches.span(), target);
            let mut m = mo.unbox();
            face_target(e.w.unbox().rndtable, ref rng, ref m, @t);
            mo = BoxTrait::new(m);
        }
        return fsm::NO_ACTION;
    }
    if action == A_POSATTACK {
        if aimed {
            a_pos_attack_in(e, mobjs, ref g, ref rng, ref mo, me, ref patches, ref ev);
        }
        return fsm::NO_ACTION;
    }
    if action == A_SPOSATTACK {
        if aimed {
            a_spos_attack_in(e, mobjs, ref g, ref rng, ref mo, me, ref patches, ref ev);
        }
        return fsm::NO_ACTION;
    }
    if action == A_TROOPATTACK {
        if aimed {
            a_troop_attack_in(
                e, mobjs, ref g, ref rng, ref mo, me, ref patches, ref ev, ref spawn_at,
            );
        }
        return fsm::NO_ACTION;
    }
    if action == A_SARGATTACK {
        if aimed {
            a_sarg_attack_in(e, mobjs, ref rng, ref mo, me, ref patches, ref ev);
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
    mobjs: Span<Mobj>,
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
            );
        depth = inc(depth);
    }
}

/// The state half of `P_MobjThinker`: one tic of countdown, the action of a
/// state it entered, and the single zero-tic hop `doom_things`'
/// `MAX_ZERO_TIC_CHAIN` allows.
fn think_state(
    e: Env,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    may_look: bool,
    may_chase: bool,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
    ref spawn_at: u32,
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
        );
    }
}

/// `P_MobjThinker` for one monster or missile: movement always, then the
/// state machine. Returns `false` when the mobj removed itself (`S_NULL`).
pub fn mobj_thinker(
    ctx: Ctx,
    mobjs: Span<Mobj>,
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
    );
    mo = b.unbox();
    alive
}

/// [`mobj_thinker`] on the narrow [`Env`].
pub(crate) fn mobj_thinker_in(
    e: Env,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    may_look: bool,
    may_chase: bool,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
    ref spawn_at: u32,
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
            hurt_in(e, mobjs, ref rng, hit, me, m.target, scale(r, dmg_per), ref patches, ref ev);
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
        e, mobjs, ref g, ref rng, ref mo, me, false, may_chase, ref patches, ref ev, ref spawn_at,
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

/// One tic of every monster and missile in `mobjs`, under the D3 schedule.
///
/// Returns the rebuilt list, the advanced RNG and the tic's events. The
/// thing grid is updated in place (it is derived data and is not hashed).
pub fn monsters_ticker(
    w: World,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    players: Span<u32>,
    noise: Noise,
    tic: u32,
    rng: Prng,
) -> (Array<Mobj>, Prng, Array<MonsterEvent>) {
    let e = Env { w: BoxTrait::new(w), players, noise, tic };
    let mut r = rng;
    let mut ev: Array<MonsterEvent> = array![];
    let mut patches: Array<Patch> = array![];
    let mut out: Array<Mobj> = array![];
    let n = mobjs.len();
    let awake = awake_count(w, mobjs);
    // Where a missile spawned this tic goes: a freed slot if there is one,
    // otherwise the end of the list. Only an awake monster can fire, and
    // `first_free` unboxes every slot of the list, so a tic with nothing
    // awake does not pay for it.
    let mut spawn_at = n;
    if awake != 0 {
        let free = first_free(mobjs);
        if free != NO_MOBJ {
            spawn_at = free;
        }
    }
    let (_, look_phase) = DivRem::div_rem(tic, CADENCE);
    // Hoisted out of the loop (D24): the classification below is `is_ours`,
    // `is_awake` and `is_dormant` spelled out, so that the ~20-span `World`
    // does not cross a call boundary once per mobj per tic.
    let states = w.states;
    let actions = states.action_id;
    let mut i: u32 = opaque_zero(n);
    let mut rank: u32 = opaque_zero(n);
    while i != n {
        // The classification reads the slot through the list's snapshot;
        // the 27 felts are materialised only where the mobj is about to be
        // written, which is one copy per slot per tic instead of two
        // (S7 §8 rule 3 applied to the ticker's own pass).
        let m = match mobjs.get(i) {
            Option::Some(b) => b.unbox(),
            Option::None => { break; },
        };
        let flags = *m.flags;
        let countkill = doom_physics::has(flags, MF_COUNTKILL);
        if *m.kind == KIND_NONE || !(countkill || doom_physics::has(flags, MF_MISSILE)) {
            out.append(*m);
            i = inc(i);
            continue;
        }
        let dormant = countkill && rd32(actions, *m.state) == A_LOOK;
        let mut may_chase = true;
        if countkill && !dormant && *m.health > 0 {
            may_chase = in_window(rank, tic, awake);
            rank = inc(rank);
        }
        let (_, phase) = DivRem::div_rem(i, CADENCE);
        let may_look = dormant && phase == look_phase;
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
            && *m.momx == fixed::ZERO
            && *m.momy == fixed::ZERO
            && *m.momz == fixed::ZERO
            && *m.z == *m.floorz {
            let (st, tc) = if *m.tics != fsm::FOREVER {
                let (st, tc, _) = fsm::advance(states, *m.state, *m.tics);
                (st, tc)
            } else {
                (*m.state, *m.tics)
            };
            if !may_look {
                // Nothing else to do this tic: the countdown goes straight
                // into the rebuilt list, one 27-felt write and no copy.
                out.append(Mobj { state: st, tics: tc, ..*m });
                i = inc(i);
                continue;
            }
            let mut b = BoxTrait::new(Mobj { state: st, tics: tc, ..*m });
            run_chain(
                e,
                mobjs,
                ref g,
                ref r,
                ref b,
                i,
                A_LOOK,
                true,
                may_chase,
                ref patches,
                ref ev,
                ref spawn_at,
            );
            out.append(b.unbox());
            i = inc(i);
            continue;
        }
        let mut b = BoxTrait::new(*m);
        let alive = mobj_thinker_in(
            e,
            mobjs,
            ref g,
            ref r,
            ref b,
            i,
            may_look,
            may_chase,
            ref patches,
            ref ev,
            ref spawn_at,
        );
        if alive {
            out.append(b.unbox());
        } else {
            out.append(removed_mobj());
        }
        i = inc(i);
    }
    let final_list = apply(out, patches.span(), n);
    (final_list, r, ev)
}

/// Write the tic's backward patches (damaged mobjs, spawned missiles) into
/// the rebuilt list in one pass — the physics README's "batch such patches
/// and apply them in one rebuild at the end of the tic" — and append the
/// ones that claimed a new slot. A tic with no patch pays nothing.
fn apply(out: Array<Mobj>, patches: Span<Patch>, n: u32) -> Array<Mobj> {
    let np = patches.len();
    if np == 0 {
        return out;
    }
    let src = out.span();
    let mut res: Array<Mobj> = array![];
    let mut i: u32 = opaque_zero(n);
    while i != n {
        let mut m = mobj_at(src, i);
        let mut k: u32 = opaque_zero(np);
        while k != np {
            match patches.get(k) {
                Option::Some(b) => {
                    let p = *b.unbox();
                    if p.idx == i {
                        m = p.mo;
                    }
                },
                Option::None => {},
            }
            k = inc(k);
        }
        res.append(m);
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
    maputl::low32(fixed::to_u128((r.into() + 1) * mul.into()))
}

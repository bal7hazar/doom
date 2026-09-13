// SPDX-License-Identifier: GPL-2.0-only
//! `P_MobjThinker` for the things this crate owns, and the D3 scheduler
//! around it.
//!
//! One tic of one monster, in Doom's order: `P_XYMovement`, `P_ZMovement`,
//! then the state machine (`fsm::advance`) and — when the countdown entered
//! a new state — that state's **action id**, dispatched by a single `match`
//! (D15: Cairo has no function pointers, and an `if`-tree over ids costs 18
//! bytecode words per value against 1 for a table, S1 §5.9).

use doom_physics::{
    Blocker, MAX_MOBJS, MF_COUNTKILL, MF_MISSILE, Mobj, MoveEvent, NO_MOBJ, ThingGrid, World,
    XyOutcome, explode_missile, first_free, is_removed, removed_mobj, unset_thing_position,
    xy_movement, z_movement,
};
use doom_things::tables::{
    A_CHASE, A_FACETARGET, A_LOOK, A_POSATTACK, A_SARGATTACK, A_SPOSATTACK, A_TROOPATTACK,
    MI_DAMAGE,
};
use prng::{Prng, PrngTrait};
use super::actions::{
    a_chase, a_face_target, a_look, a_pos_attack, a_sarg_attack, a_spos_attack, a_troop_attack,
    hurt, passive,
};
use super::event::{MonsterEvent, drain, missile_hit};
use super::{Ctx, LOOK_CADENCE, Noise, Patch, WINDOW, read_mobj};

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
    *w.states.action_id.at(*mo.state) == A_LOOK
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
    let n = mobjs.len();
    let mut i: u32 = 0;
    let mut c: u32 = 0;
    while i != n {
        if is_awake(w, mobjs.at(i)) {
            c += 1;
        }
        i += 1;
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
    let start = (WINDOW * tic) % n;
    (rank + n - start) % n < WINDOW
}

/// Run one action id on `mo`, and return the action of the state it entered
/// (Doom's `P_SetMobjState` runs that one too), or `fsm::NO_ACTION`.
///
/// `may_look` and `may_chase` are the D3 gates: an `A_Look` that is not due
/// this tic and an `A_Chase` outside the window are skipped, and the monster
/// keeps counting down its idle or run frames as it would have.
fn dispatch(
    ctx: Ctx,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Mobj,
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
        return a_chase(ctx, mobjs, ref g, ref rng, ref mo, me, patches.span(), ref ev);
    }
    if action == A_LOOK {
        if !may_look {
            return fsm::NO_ACTION;
        }
        return a_look(ctx, mobjs, ref rng, ref mo, me, ref ev);
    }
    if action == A_FACETARGET {
        if mo.target != NO_MOBJ && mo.target < mobjs.len() {
            let t = read_mobj(mobjs, patches.span(), mo.target);
            a_face_target(ctx, ref rng, ref mo, @t);
        }
        return fsm::NO_ACTION;
    }
    if action == A_POSATTACK {
        if mo.target != NO_MOBJ && mo.target < mobjs.len() {
            a_pos_attack(ctx, mobjs, ref g, ref rng, ref mo, me, ref patches, ref ev);
        }
        return fsm::NO_ACTION;
    }
    if action == A_SPOSATTACK {
        if mo.target != NO_MOBJ && mo.target < mobjs.len() {
            a_spos_attack(ctx, mobjs, ref g, ref rng, ref mo, me, ref patches, ref ev);
        }
        return fsm::NO_ACTION;
    }
    if action == A_TROOPATTACK {
        if mo.target != NO_MOBJ && mo.target < mobjs.len() {
            a_troop_attack(
                ctx, mobjs, ref g, ref rng, ref mo, me, ref patches, ref ev, ref spawn_at,
            );
        }
        return fsm::NO_ACTION;
    }
    if action == A_SARGATTACK {
        if mo.target != NO_MOBJ && mo.target < mobjs.len() {
            a_sarg_attack(ctx, mobjs, ref rng, ref mo, me, ref patches, ref ev);
        }
        return fsm::NO_ACTION;
    }
    // `A_Pain`, `A_Scream`, `A_XScream`, `A_Fall`: none of them changes the
    // state again. Everything else (the weapon and flash actions) belongs to
    // `doom_player` and is ignored here.
    passive(ctx, ref rng, ref mo, me, action, ref ev);
    fsm::NO_ACTION
}

/// `P_SetMobjState`'s chain: run `action`, then the action of whatever state
/// it entered, up to [`MAX_ACTION_CHAIN`] deep.
fn run_chain(
    ctx: Ctx,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Mobj,
    me: u32,
    action: u32,
    may_look: bool,
    may_chase: bool,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
    ref spawn_at: u32,
) {
    let mut a = action;
    let mut depth: u32 = 0;
    while a != fsm::NO_ACTION && depth != MAX_ACTION_CHAIN {
        a =
            dispatch(
                ctx,
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
        depth += 1;
    }
}

/// The state half of `P_MobjThinker`: one tic of countdown, the action of a
/// state it entered, and the single zero-tic hop `doom_things`'
/// `MAX_ZERO_TIC_CHAIN` allows.
fn think_state(
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
) {
    if mo.tics == fsm::FOREVER {
        return;
    }
    let (state, tics, action) = fsm::advance(ctx.w.states, mo.state, mo.tics);
    mo.state = state;
    mo.tics = tics;
    run_chain(
        ctx,
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
    if mo.tics == 0 {
        let (s2, t2, a2) = fsm::advance(ctx.w.states, mo.state, 0);
        mo.state = s2;
        mo.tics = t2;
        run_chain(
            ctx,
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
    let missile = doom_physics::has(mo.flags, MF_MISSILE);
    // Momentum. Movement is never skipped: D3 caps the *thinking*, not the
    // physics, or a de-scheduled monster would stop mid-air.
    let mut moves: Array<MoveEvent> = array![];
    let xy = xy_movement(ctx.w, mobjs, ref g, ref mo, me, false, false, ref moves);
    drain(moves.span(), me, ref ev);
    let mut exploded = false;
    if missile {
        let hit = missile_hit(moves.span());
        if hit != NO_MOBJ {
            // `PIT_CheckThing` damages inline in C; the crate reports it, so
            // the draw happens here — still before anything else draws.
            let dmg_per: u32 = *MI_DAMAGE.span().at(mo.kind);
            let (next, roll) = rng.next(ctx.w.rndtable);
            rng = next;
            let r: u32 = (roll % 8).into();
            hurt(ctx, mobjs, ref rng, hit, me, mo.target, (r + 1) * dmg_per, ref patches, ref ev);
        }
        match xy {
            XyOutcome::MissileHit(b) => {
                let _: Blocker = b;
                explode_missile(ctx.w, ref rng, ref mo);
                exploded = true;
            },
            _ => {},
        }
    }
    if !exploded {
        let z = z_movement(ref mo, Option::None);
        if missile && z.missile_hit {
            explode_missile(ctx.w, ref rng, ref mo);
        }
    }
    // The state machine, with `A_Look` held back (see below).
    think_state(
        ctx, mobjs, ref g, ref rng, ref mo, me, false, may_chase, ref patches, ref ev, ref spawn_at,
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
    if may_look && is_dormant(ctx.w, @mo) {
        run_chain(
            ctx,
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
    if mo.state == 0 && mo.tics == fsm::FOREVER {
        unset_thing_position(ref g, @mo, me);
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
    let ctx = Ctx { w, players, noise, tic };
    let mut r = rng;
    let mut ev: Array<MonsterEvent> = array![];
    let mut patches: Array<Patch> = array![];
    let mut out: Array<Mobj> = array![];
    let n = mobjs.len();
    let awake = awake_count(w, mobjs);
    // Where a missile spawned this tic goes: a freed slot if there is one,
    // otherwise the end of the list.
    let free = first_free(mobjs);
    let mut spawn_at = if free == NO_MOBJ {
        n
    } else {
        free
    };
    let look_phase = tic % LOOK_CADENCE;
    let mut i: u32 = 0;
    let mut rank: u32 = 0;
    while i != n {
        let mut mo = *mobjs.at(i);
        if is_removed(@mo) || !is_ours(@mo) {
            out.append(mo);
            i += 1;
            continue;
        }
        let mut may_chase = true;
        if is_awake(w, @mo) {
            may_chase = in_window(rank, tic, awake);
            rank += 1;
        }
        let may_look = i % LOOK_CADENCE == look_phase;
        let alive = mobj_thinker(
            ctx,
            mobjs,
            ref g,
            ref r,
            ref mo,
            i,
            may_look,
            may_chase,
            ref patches,
            ref ev,
            ref spawn_at,
        );
        if alive {
            out.append(mo);
        } else {
            out.append(removed_mobj());
        }
        i += 1;
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
    let mut i: u32 = 0;
    while i != n {
        let mut m = *src.at(i);
        let mut k: u32 = 0;
        while k != np {
            let p = *patches.at(k);
            if p.idx == i {
                m = p.mo;
            }
            k += 1;
        }
        res.append(m);
        i += 1;
    }
    let mut k: u32 = 0;
    while k != np {
        let p = *patches.at(k);
        if p.idx >= n && res.len() < MAX_MOBJS {
            res.append(p.mo);
        }
        k += 1;
    }
    res
}

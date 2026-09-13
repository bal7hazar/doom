// SPDX-License-Identifier: GPL-2.0-only
//! The action functions of linuxdoom-1.10's `p_enemy.c`, as pure functions
//! on a `doom_physics::Mobj`: semantics derived, no C copied.
//!
//! Every function here is what one action *id* of `doom_things` does; the
//! dispatcher in [`super::think`] is a single `match` on that id. An action
//! that changes the actor's state returns the action of the state it
//! entered, for the dispatcher to run in turn (Doom's `P_SetMobjState`
//! calls the action immediately), and [`fsm::NO_ACTION`] otherwise.
//!
//! # Shape (docs/spikes/S7.md §8)
//!
//! Every public function of this module is the **boundary**: it takes the
//! 72-felt [`Ctx`] and the actor as a `Mobj`, and hands both to the `_in`
//! twin that does the work, which carries the six-felt [`Env`] and the
//! actor as a `Box<Mobj>`. Nothing wide crosses a call inside the crate:
//!
//! * a struct pushed at a call costs one word of bytecode and one step per
//!   felt, and a `ref` parameter is pushed **twice**, once in and once out;
//! * every panic site of a function stores its whole return width in
//!   zero-padded bytecode, and every call of a function that can panic is
//!   such a site in the caller — so the 27 felts of a `ref mo: Mobj` were
//!   being paid again at each of the ~90 propagation points of the chain;
//! * a `Box` is one felt, reading a field through it is free, and writing
//!   costs one `into_box` (27 felts) at the point of the write.
//!
//! The actor is therefore unboxed into a local at the top of a function,
//! mutated there, and re-boxed once — at the end, or just before a call
//! that has to see the change.

use bam::{ANG270, ANG90, Angle, point_to_angle2};
use doom_map::reject_of;
use doom_physics::maputl::{add32, dec, inc, low32, opaque_zero, rd, rd32};
use doom_physics::spawn::{roll, set_state_in};
use doom_physics::{
    Aim, DamageOutcome, FIREBALL, Hit, MELEERANGE, MF_AMBUSH, MF_JUSTATTACKED, MF_JUSTHIT,
    MF_SHADOW, MF_SHOOTABLE, MF_SOLID, MISSILERANGE, Mobj, MoveEvent, NO_MOBJ, ThingGrid, Verdict,
    aim_line_attack, bleeds, check_sight_cached, damage_mobj, has, line_attack, maputl,
    spawn_missile, try_move, without,
};
use doom_things::tables::{
    MI_MELEESTATE, MI_MISSILESTATE, MI_RADIUS, MI_SEESTATE, MI_SPAWNSTATE, MI_SPEED,
};
use fixed::{BIAS, Fixed};
use geom2d::approx_distance;
use prng::Prng;
use super::event::{
    EV_BLOOD, EV_DROP, EV_KILLED, EV_PUFF, EV_USE, EV_WAKE, MonsterEvent, event, sound,
};
use super::tables::{
    DIAGS, DI_NODIR, MI_ACTIVESOUND, MI_ATTACKSOUND, MI_DEATHSOUND, MI_PAINSOUND, MI_SEESOUND,
    OPPOSITE, SFX_BGDTH1, SFX_BGSIT1, SFX_BGSIT2, SFX_CLAW, SFX_FIRSHT, SFX_NONE, SFX_PISTOL,
    SFX_PODTH1, SFX_PODTH3, SFX_POSIT1, SFX_POSIT3, SFX_SHOTGN, SFX_SLOP, SOUND_KINDS, XSPEED,
    YSPEED,
};
use super::think::scale;
use super::{Ctx, Env, Patch, SIGHT_TTL, env_of, read_mobj};

/// One eighth of a turn, `ANG90 / 2`: what `A_Chase` turns by per tic.
const ANG45: Angle = 0x20000000;

/// `P_CheckMeleeRange`'s slack: `MELEERANGE - 20 * FRACUNIT`, before the
/// target's radius is added.
const MELEE_SLACK: Fixed = Fixed { enc: BIAS + 44 * 65536 };

/// `64 * FRACUNIT`, subtracted by `P_CheckMissileRange`.
const MISSILE_NEAR: Fixed = Fixed { enc: BIAS + 64 * 65536 };

/// `128 * FRACUNIT`, subtracted again when the actor has no melee attack.
const MISSILE_FAR: Fixed = Fixed { enc: BIAS + 128 * 65536 };

/// The eight angles `A_Chase` snaps to, `octant * ANG45`.
///
/// A table instead of `bam::add`/`bam::sub` around a multiplication: those
/// three carry `u32` overflow and `try_into` panic paths, and the value is
/// one of eight constants (S7 §8 rule 1, and S1 §5.9 on tables against
/// `if`-trees).
const OCTANT_ANGLE: [u32; 8] = [
    0, 0x20000000, 0x40000000, 0x60000000, 0x80000000, 0xA0000000, 0xC0000000, 0xE0000000,
];

/// `ANG45` as a divisor and `DI_NODIR` as a modulus, as `NonZero` literals:
/// the `/` and `%` operators keep an unfolded "division by zero" panic path
/// even against a constant divisor (S7 §8 rule 1).
const ANG45_NZ: NonZero<u32> = 0x20000000;
const EIGHT: NonZero<u32> = 8;
const SIXTEEN: NonZero<u8> = 16;
const TWO: NonZero<u8> = 2;
const UNIT: NonZero<u128> = 65536;
const TURN: NonZero<u128> = 0x100000000;
const FIVE: NonZero<u8> = 5;
const EIGHT_U8: NonZero<u8> = 8;
const TEN: NonZero<u8> = 10;

/// `bam::reduce` without its two `try_into().unwrap()`s: `x mod 2^32`.
fn reduce_at(x: felt252) -> Angle {
    let (_, r) = DivRem::div_rem(fixed::to_u128(x), TURN);
    low32(r)
}

// ---------------------------------------------------------------------------
// Writing through the box
// ---------------------------------------------------------------------------

/// `mo.move_dir = dir`, out of line: every `BoxTrait::new` writes the 27
/// felts of a `Mobj`, and `P_NewChaseDir` has eight such assignments
/// (S7 §8 rule 6).
fn set_dir(ref mo: Box<Mobj>, dir: u32) {
    mo = BoxTrait::new(Mobj { move_dir: dir, ..mo.unbox() });
}

/// `P_SetMobjState` on the boxed actor, returning the entered state's
/// action. `set_state_in` takes the five state spans, not the 67-felt
/// `World` its `set_state` sibling does.
fn state_to(e: Env, ref mo: Box<Mobj>, s: u32) -> u32 {
    let mut m = mo.unbox();
    let a = set_state_in(e.w.unbox().states, ref m, s);
    mo = BoxTrait::new(m);
    a
}

// ---------------------------------------------------------------------------
// `mobjinfo` columns, read one field at a time
// ---------------------------------------------------------------------------
//
// `doom_things::thing_info` builds all 18 fields (225 steps); these read the
// one column the caller needs (10 steps), which is what its README asks hot
// callers to do.

fn speed_of(kind: u32) -> u32 {
    rd32(MI_SPEED.span(), kind)
}

fn seestate_of(kind: u32) -> u32 {
    rd32(MI_SEESTATE.span(), kind)
}

fn spawnstate_of(kind: u32) -> u32 {
    rd32(MI_SPAWNSTATE.span(), kind)
}

fn meleestate_of(kind: u32) -> u32 {
    rd32(MI_MELEESTATE.span(), kind)
}

fn missilestate_of(kind: u32) -> u32 {
    rd32(MI_MISSILESTATE.span(), kind)
}

fn radius_of(kind: u32) -> Fixed {
    Fixed { enc: rd(MI_RADIUS.span(), kind) }
}

/// One of the five sound columns of [`super::tables`]; `SFX_NONE` for a kind
/// that has no sound roster (every item, the puff, the fireball).
fn sound_of(column: Span<u32>, kind: u32) -> u32 {
    if kind >= SOUND_KINDS {
        SFX_NONE
    } else {
        rd32(column, kind)
    }
}

// ---------------------------------------------------------------------------
// P_Move / P_TryWalk / P_NewChaseDir
// ---------------------------------------------------------------------------

/// `P_Move`: one step of `info->speed` along `movedir`.
///
/// **Departure.** Vanilla, when the step is refused, walks `spechit` and
/// calls `P_UseSpecialLine(actor, ld, 0)` so that a monster can open a door,
/// returning whether any line was usable. `doom_specials` owns the switch
/// and door state and this crate does not depend on it, so the blocking line
/// is reported as an [`EV_USE`] event for `doom_game` to hand to
/// `doom_specials::use_line` with a non-player `Actor`, and the move counts
/// as refused — the monster therefore also picks a new chase direction on
/// the tic it bumps into a door, one tic earlier than vanilla.
pub fn p_move(
    ctx: Ctx,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref mo: Mobj,
    me: u32,
    ref ev: Array<MonsterEvent>,
) -> bool {
    let mut b = BoxTrait::new(mo);
    let r = p_move_in(env_of(ctx), mobjs, ref g, ref b, me, ref ev);
    mo = b.unbox();
    r
}

pub(crate) fn p_move_in(
    e: Env,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref mo: Box<Mobj>,
    me: u32,
    ref ev: Array<MonsterEvent>,
) -> bool {
    let mut m = mo.unbox();
    let dir = m.move_dir;
    if dir >= DI_NODIR {
        return false;
    }
    let sp: felt252 = speed_of(m.kind).into();
    let tryx = Fixed { enc: m.x.enc + sp * rd(XSPEED.span(), dir) };
    let tryy = Fixed { enc: m.y.enc + sp * rd(YSPEED.span(), dir) };
    let mut moves: Array<MoveEvent> = array![];
    let v: Verdict = try_move(e.w.unbox(), mobjs, ref g, ref m, me, tryx, tryy, ref moves);
    // `MF_INFLOAT` is only ever set by the float arm; nothing clears it here.
    if v.ok {
        m.z = m.floorz;
    }
    mo = BoxTrait::new(m);
    if !v.ok {
        // A monster never floats on E1M1 (no lost soul, no cacodemon), so
        // vanilla's `MF_FLOAT && floatok` arm is not reachable here; the
        // door-opening arm becomes the event above.
        match v.blocker {
            doom_physics::Blocker::Line(line) => { ev.append(event(EV_USE, me, line, 0)); },
            _ => {},
        }
        return false;
    }
    super::event::drain(moves.span(), me, ref ev);
    true
}

/// `P_TryWalk`: move, and on success re-arm `movecount` with `P_Random()&15`.
fn try_walk(
    e: Env,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    ref ev: Array<MonsterEvent>,
) -> bool {
    if !p_move_in(e, mobjs, ref g, ref mo, me, ref ev) {
        return false;
    }
    let (_, low) = DivRem::div_rem(roll(ref rng, e.w.unbox().rndtable), SIXTEEN);
    mo = BoxTrait::new(Mobj { move_count: low.into(), ..mo.unbox() });
    true
}

/// `P_NewChaseDir`: Doom's direction search, in Doom's order.
pub fn new_chase_dir(
    ctx: Ctx,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Mobj,
    me: u32,
    target: @Mobj,
    ref ev: Array<MonsterEvent>,
) {
    let mut b = BoxTrait::new(mo);
    new_chase_dir_in(env_of(ctx), mobjs, ref g, ref rng, ref b, me, target, ref ev);
    mo = b.unbox();
}

pub(crate) fn new_chase_dir_in(
    e: Env,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    target: @Mobj,
    ref ev: Array<MonsterEvent>,
) {
    let rnd = e.w.unbox().rndtable;
    let m = mo.unbox();
    let olddir = m.move_dir;
    let turnaround = rd32(OPPOSITE.span(), olddir);
    let deltax = fixed::sub(*target.x, m.x);
    let deltay = fixed::sub(*target.y, m.y);
    let ten = Fixed { enc: BIAS + 10 * 65536 };
    let east = fixed::gt(deltax, ten);
    let west = fixed::lt(deltax, fixed::neg(ten));
    let north = fixed::gt(deltay, ten);
    let south = fixed::lt(deltay, fixed::neg(ten));
    let mut d1 = if east {
        super::tables::DI_EAST
    } else if west {
        super::tables::DI_WEST
    } else {
        DI_NODIR
    };
    let mut d2 = if south {
        super::tables::DI_SOUTH
    } else if north {
        super::tables::DI_NORTH
    } else {
        DI_NODIR
    };

    // Try the direct diagonal route.
    if d1 != DI_NODIR && d2 != DI_NODIR {
        let idx = if fixed::is_neg(deltay) {
            2
        } else {
            0
        }
            + if fixed::gt(deltax, fixed::ZERO) {
                1
            } else {
                0
            };
        let diag = rd32(DIAGS.span(), idx);
        set_dir(ref mo, diag);
        if diag != turnaround && try_walk(e, mobjs, ref g, ref rng, ref mo, me, ref ev) {
            return;
        }
    }

    // Swap the two candidates, sometimes.
    let swap = roll(ref rng, rnd);
    if swap > 200 || fixed::gt(fixed::abs(deltay), fixed::abs(deltax)) {
        let t = d1;
        d1 = d2;
        d2 = t;
    }
    if d1 == turnaround {
        d1 = DI_NODIR;
    }
    if d2 == turnaround {
        d2 = DI_NODIR;
    }
    if d1 != DI_NODIR {
        set_dir(ref mo, d1);
        if try_walk(e, mobjs, ref g, ref rng, ref mo, me, ref ev) {
            return;
        }
    }
    if d2 != DI_NODIR {
        set_dir(ref mo, d2);
        if try_walk(e, mobjs, ref g, ref rng, ref mo, me, ref ev) {
            return;
        }
    }
    // No direct path: keep going the old way if there was one.
    if olddir != DI_NODIR {
        set_dir(ref mo, olddir);
        if try_walk(e, mobjs, ref g, ref rng, ref mo, me, ref ev) {
            return;
        }
    }
    // Then sweep the eight directions, in a randomly chosen order.
    let order = roll(ref rng, rnd);
    let (_, parity) = DivRem::div_rem(order, TWO);
    let forward = parity == 1;
    let mut k: u32 = opaque_zero(olddir);
    let mut done = false;
    while k != DI_NODIR {
        let tdir = if forward {
            k
        } else {
            maputl::sub32(DI_NODIR - 1, k)
        };
        k = inc(k);
        if tdir == turnaround {
            continue;
        }
        set_dir(ref mo, tdir);
        if try_walk(e, mobjs, ref g, ref rng, ref mo, me, ref ev) {
            done = true;
            break;
        }
    }
    if done {
        return;
    }
    if turnaround != DI_NODIR {
        set_dir(ref mo, turnaround);
        if try_walk(e, mobjs, ref g, ref rng, ref mo, me, ref ev) {
            return;
        }
    }
    set_dir(ref mo, DI_NODIR);
}

// ---------------------------------------------------------------------------
// Range checks
// ---------------------------------------------------------------------------

/// `P_CheckMeleeRange`: within `MELEERANGE - 20 + target radius`, and in
/// sight (through the R2-A3 cache).
pub fn check_melee_range(ctx: Ctx, ref mo: Mobj, target: @Mobj) -> bool {
    let mut b = BoxTrait::new(mo);
    let r = check_melee_range_in(env_of(ctx), ref b, target);
    mo = b.unbox();
    r
}

pub(crate) fn check_melee_range_in(e: Env, ref mo: Box<Mobj>, target: @Mobj) -> bool {
    let mut m = mo.unbox();
    let dist = approx_distance(fixed::sub(*target.x, m.x), fixed::sub(*target.y, m.y));
    if fixed::ge(dist, fixed::add(MELEE_SLACK, radius_of(*target.kind))) {
        return false;
    }
    let seen = check_sight_cached(e.w.unbox(), ref m, target, e.tic, SIGHT_TTL);
    mo = BoxTrait::new(m);
    seen
}

/// `P_CheckMissileRange`: sight, `MF_JUSTHIT`, `reactiontime`, then the
/// vanilla distance-as-probability rule.
///
/// The `P_Random` draw of the last line happens **whatever** the distance,
/// exactly as in C, so RNG consumption does not depend on the geometry.
pub fn check_missile_range(ctx: Ctx, ref rng: Prng, ref mo: Mobj, target: @Mobj) -> bool {
    let mut b = BoxTrait::new(mo);
    let r = check_missile_range_in(env_of(ctx), ref rng, ref b, target);
    mo = b.unbox();
    r
}

pub(crate) fn check_missile_range_in(
    e: Env, ref rng: Prng, ref mo: Box<Mobj>, target: @Mobj,
) -> bool {
    let mut m = mo.unbox();
    let seen = check_sight_cached(e.w.unbox(), ref m, target, e.tic, SIGHT_TTL);
    // "The target just hit us: fight back", folded into the one write-back
    // so that the function boxes the actor once whichever way it answers.
    let fight_back = seen && has(m.flags, MF_JUSTHIT);
    if fight_back {
        m.flags = without(m.flags, MF_JUSTHIT);
    }
    mo = BoxTrait::new(m);
    if !seen {
        return false;
    }
    if fight_back {
        return true;
    }
    if m.reaction_time != 0 {
        return false;
    }
    let mut dist = approx_distance(fixed::sub(m.x, *target.x), fixed::sub(m.y, *target.y));
    dist = fixed::sub(dist, MISSILE_NEAR);
    if meleestate_of(m.kind) == 0 {
        dist = fixed::sub(dist, MISSILE_FAR);
    }
    // `dist >>= 16` on a signed fixed_t, then `if (dist > 200) dist = 200`.
    // A negative or sub-unit distance leaves a threshold of 0, and
    // `P_Random() < 0` is false — the monster fires. E1M1's only missile
    // user is the imp, whose `MT_CYBORG`/`MT_SKULL` special cases in C
    // cannot apply.
    let mut n: u32 = 0;
    if !fixed::is_neg(dist) {
        let (units, _) = DivRem::div_rem(fixed::to_u128(fixed::to_raw(dist)), UNIT);
        n = if units > 200 {
            200
        } else {
            low32(units)
        };
    }
    let roll32: u32 = roll(ref rng, e.w.unbox().rndtable).into();
    roll32 >= n
}

// ---------------------------------------------------------------------------
// A_Look
// ---------------------------------------------------------------------------

/// Whether a monster in `listener` can hear a noise made in `noise`.
///
/// **Departure, documented in the README.** Vanilla floods the sector graph
/// (`P_NoiseAlert`/`P_RecursiveSound`) from the sector the shot was fired
/// in, stopping at closed openings and `ML_SOUNDBLOCK`, and leaves a
/// `soundtarget` on every sector it reaches. `doom_map` compiles no
/// sector→lines index, so that flood would have to rebuild the sector graph
/// from all of E1M1's linedefs on every shot (~500 lines × ~15 steps = a
/// five-figure cost per flood, and a per-shot one). The REJECT row of the
/// two sectors answers the same question in **one packed table read**
/// (~150 steps, R2-A2) and is what `check_sight` already consults: sectors
/// that REJECT each other are exactly the ones with no line of sight at all.
/// It is conservative in the safe direction — a monster around a fully
/// occluded corner does not hear the shot where vanilla would wake it — and
/// it needs no new state, no new map data and no per-tic work.
fn hears(e: Env, listener: u32, noise: u32) -> bool {
    let map = e.w.unbox().map;
    !reject_of(map.reject, map.reject_stride, map.pow2, listener, noise)
}

/// `P_LookForPlayers`, single-player shape.
///
/// **Departure.** Vanilla's `lastlook` walk re-tests the same player up to
/// three times when only one is in the game (`c++ == 2` is what ends it);
/// the answer is identical every time and each repeat is a full
/// `P_CheckSight`, so the loop runs once per player here. No `P_Random` is
/// drawn either way, so the RNG stream is unaffected.
pub fn look_for_players(ctx: Ctx, mobjs: Span<Mobj>, ref mo: Mobj, all_around: bool) -> bool {
    let mut b = BoxTrait::new(mo);
    let r = look_for_players_in(env_of(ctx), mobjs, ref b, all_around);
    mo = b.unbox();
    r
}

pub(crate) fn look_for_players_in(
    e: Env, mobjs: Span<Mobj>, ref mo: Box<Mobj>, all_around: bool,
) -> bool {
    let n = e.players.len();
    let mut k: u32 = opaque_zero(n);
    let mut found = false;
    // The loop carries the actor's `Box`, not the actor: a loop is a
    // function, and a 27-felt live value is pushed into it and returned out
    // of it on every iteration (S7 §8 rule 4).
    while k != n {
        let pi = rd32(e.players, k);
        k = inc(k);
        let p = match mobjs.get(pi) {
            Option::Some(b) => b.unbox(),
            Option::None => { continue; },
        };
        if *p.health <= 0 {
            continue;
        }
        let mut m = mo.unbox();
        let seen = check_sight_cached(e.w.unbox(), ref m, p, e.tic, SIGHT_TTL);
        mo = BoxTrait::new(m);
        if !seen {
            continue;
        }
        if !all_around {
            let an = bam::sub(point_to_angle2(m.x, m.y, *p.x, *p.y), m.angle);
            if an > ANG90 && an < ANG270 {
                let dist = approx_distance(fixed::sub(*p.x, m.x), fixed::sub(*p.y, m.y));
                if fixed::gt(dist, MELEERANGE) {
                    continue; // behind the back and out of reach
                }
            }
        }
        mo = BoxTrait::new(Mobj { target: pi, ..m });
        found = true;
        break;
    }
    found
}

/// Doom's "pick inside the run" rule for a see or death sound: the two
/// contiguous families `posit1..3` and `bgsit1..2` (`podth1..3` and
/// `bgdth1..2` for a death) draw one `P_Random`, everything else does not.
///
/// Takes the `rndtable` span, not the context: this needs two felts, not
/// six (S7 §8 rule 3).
fn pick_sound(
    rnd: Span<u8>, ref rng: Prng, base: u32, low: u32, high: u32, span: NonZero<u8>,
) -> u32 {
    if base < low || base > high {
        return base;
    }
    let (_, r) = DivRem::div_rem(roll(ref rng, rnd), span);
    let pick: u32 = r.into();
    add32(low, pick)
}

/// `A_Look`: wake on the sector's `soundtarget` (subject to `MF_AMBUSH`) or
/// on seeing a player, then enter `seestate`.
pub fn a_look(
    ctx: Ctx, mobjs: Span<Mobj>, ref rng: Prng, ref mo: Mobj, me: u32, ref ev: Array<MonsterEvent>,
) -> u32 {
    let mut b = BoxTrait::new(mo);
    let r = a_look_in(env_of(ctx), mobjs, ref rng, ref b, me, ref ev);
    mo = b.unbox();
    r
}

pub(crate) fn a_look_in(
    e: Env,
    mobjs: Span<Mobj>,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    ref ev: Array<MonsterEvent>,
) -> u32 {
    let mut m = mo.unbox();
    m.threshold = 0; // any shot will wake us up
    let mut seeyou = false;
    let src = e.noise.source;
    if src != NO_MOBJ && src < mobjs.len() && hears(e, m.sector, e.noise.sector) {
        match mobjs.get(src) {
            Option::Some(b) => {
                let targ = b.unbox();
                if has(*targ.flags, MF_SHOOTABLE) {
                    m.target = src;
                    if has(m.flags, MF_AMBUSH) {
                        seeyou = check_sight_cached(e.w.unbox(), ref m, targ, e.tic, SIGHT_TTL);
                    } else {
                        seeyou = true;
                    }
                }
            },
            Option::None => {},
        }
    }
    mo = BoxTrait::new(m);
    if !seeyou && !look_for_players_in(e, mobjs, ref mo, false) {
        return fsm::NO_ACTION;
    }
    let woken = mo.unbox();
    let base = sound_of(MI_SEESOUND.span(), woken.kind);
    if base != SFX_NONE {
        let rnd = e.w.unbox().rndtable;
        let three: NonZero<u8> = 3;
        let two: NonZero<u8> = 2;
        let mut s = pick_sound(rnd, ref rng, base, SFX_POSIT1, SFX_POSIT3, three);
        if s == base {
            s = pick_sound(rnd, ref rng, base, SFX_BGSIT1, SFX_BGSIT2, two);
        }
        ev.append(sound(me, s));
    }
    ev.append(event(EV_WAKE, me, woken.target, 0));
    state_to(e, ref mo, seestate_of(woken.kind))
}

// ---------------------------------------------------------------------------
// A_Chase
// ---------------------------------------------------------------------------

/// `A_Chase`: the whole of a monster's turn — countdowns, turning, the melee
/// and missile decisions, the walk, and the active sound.
pub fn a_chase(
    ctx: Ctx,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Mobj,
    me: u32,
    patches: Span<Patch>,
    ref ev: Array<MonsterEvent>,
) -> u32 {
    let mut b = BoxTrait::new(mo);
    let r = a_chase_in(env_of(ctx), mobjs, ref g, ref rng, ref b, me, patches, ref ev);
    mo = b.unbox();
    r
}

pub(crate) fn a_chase_in(
    e: Env,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    patches: Span<Patch>,
    ref ev: Array<MonsterEvent>,
) -> u32 {
    let mut m = mo.unbox();
    if m.reaction_time != 0 {
        m.reaction_time = dec(m.reaction_time);
    }
    let has_target = m.target != NO_MOBJ && m.target < mobjs.len();
    let target = if has_target {
        read_mobj(mobjs, patches, m.target)
    } else {
        m
    };
    // Modify the target threshold.
    if m.threshold != 0 {
        if !has_target || target.health <= 0 {
            m.threshold = 0;
        } else {
            m.threshold = dec(m.threshold);
        }
    }
    // Turn towards the movement direction if not there yet: the angle is
    // first snapped to a multiple of 45 degrees (`angle &= 7 << 29`), then
    // moved one eighth of a turn the short way round.
    if m.move_dir < DI_NODIR {
        let (octant, _) = DivRem::div_rem(m.angle, ANG45_NZ);
        let (_, delta) = DivRem::div_rem(maputl::sub32(add32(octant, DI_NODIR), m.move_dir), EIGHT);
        // The same eighth of a turn as an octant index: `bam::sub(ang,
        // ANG45)` is `octant - 1 mod 8` and `bam::add` is `octant + 1 mod 8`,
        // both exact because `ang` is a multiple of `ANG45`.
        let turn = if delta == 0 {
            0
        } else if delta < 4 {
            7
        } else {
            1
        };
        let (_, oct) = DivRem::div_rem(add32(octant, turn), EIGHT);
        m.angle = rd32(OCTANT_ANGLE.span(), oct);
    }
    // The three fields the rest of the function reads, read before the one
    // write-back: `kind` never changes, and `flags` and `move_count` are
    // read at points that no call in between has reached yet.
    let kind = m.kind;
    let flags = m.flags;
    let move_count = m.move_count;
    mo = BoxTrait::new(m);
    if !has_target || !has(target.flags, MF_SHOOTABLE) {
        // Look for a new target.
        if look_for_players_in(e, mobjs, ref mo, true) {
            return fsm::NO_ACTION;
        }
        return state_to(e, ref mo, spawnstate_of(kind));
    }
    // Do not attack twice in a row.
    if has(flags, MF_JUSTATTACKED) {
        mo = BoxTrait::new(Mobj { flags: without(flags, MF_JUSTATTACKED), ..mo.unbox() });
        new_chase_dir_in(e, mobjs, ref g, ref rng, ref mo, me, @target, ref ev);
        return fsm::NO_ACTION;
    }
    // Melee.
    let melee = meleestate_of(kind);
    if melee != 0 && check_melee_range_in(e, ref mo, @target) {
        let s = sound_of(MI_ATTACKSOUND.span(), kind);
        if s != SFX_NONE {
            ev.append(sound(me, s));
        }
        return state_to(e, ref mo, melee);
    }
    // Missile. Skill 2 is below nightmare, so `movecount` gates it.
    let missile = missilestate_of(kind);
    if missile != 0 && move_count == 0 && check_missile_range_in(e, ref rng, ref mo, @target) {
        let firing = mo.unbox();
        mo = BoxTrait::new(Mobj { flags: firing.flags | MF_JUSTATTACKED, ..firing });
        return state_to(e, ref mo, missile);
    }
    // Chase towards the player. Doom's `--movecount < 0` on a signed int:
    // the counter only ever matters by its sign, and `P_TryWalk` re-arms it.
    if move_count == 0 {
        new_chase_dir_in(e, mobjs, ref g, ref rng, ref mo, me, @target, ref ev);
    } else {
        mo = BoxTrait::new(Mobj { move_count: dec(move_count), ..mo.unbox() });
        if !p_move_in(e, mobjs, ref g, ref mo, me, ref ev) {
            new_chase_dir_in(e, mobjs, ref g, ref rng, ref mo, me, @target, ref ev);
        }
    }
    // Make an active sound.
    let active = sound_of(MI_ACTIVESOUND.span(), kind);
    if active != SFX_NONE {
        if roll(ref rng, e.w.unbox().rndtable) < 3 {
            ev.append(sound(me, active));
        }
    }
    fsm::NO_ACTION
}

// ---------------------------------------------------------------------------
// A_FaceTarget and the attacks
// ---------------------------------------------------------------------------

/// `A_FaceTarget`: turn to the target, clear `MF_AMBUSH`, and spread the
/// aim against a `MF_SHADOW` target.
pub fn a_face_target(ctx: Ctx, ref rng: Prng, ref mo: Mobj, target: @Mobj) {
    face_target(ctx.w.rndtable, ref rng, ref mo, target);
}

/// [`a_face_target`] on the `rndtable` alone: two felts instead of a
/// context. The actor travels by `ref` and not boxed here: this is a leaf
/// its callers reach with an unboxed local in hand.
pub(crate) fn face_target(rnd: Span<u8>, ref rng: Prng, ref mo: Mobj, target: @Mobj) {
    mo.flags = without(mo.flags, MF_AMBUSH);
    let mut an = point_to_angle2(mo.x, mo.y, *target.x, *target.y);
    if has(*target.flags, MF_SHADOW) {
        let s = sub_roll(rnd, ref rng);
        an = reduce_at(an.into() + s * 0x200000 + 0x100000000);
    }
    mo.angle = an;
}

/// `(P_Random() - P_Random()) << 20` added to an angle: the hitscan spread.
fn spread_angle(rnd: Span<u8>, ref rng: Prng, base: Angle) -> Angle {
    let s = sub_roll(rnd, ref rng);
    reduce_at(base.into() + s * 0x100000 + 0x100000000)
}

/// `P_Random() - P_Random()` as a felt: `prng::sub_random` without its `i32`
/// subtraction (an overflow panic path) and without its two `at` reads.
fn sub_roll(rnd: Span<u8>, ref rng: Prng) -> felt252 {
    let a = roll(ref rng, rnd);
    let b = roll(ref rng, rnd);
    let af: felt252 = a.into();
    let bf: felt252 = b.into();
    af - bf
}

/// One hitscan of `damage` from `me` along `angle` at `slope`, with the
/// puff/blood event and the damage the crossing costs.
fn shoot(
    e: Env,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    me: u32,
    angle: Angle,
    slope: Fixed,
    damage: u32,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
) {
    let hit = line_attack(e.w.unbox(), mobjs, ref g, me, angle, MISSILERANGE, slope);
    match hit {
        Hit::Nothing => {},
        Hit::Wall((
            _, p, _,
        )) => { ev.append(MonsterEvent { kind: EV_PUFF, who: me, a: 0, b: 0, at: p }); },
        Hit::Thing((
            idx, p, _,
        )) => {
            let bleed = match mobjs.get(idx) {
                Option::Some(b) => bleeds(b.unbox()),
                Option::None => false,
            };
            let kind = if bleed {
                EV_BLOOD
            } else {
                EV_PUFF
            };
            ev.append(MonsterEvent { kind, who: me, a: idx, b: damage, at: p });
            hurt_in(e, mobjs, ref rng, idx, me, me, damage, ref patches, ref ev);
        },
    }
}

/// `P_DamageMobj` on another mobj, applied to a copy that the ticker writes
/// back at the end of the tic (the physics README's "batch the backward
/// patches"), with the pain or death action run on the spot as
/// `P_SetMobjState` does.
pub fn hurt(
    ctx: Ctx,
    mobjs: Span<Mobj>,
    ref rng: Prng,
    target_idx: u32,
    inflictor: u32,
    source: u32,
    damage: u32,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
) {
    hurt_in(
        env_of(ctx), mobjs, ref rng, target_idx, inflictor, source, damage, ref patches, ref ev,
    );
}

pub(crate) fn hurt_in(
    e: Env,
    mobjs: Span<Mobj>,
    ref rng: Prng,
    target_idx: u32,
    inflictor: u32,
    source: u32,
    damage: u32,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
) {
    let mut t = read_mobj(mobjs, patches.span(), target_idx);
    let out: DamageOutcome = damage_mobj(
        e.w.unbox(), mobjs, ref rng, ref t, target_idx, inflictor, source, damage, true,
    );
    run_passive(e.w.unbox().rndtable, ref rng, ref t, target_idx, out.action, ref ev);
    if out.counts_kill {
        ev.append(event(EV_KILLED, target_idx, source, 0));
    }
    patches.append(Patch { idx: target_idx, mo: t });
    match out.drop {
        Option::Some(item) => { ev.append(event(EV_DROP, target_idx, item.kind, 0)); },
        Option::None => {},
    }
}

/// The four actions a damaged or dying mobj runs on the spot, none of which
/// changes its state again: `A_Pain`, `A_Scream`, `A_XScream`, `A_Fall`.
pub fn passive(
    ctx: Ctx, ref rng: Prng, ref mo: Mobj, me: u32, action: u32, ref ev: Array<MonsterEvent>,
) {
    run_passive(ctx.w.rndtable, ref rng, ref mo, me, action, ref ev);
}

/// [`passive`] on the `rndtable` alone. The actor travels by `ref` here:
/// this is also run on the *target*'s copy by [`hurt_in`], which holds a
/// plain `Mobj`, and the function has no panic site of its own.
pub(crate) fn run_passive(
    rnd: Span<u8>, ref rng: Prng, ref mo: Mobj, me: u32, action: u32, ref ev: Array<MonsterEvent>,
) {
    if action == doom_things::tables::A_PAIN {
        let s = sound_of(MI_PAINSOUND.span(), mo.kind);
        if s != SFX_NONE {
            ev.append(sound(me, s));
        }
    } else if action == doom_things::tables::A_SCREAM {
        scream(rnd, ref rng, ref mo, me, ref ev);
    } else if action == doom_things::tables::A_XSCREAM {
        ev.append(sound(me, SFX_SLOP));
    } else if action == doom_things::tables::A_FALL {
        mo.flags = without(mo.flags, MF_SOLID);
    }
}

/// `A_Scream`: the death sound, picked inside its family.
pub fn a_scream(ctx: Ctx, ref rng: Prng, ref mo: Mobj, me: u32, ref ev: Array<MonsterEvent>) {
    scream(ctx.w.rndtable, ref rng, ref mo, me, ref ev);
}

/// [`a_scream`] on the `rndtable` alone.
pub(crate) fn scream(
    rnd: Span<u8>, ref rng: Prng, ref mo: Mobj, me: u32, ref ev: Array<MonsterEvent>,
) {
    let base = sound_of(MI_DEATHSOUND.span(), mo.kind);
    if base == SFX_NONE {
        return;
    }
    let three: NonZero<u8> = 3;
    let two: NonZero<u8> = 2;
    let mut s = pick_sound(rnd, ref rng, base, SFX_PODTH1, SFX_PODTH3, three);
    if s == base {
        s = pick_sound(rnd, ref rng, base, SFX_BGDTH1, SFX_BGDTH1 + 1, two);
    }
    ev.append(sound(me, s));
}

/// `A_PosAttack`: the zombieman's single pistol shot.
pub fn a_pos_attack(
    ctx: Ctx,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Mobj,
    me: u32,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
) {
    let mut b = BoxTrait::new(mo);
    a_pos_attack_in(env_of(ctx), mobjs, ref g, ref rng, ref b, me, ref patches, ref ev);
    mo = b.unbox();
}

pub(crate) fn a_pos_attack_in(
    e: Env,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
) {
    let rnd = e.w.unbox().rndtable;
    let mut m = mo.unbox();
    let target = read_mobj(mobjs, patches.span(), m.target);
    face_target(rnd, ref rng, ref m, @target);
    let base = m.angle;
    mo = BoxTrait::new(m);
    let aim: Aim = aim_line_attack(e.w.unbox(), mobjs, ref g, me, base, MISSILERANGE);
    ev.append(sound(me, SFX_PISTOL));
    let angle = spread_angle(rnd, ref rng, base);
    let damage = roll_damage(rnd, ref rng, FIVE, 3);
    shoot(e, mobjs, ref g, ref rng, me, angle, aim.slope, damage, ref patches, ref ev);
}

/// `A_SPosAttack`: the shotgun guy's three pellets, one aim for all three.
pub fn a_spos_attack(
    ctx: Ctx,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Mobj,
    me: u32,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
) {
    let mut b = BoxTrait::new(mo);
    a_spos_attack_in(env_of(ctx), mobjs, ref g, ref rng, ref b, me, ref patches, ref ev);
    mo = b.unbox();
}

pub(crate) fn a_spos_attack_in(
    e: Env,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
) {
    let rnd = e.w.unbox().rndtable;
    let mut m = mo.unbox();
    let target = read_mobj(mobjs, patches.span(), m.target);
    ev.append(sound(me, SFX_SHOTGN));
    face_target(rnd, ref rng, ref m, @target);
    let base = m.angle;
    mo = BoxTrait::new(m);
    let aim: Aim = aim_line_attack(e.w.unbox(), mobjs, ref g, me, base, MISSILERANGE);
    let mut i: u32 = opaque_zero(me);
    while i != 3 {
        i = inc(i);
        let angle = spread_angle(rnd, ref rng, base);
        let damage = roll_damage(rnd, ref rng, FIVE, 3);
        shoot(e, mobjs, ref g, ref rng, me, angle, aim.slope, damage, ref patches, ref ev);
    }
}

/// `((P_Random() % n) + 1) * mul`, the damage roll of every melee and
/// hitscan attack in `p_enemy.c`.
fn roll_damage(rnd: Span<u8>, ref rng: Prng, n: NonZero<u8>, mul: u32) -> u32 {
    let (_, r) = DivRem::div_rem(roll(ref rng, rnd), n);
    scale(r.into(), mul)
}

/// `A_TroopAttack`: the imp's claw, or its fireball.
pub fn a_troop_attack(
    ctx: Ctx,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Mobj,
    me: u32,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
    ref spawn_at: u32,
) {
    let mut b = BoxTrait::new(mo);
    a_troop_attack_in(
        env_of(ctx), mobjs, ref g, ref rng, ref b, me, ref patches, ref ev, ref spawn_at,
    );
    mo = b.unbox();
}

pub(crate) fn a_troop_attack_in(
    e: Env,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
    ref spawn_at: u32,
) {
    let rnd = e.w.unbox().rndtable;
    let mut m = mo.unbox();
    let target_idx = m.target;
    let target = read_mobj(mobjs, patches.span(), target_idx);
    face_target(rnd, ref rng, ref m, @target);
    mo = BoxTrait::new(m);
    if check_melee_range_in(e, ref mo, @target) {
        ev.append(sound(me, SFX_CLAW));
        let damage = roll_damage(rnd, ref rng, EIGHT_U8, 3);
        hurt_in(e, mobjs, ref rng, target_idx, me, me, damage, ref patches, ref ev);
        return;
    }
    // Launch a missile.
    let mut moves: Array<MoveEvent> = array![];
    let idx = spawn_at;
    let shooter = mo.unbox();
    let (missile, _) = spawn_missile(
        e.w.unbox(), mobjs, ref g, ref rng, @shooter, me, @target, FIREBALL, idx, ref moves,
    );
    super::event::drain(moves.span(), idx, ref ev);
    ev.append(sound(me, SFX_FIRSHT));
    patches.append(Patch { idx, mo: missile });
    spawn_at = inc(idx);
}

/// `A_SargAttack`: the demon's (and the spectre's) bite.
pub fn a_sarg_attack(
    ctx: Ctx,
    mobjs: Span<Mobj>,
    ref rng: Prng,
    ref mo: Mobj,
    me: u32,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
) {
    let mut b = BoxTrait::new(mo);
    a_sarg_attack_in(env_of(ctx), mobjs, ref rng, ref b, me, ref patches, ref ev);
    mo = b.unbox();
}

pub(crate) fn a_sarg_attack_in(
    e: Env,
    mobjs: Span<Mobj>,
    ref rng: Prng,
    ref mo: Box<Mobj>,
    me: u32,
    ref patches: Array<Patch>,
    ref ev: Array<MonsterEvent>,
) {
    let rnd = e.w.unbox().rndtable;
    let mut m = mo.unbox();
    let target_idx = m.target;
    let target = read_mobj(mobjs, patches.span(), target_idx);
    face_target(rnd, ref rng, ref m, @target);
    mo = BoxTrait::new(m);
    if !check_melee_range_in(e, ref mo, @target) {
        return;
    }
    let damage = roll_damage(rnd, ref rng, TEN, 4);
    hurt_in(e, mobjs, ref rng, target_idx, me, me, damage, ref patches, ref ev);
}

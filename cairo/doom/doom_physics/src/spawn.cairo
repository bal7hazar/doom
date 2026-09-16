// SPDX-License-Identifier: GPL-2.0-only
//! `P_SpawnMobj`, `P_SpawnMapThing`, `P_SpawnMissile`, `P_ExplodeMissile`
//! and `P_SetMobjState` (`p_mobj.c`).
//!
//! A spawn returns the new record; the caller puts it in the list
//! (`mobj::push`, or a removed slot) and links it (`position::link_thing`)
//! with the index it got. Puffs and blood are events (see `hitscan`).
//!
//! The panic-free twins of three foreign accessors live here (S7 §2: a
//! panic site inside an inlined accessor costs the enclosing function's
//! whole return width, and these are inlined into the widest functions of
//! the crate): [`state_entry`] for `fsm::enter`, [`roll`] for
//! `prng::PrngTrait::next` and [`info_of`] for `doom_things::thing_info`.
//! Each reads the same tables with the same semantics; the crates they
//! mirror stay the source of truth and are tested against them.

use bam::{Angle, point_to_angle2};
use doom_map::MapThing;
use doom_things::tables::{KIND_PLAYER, KIND_TROOPSHOT};
use doom_things::{ThingInfo, kind_of_doomednum, tables};
use fixed::{BIAS, Fixed};
use fsm::{FOREVER, NO_ACTION, StateTables};
use geom2d::{Point, approx_distance};
use prng::{Prng, PrngTrait, TABLE_LEN};
use super::grid::ThingGrid;
use super::maputl::{add32, dec, inc, rd, rd32, rd8, sub32};
use super::mobj::{
    MF_AMBUSH, MF_MISSILE, MF_SHADOW, MF_SPAWNCEILING, Mobj, NO_CELL, NO_MOBJ, has, without,
};
use super::movement::{MoveEvent, half_of, try_move_in};
use super::position::{locate_boxed, move_cell};
use super::world::{Level, World, level_of};

/// The lost soul, whose corpse keeps `MF_NOGRAVITY` (not on E1M1; the
/// roster has no such kind, so no kind matches).
pub const KIND_SKULL: u32 = 0xFFFE;
/// `MTF_AMBUSH` on a THINGS flags word.
pub const MTF_AMBUSH: u32 = 8;

/// Where to put a spawned thing vertically (`ONFLOORZ` / `ONCEILINGZ`).
#[derive(Copy, Drop, PartialEq, Debug)]
pub enum SpawnZ {
    OnFloor,
    OnCeiling,
    At: Fixed,
}

// ---------------------------------------------------------------------------
// Panic-free table accessors
// ---------------------------------------------------------------------------

/// `fsm::enter` without a panic path: `(tics, action)` of `state`, or
/// `(FOREVER, NO_ACTION)` past the table.
#[inline(always)]
pub fn state_entry(states: StateTables, state: u32) -> (u32, u32) {
    if state >= states.tics.len() {
        return (FOREVER, NO_ACTION);
    }
    (rd32(states.tics, state), rd32(states.action_id, state))
}

/// `P_Random`: `prng::PrngTrait::next` without a panic path — the same
/// table read and the same wrap at `TABLE_LEN`.
pub fn roll(ref rng: Prng, table: Span<u8>) -> u8 {
    let value = rd8(table, rng.index);
    rng = Prng { index: if rng.index == dec(TABLE_LEN) {
        0
    } else {
        inc(rng.index)
    } };
    value
}

/// `doom_things::thing_info` without a panic path: the same `mobjinfo` row.
#[inline(never)]
pub fn info_of(kind: u32) -> ThingInfo {
    ThingInfo {
        doomednum: rd32(tables::MI_DOOMEDNUM.span(), kind),
        spawnstate: rd32(tables::MI_SPAWNSTATE.span(), kind),
        spawnhealth: rd32(tables::MI_SPAWNHEALTH.span(), kind),
        seestate: rd32(tables::MI_SEESTATE.span(), kind),
        reactiontime: rd32(tables::MI_REACTIONTIME.span(), kind),
        painstate: rd32(tables::MI_PAINSTATE.span(), kind),
        painchance: rd32(tables::MI_PAINCHANCE.span(), kind),
        meleestate: rd32(tables::MI_MELEESTATE.span(), kind),
        missilestate: rd32(tables::MI_MISSILESTATE.span(), kind),
        deathstate: rd32(tables::MI_DEATHSTATE.span(), kind),
        xdeathstate: rd32(tables::MI_XDEATHSTATE.span(), kind),
        raisestate: rd32(tables::MI_RAISESTATE.span(), kind),
        speed: rd32(tables::MI_SPEED.span(), kind),
        radius: Fixed { enc: rd(tables::MI_RADIUS.span(), kind) },
        height: Fixed { enc: rd(tables::MI_HEIGHT.span(), kind) },
        mass: rd32(tables::MI_MASS.span(), kind),
        damage: rd32(tables::MI_DAMAGE.span(), kind),
        flags: rd32(tables::MI_FLAGS.span(), kind),
    }
}

// ---------------------------------------------------------------------------
// P_SetMobjState
// ---------------------------------------------------------------------------

/// `P_SetMobjState` without the zero-tic loop (`fsm::enter`): returns the
/// action of the state entered, for the caller to run (`fsm::NO_ACTION` when
/// none). Entering state 0 (`S_NULL`) is Doom's "remove me" — the caller
/// checks `tics == FOREVER && state == 0`.
pub fn set_state(w: World, ref mo: Mobj, state: u32) -> u32 {
    set_state_in(w.states, ref mo, state)
}

/// [`set_state`] on the tables alone.
pub fn set_state_in(states: StateTables, ref mo: Mobj, state: u32) -> u32 {
    let (tics, action) = state_entry(states, state);
    mo.state = state;
    mo.tics = tics;
    action
}

/// Doom's random tic shortening (`P_KillMobj`, `P_CheckMissileSpawn`,
/// `P_ExplodeMissile`): `tics -= P_Random() & 3`, floored at 1.
pub fn shorten_tics(rnd: Span<u8>, ref rng: Prng, tics: u32) -> u32 {
    let r = roll(ref rng, rnd);
    let four: NonZero<u8> = 4;
    let (_, low) = DivRem::div_rem(r, four);
    let shorten: u32 = low.into();
    if tics > add32(shorten, 1) {
        sub32(tics, shorten)
    } else {
        1
    }
}

// ---------------------------------------------------------------------------
// P_SpawnMobj
// ---------------------------------------------------------------------------

/// `P_SpawnMobj`: a thing of `kind` at `(x, y)`, on its floor or ceiling or
/// at `z`, in its spawn state, located but **not yet linked** (the caller
/// knows the index). `reaction_time` starts at the info value; Doom halves
/// it on nightmare only.
pub fn spawn_mobj(w: World, kind: u32, x: Fixed, y: Fixed, z: SpawnZ) -> Mobj {
    spawn_in(level_of(w), w.states, kind, x, y, z)
}

/// [`spawn_mobj`] on a [`Level`].
pub fn spawn_in(lv: Level, states: StateTables, kind: u32, x: Fixed, y: Fixed, z: SpawnZ) -> Mobj {
    let info = info_of(kind);
    let loc = locate_boxed(lv.hot, Point { x, y });
    let floorz = Fixed { enc: rd(lv.floor, loc.sector) };
    let ceilingz = Fixed { enc: rd(lv.ceil, loc.sector) };
    let z = match z {
        SpawnZ::OnFloor => floorz,
        SpawnZ::OnCeiling => fixed::sub(ceilingz, info.height),
        SpawnZ::At(v) => v,
    };
    let (tics, _) = state_entry(states, info.spawnstate);
    let health: Option<i32> = info.spawnhealth.try_into();
    Mobj {
        kind,
        x,
        y,
        z,
        angle: 0,
        momx: fixed::ZERO,
        momy: fixed::ZERO,
        momz: fixed::ZERO,
        radius: info.radius,
        height: info.height,
        flags: info.flags,
        health: match health {
            Option::Some(h) => h,
            Option::None => 0,
        },
        state: info.spawnstate,
        tics,
        target: NO_MOBJ,
        reaction_time: info.reactiontime,
        threshold: 0,
        move_dir: 0,
        move_count: 0,
        // `place` links it once the caller has an index; until then the
        // record says "not linked" while remembering where it belongs.
        cell: NO_CELL,
        subsector: loc.subsector,
        sector: loc.sector,
        floorz,
        ceilingz,
        sight_expires: 0,
        sight_sector: 0,
        sight_ok: false,
    }
}

/// The blockmap cell a spawned thing belongs to (what `place` needs).
pub fn spawn_cell(w: World, m: @Mobj) -> u32 {
    locate_boxed(w.hot, Point { x: *m.x, y: *m.y }).cell
}

/// `P_SpawnMapThing` for one THINGS entry (skill already filtered by
/// `doom_map`): `None` for a player/deathmatch start or an unknown type.
/// Angle from the WAD, `MF_SPAWNCEILING` respected, `MTF_AMBUSH` →
/// `MF_AMBUSH`.
pub fn spawn_map_thing(w: World, thing: MapThing) -> Option<Mobj> {
    let kind = match kind_of_doomednum(thing.doomednum) {
        Option::Some(k) => k,
        Option::None => NO_MOBJ,
    };
    if kind == NO_MOBJ {
        Option::None
    } else {
        let z = if has(info_of(kind).flags, MF_SPAWNCEILING) {
            SpawnZ::OnCeiling
        } else {
            SpawnZ::OnFloor
        };
        let mut mo = spawn_in(level_of(w), w.states, kind, thing.position.x, thing.position.y, z);
        mo.angle = thing.angle;
        if has(thing.flags, MTF_AMBUSH) {
            mo.flags = mo.flags | MF_AMBUSH;
        }
        Option::Some(mo)
    }
}

/// `P_SpawnPlayer`'s mobj half: `MT_PLAYER` at `start`, facing `angle`.
pub fn spawn_player(w: World, start: Point, angle: Angle) -> Mobj {
    let mut mo = spawn_in(level_of(w), w.states, KIND_PLAYER, start.x, start.y, SpawnZ::OnFloor);
    mo.angle = angle;
    mo
}

// ---------------------------------------------------------------------------
// P_SpawnMissile / P_ExplodeMissile
// ---------------------------------------------------------------------------

/// The aim of `P_SpawnMissile`: the angle from `source` to `dest` (with the
/// random spread against a `MF_SHADOW` target), the momentum along it and
/// the vertical momentum: `(angle, momx, momy, momz)`.
fn missile_aim(
    rnd: Span<u8>,
    ref rng: Prng,
    from: Point,
    from_z: Fixed,
    to: Point,
    to_z: Fixed,
    fuzzy: bool,
    speed: Fixed,
) -> (Angle, Fixed, Fixed, Fixed) {
    let mut an = point_to_angle2(from.x, from.y, to.x, to.y);
    // Fuzzy player.
    if fuzzy {
        let (next, r) = rng.sub_random(rnd);
        rng = next;
        let spread: felt252 = r.into();
        // P_SubRandom() << 20 may be negative: add two turns so that the
        // felt `reduce` folds stays non-negative.
        an = bam::reduce(an.into() + spread * 0x100000 + 0x200000000);
    }
    let (s, c) = bam::sin_cos(an);
    let mut dist = approx_distance(fixed::sub(to.x, from.x), fixed::sub(to.y, from.y));
    dist = fixed::div(dist, speed);
    if !fixed::gt(dist, fixed::ZERO) {
        dist = fixed::FRACUNIT;
    }
    (an, fixed::mul(speed, c), fixed::mul(speed, s), fixed::div(fixed::sub(to_z, from_z), dist))
}

/// `P_SpawnMissile` for the imp's fireball (and any `MF_MISSILE` kind): aimed
/// from `source` (index `source_idx`) at `dest`, with the random spread
/// against a `MF_SHADOW` target, then `P_CheckMissileSpawn` (random tic
/// shortening, half a step forward, and an immediate `try_move` that
/// explodes it in a wall). The missile is returned **already placed**
/// (linked under index `me`), and the flag says whether it exploded on
/// spawn.
pub fn spawn_missile(
    w: World,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    ref rng: Prng,
    source: @Mobj,
    source_idx: u32,
    dest: @Mobj,
    kind: u32,
    me: u32,
    ref events: Array<MoveEvent>,
) -> (Mobj, bool) {
    let lv = level_of(w);
    let z = SpawnZ::At(fixed::add(*source.z, Fixed { enc: BIAS + 4 * 8 * 65536 }));
    let base = spawn_in(lv, w.states, kind, *source.x, *source.y, z);
    let speed = Fixed { enc: BIAS + info_of(kind).speed.into() };
    let (an, momx, momy, momz) = missile_aim(
        w.rndtable,
        ref rng,
        Point { x: *source.x, y: *source.y },
        *source.z,
        Point { x: *dest.x, y: *dest.y },
        *dest.z,
        has(*dest.flags, MF_SHADOW),
        speed,
    );
    // P_CheckMissileSpawn: the random tic shortening, then a little forward
    // so an angle can be computed if it immediately explodes.
    let tics = shorten_tics(w.rndtable, ref rng, base.tics);
    let x = fixed::add(base.x, half_of(momx));
    let y = fixed::add(base.y, half_of(momy));
    // Link it where it is, then let try_move relink it at the tested spot.
    let loc = locate_boxed(lv.hot, Point { x, y });
    move_cell(ref g, me, base.flags, kind, NO_CELL, loc.cell);
    let th = BoxTrait::new(
        Mobj {
            x,
            y,
            z: fixed::add(base.z, half_of(momz)),
            angle: an,
            momx,
            momy,
            momz,
            tics,
            target: source_idx, // where it came from
            cell: loc.cell,
            subsector: loc.subsector,
            sector: loc.sector,
            ..base,
        },
    );
    let (th, v) = try_move_in(lv, mobjs, ref g, th, me, x, y, ref events);
    let mut th = th.unbox();
    let exploded = !v.ok;
    if exploded {
        explode_in(w.states, w.rndtable, ref rng, ref th);
    }
    (th, exploded)
}

/// `P_ExplodeMissile`: stop, enter the death state (with the random tic
/// shortening), and stop being a missile.
pub fn explode_missile(w: World, ref rng: Prng, ref mo: Mobj) -> u32 {
    explode_in(w.states, w.rndtable, ref rng, ref mo)
}

/// [`explode_missile`] on the tables alone.
pub fn explode_in(states: StateTables, rnd: Span<u8>, ref rng: Prng, ref mo: Mobj) -> u32 {
    mo.momx = fixed::ZERO;
    mo.momy = fixed::ZERO;
    mo.momz = fixed::ZERO;
    let action = set_state_in(states, ref mo, info_of(mo.kind).deathstate);
    mo.tics = shorten_tics(rnd, ref rng, mo.tics);
    mo.flags = without(mo.flags, MF_MISSILE);
    action
}

/// The imp's fireball kind, for `A_TroopAttack`.
pub const FIREBALL: u32 = KIND_TROOPSHOT;

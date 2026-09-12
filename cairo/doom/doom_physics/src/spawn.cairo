// SPDX-License-Identifier: GPL-2.0-only
//! `P_SpawnMobj`, `P_SpawnMapThing`, `P_SpawnMissile`, `P_ExplodeMissile`
//! and `P_SetMobjState` (`p_mobj.c`).
//!
//! A spawn returns the new record; the caller puts it in the list
//! (`mobj::push`, or a removed slot) and links it (`position::link_thing`)
//! with the index it got. Puffs and blood are events (see `hitscan`).

use bam::{Angle, point_to_angle2};
use doom_map::MapThing;
use doom_things::tables::{KIND_PLAYER, KIND_TROOPSHOT};
use doom_things::{kind_of_doomednum, thing_info};
use fixed::{BIAS, Fixed};
use geom2d::{Point, approx_distance};
use prng::{Prng, PrngTrait};
use super::grid::ThingGrid;
use super::mobj::{
    MF_AMBUSH, MF_MISSILE, MF_SHADOW, MF_SPAWNCEILING, Mobj, NO_CELL, NO_MOBJ, has, without,
};
use super::movement::{MoveEvent, try_move};
use super::position::locate;
use super::world::World;

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

/// `P_SetMobjState` without the zero-tic loop (`fsm::enter`): returns the
/// action of the state entered, for the caller to run (`fsm::NO_ACTION` when
/// none). Entering state 0 (`S_NULL`) is Doom's "remove me" — the caller
/// checks `tics == FOREVER && state == 0`.
pub fn set_state(w: World, ref mo: Mobj, state: u32) -> u32 {
    let (tics, action) = fsm::enter(w.states, state);
    mo.state = state;
    mo.tics = tics;
    action
}

/// `P_SpawnMobj`: a thing of `kind` at `(x, y)`, on its floor or ceiling or
/// at `z`, in its spawn state, located but **not yet linked** (the caller
/// knows the index). `reaction_time` starts at the info value; Doom halves
/// it on nightmare only.
pub fn spawn_mobj(w: World, kind: u32, x: Fixed, y: Fixed, z: SpawnZ) -> Mobj {
    let info = thing_info(kind);
    let loc = locate(@w.map, Point { x, y });
    let floorz = Fixed { enc: *w.floor.at(loc.sector) };
    let ceilingz = Fixed { enc: *w.ceil.at(loc.sector) };
    let z = match z {
        SpawnZ::OnFloor => floorz,
        SpawnZ::OnCeiling => fixed::sub(ceilingz, info.height),
        SpawnZ::At(v) => v,
    };
    let (tics, _) = fsm::enter(w.states, info.spawnstate);
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
        health: info.spawnhealth.try_into().unwrap(),
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
    locate(@w.map, Point { x: *m.x, y: *m.y }).cell
}

/// `P_SpawnMapThing` for one THINGS entry (skill already filtered by
/// `doom_map`): `None` for a player/deathmatch start or an unknown type.
/// Angle from the WAD, `MF_SPAWNCEILING` respected, `MTF_AMBUSH` →
/// `MF_AMBUSH`.
pub fn spawn_map_thing(w: World, thing: MapThing) -> Option<Mobj> {
    let kind = match kind_of_doomednum(thing.doomednum) {
        Option::Some(k) => k,
        Option::None => { return Option::None; },
    };
    let z = if has(thing_info(kind).flags, MF_SPAWNCEILING) {
        SpawnZ::OnCeiling
    } else {
        SpawnZ::OnFloor
    };
    let mut mo = spawn_mobj(w, kind, thing.position.x, thing.position.y, z);
    mo.angle = thing.angle;
    if has(thing.flags, MTF_AMBUSH) {
        mo.flags = mo.flags | MF_AMBUSH;
    }
    Option::Some(mo)
}

/// `P_SpawnPlayer`'s mobj half: `MT_PLAYER` at `start`, facing `angle`.
pub fn spawn_player(w: World, start: Point, angle: Angle) -> Mobj {
    let mut mo = spawn_mobj(w, KIND_PLAYER, start.x, start.y, SpawnZ::OnFloor);
    mo.angle = angle;
    mo
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
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref rng: Prng,
    source: @Mobj,
    source_idx: u32,
    dest: @Mobj,
    kind: u32,
    me: u32,
    ref events: Array<MoveEvent>,
) -> (Mobj, bool) {
    let z = SpawnZ::At(fixed::add(*source.z, Fixed { enc: BIAS + 4 * 8 * 65536 }));
    let mut th = spawn_mobj(w, kind, *source.x, *source.y, z);
    let info = thing_info(kind);
    th.target = source_idx; // where it came from
    let mut an = point_to_angle2(*source.x, *source.y, *dest.x, *dest.y);
    // Fuzzy player.
    if has(*dest.flags, MF_SHADOW) {
        let (next, r) = rng.sub_random(w.rndtable);
        rng = next;
        let spread: felt252 = r.into();
        // P_SubRandom() << 20 may be negative: add two turns so that the
        // felt `reduce` folds stays non-negative.
        an = bam::reduce(an.into() + spread * 0x100000 + 0x200000000);
    }
    th.angle = an;
    let (s, c) = bam::sin_cos(an);
    let speed = Fixed { enc: BIAS + info.speed.into() };
    th.momx = fixed::mul(speed, c);
    th.momy = fixed::mul(speed, s);
    let mut dist = approx_distance(fixed::sub(*dest.x, *source.x), fixed::sub(*dest.y, *source.y));
    dist = fixed::div(dist, speed);
    if !fixed::gt(dist, fixed::ZERO) {
        dist = fixed::FRACUNIT;
    }
    th.momz = fixed::div(fixed::sub(*dest.z, *source.z), dist);
    // P_CheckMissileSpawn.
    let (next, roll) = rng.next(w.rndtable);
    rng = next;
    let shorten: u32 = (roll % 4).into();
    th.tics = if th.tics > shorten + 1 {
        th.tics - shorten
    } else {
        1
    };
    // Move a little forward so an angle can be computed if it immediately
    // explodes.
    th.x = fixed::add(th.x, super::movement::half_of(th.momx));
    th.y = fixed::add(th.y, super::movement::half_of(th.momy));
    th.z = fixed::add(th.z, super::movement::half_of(th.momz));
    // Link it where it is, then let try_move relink it at the tested spot.
    let loc = locate(@w.map, Point { x: th.x, y: th.y });
    super::position::place(ref g, ref th, me, loc);
    let x = th.x;
    let y = th.y;
    let exploded = !try_move(w, mobjs, ref g, ref th, me, x, y, ref events).ok;
    if exploded {
        explode_missile(w, ref rng, ref th);
    }
    (th, exploded)
}

/// `P_ExplodeMissile`: stop, enter the death state (with the random tic
/// shortening), and stop being a missile.
pub fn explode_missile(w: World, ref rng: Prng, ref mo: Mobj) -> u32 {
    mo.momx = fixed::ZERO;
    mo.momy = fixed::ZERO;
    mo.momz = fixed::ZERO;
    let action = set_state(w, ref mo, thing_info(mo.kind).deathstate);
    let (next, roll) = rng.next(w.rndtable);
    rng = next;
    let shorten: u32 = (roll % 4).into();
    mo.tics = if mo.tics > shorten + 1 {
        mo.tics - shorten
    } else {
        1
    };
    mo.flags = without(mo.flags, MF_MISSILE);
    action
}

/// The imp's fireball kind, for `A_TroopAttack`.
pub const FIREBALL: u32 = KIND_TROOPSHOT;

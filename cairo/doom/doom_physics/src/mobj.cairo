// SPDX-License-Identifier: GPL-2.0-only
//! The map object record (`mobj_t` of `p_mobj.h`), its flag word, its
//! serialization schema, and the fixed-capacity list it lives in.

use bam::Angle;
use fixed::Fixed;

// ---------------------------------------------------------------------------
// Flags (`MF_*` of p_mobj.h), the raw word `doom_things` generates
// ---------------------------------------------------------------------------

/// Call `P_TouchSpecialThing` when touched (an item).
pub const MF_SPECIAL: u32 = 1;
/// Blocks.
pub const MF_SOLID: u32 = 2;
/// Can be hit.
pub const MF_SHOOTABLE: u32 = 4;
/// Not in a sector's thing list (invisible, never used by the physics).
pub const MF_NOSECTOR: u32 = 8;
/// Not in the blockmap: not collided with, not shot.
pub const MF_NOBLOCKMAP: u32 = 16;
/// Deaf monster (`MTF_AMBUSH` on the map thing).
pub const MF_AMBUSH: u32 = 32;
/// Will try to attack right back.
pub const MF_JUSTHIT: u32 = 64;
/// Will take at least one step before attacking.
pub const MF_JUSTATTACKED: u32 = 128;
/// Hangs from the ceiling.
pub const MF_SPAWNCEILING: u32 = 256;
/// No gravity.
pub const MF_NOGRAVITY: u32 = 512;
/// Allowed to walk off a ledge.
pub const MF_DROPOFF: u32 = 1024;
/// Can pick up items (the player).
pub const MF_PICKUP: u32 = 2048;
/// Clips through walls.
pub const MF_NOCLIP: u32 = 4096;
/// Keeps sliding along walls (unused by Doom's own code).
pub const MF_SLIDE: u32 = 8192;
/// Floats toward its target.
pub const MF_FLOAT: u32 = 16384;
/// Skips height checks (teleporting).
pub const MF_TELEPORT: u32 = 32768;
/// A projectile.
pub const MF_MISSILE: u32 = 65536;
/// Dropped by a dying monster (no respawn).
pub const MF_DROPPED: u32 = 131072;
/// Partially invisible (the spectre).
pub const MF_SHADOW: u32 = 262144;
/// Bleeds puffs, not blood.
pub const MF_NOBLOOD: u32 = 524288;
/// A corpse.
pub const MF_CORPSE: u32 = 1048576;
/// Floating at its target's height.
pub const MF_INFLOAT: u32 = 2097152;
/// Counts toward the kill percentage.
pub const MF_COUNTKILL: u32 = 4194304;
/// Counts toward the item percentage.
pub const MF_COUNTITEM: u32 = 8388608;
/// A charging lost soul.
pub const MF_SKULLFLY: u32 = 16777216;
/// Not spawned in deathmatch.
pub const MF_NOTDMATCH: u32 = 33554432;

/// `flags & bit != 0`.
///
/// **Measured: ~10 steps** with the bitwise builtin (a second test on the
/// same word is ~8), against 25 for a `u32` division and 33 for the `u128`
/// form. A7's warning about masks is about *loops* of felt arithmetic; for
/// a single bit test the builtin is the cheapest form there is.
#[inline(always)]
pub fn has(flags: u32, bit: u32) -> bool {
    (flags & bit) != 0
}

/// `flags & !mask`.
#[inline(always)]
pub fn without(flags: u32, mask: u32) -> u32 {
    flags & (0xFFFFFFFF - mask)
}

// ---------------------------------------------------------------------------
// Sentinels and sizes
// ---------------------------------------------------------------------------

/// "No mobj": the `target` of a thing that has none, and the index a spawn
/// returns when the list is full.
pub const NO_MOBJ: u32 = 0xFFFF;
/// "Off the blockmap": the `cell` of a thing outside the grid (or not linked).
pub const NO_CELL: u32 = 0xFFFF;
/// The `kind` of a removed slot.
pub const KIND_NONE: u32 = 0xFFFF;
/// Fixed capacity of the mobj list (docs/G0.md D3 allows a fixed maximum of
/// live mobjs). Freedoom E1M1 spawns 209 things plus the player at skill 2;
/// missiles and dropped items reuse removed slots.
pub const MAX_MOBJS: u32 = 256;
/// Bias added to `health` when it is serialized (`health` is signed: a gibbed
/// corpse is below `-spawnhealth`), so the felt stays small and positive.
pub const HEALTH_BIAS: felt252 = 0x80000000;
/// Felts one mobj serializes to ([`push_felts`]).
pub const MOBJ_FELTS: u32 = 27;

// ---------------------------------------------------------------------------
// The record
// ---------------------------------------------------------------------------

/// One map object: `mobj_t` minus what the renderer derives from `state`
/// (sprite, frame) and what a single-player run never reads (`lastlook`,
/// the spawn point, `spawnpoint` respawning).
///
/// Every field is a value below 2^33 (`Fixed`), a `u32`, a `bool` or the
/// signed `i32` `health`; the record is 27 felts once serialized
/// ([`push_felts`]). Keeping it small matters: the tic loop copies every mobj
/// once per tic, at roughly one step per felt.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Mobj {
    /// `doom_things::tables::KIND_*`, or [`KIND_NONE`] for a removed slot.
    pub kind: u32,
    pub x: Fixed,
    pub y: Fixed,
    pub z: Fixed,
    pub angle: Angle,
    pub momx: Fixed,
    pub momy: Fixed,
    pub momz: Fixed,
    pub radius: Fixed,
    pub height: Fixed,
    /// `MF_*` word.
    pub flags: u32,
    /// Signed: `P_KillMobj` gibs below `-spawnhealth`.
    pub health: i32,
    /// `info.c` state id and tics left in it (`fsm`).
    pub state: u32,
    pub tics: u32,
    /// Index of the thing it is chasing/shooting, or [`NO_MOBJ`].
    pub target: u32,
    pub reaction_time: u32,
    /// Tics during which the current target is kept (`BASETHRESHOLD`).
    pub threshold: u32,
    /// `P_NewChaseDir` state.
    pub move_dir: u32,
    pub move_count: u32,
    /// Blockmap cell index (R2-A11), or [`NO_CELL`] when off the grid.
    pub cell: u32,
    /// BSP subsector and its sector, kept in sync by `set_thing_position`.
    pub subsector: u32,
    pub sector: u32,
    /// The floor and ceiling under the thing, as `P_TryMove` last saw them.
    pub floorz: Fixed,
    pub ceilingz: Fixed,
    /// R2-A3 sight cache: the last `check_sight` verdict, valid while
    /// `tic < sight_expires` and the target is still in `sight_sector`.
    pub sight_expires: u32,
    pub sight_sector: u32,
    pub sight_ok: bool,
}

/// Serialization schema, for `doom_game`'s `state_hash`: appends the
/// [`MOBJ_FELTS`] felts of `m` in this fixed order:
///
/// ```text
/// kind, x, y, z, angle, momx, momy, momz, radius, height, flags,
/// health + HEALTH_BIAS, state, tics, target, reaction_time, threshold,
/// move_dir, move_count, cell, subsector, sector, floorz, ceilingz,
/// sight_expires, sight_sector, sight_ok
/// ```
///
/// `Fixed` fields are their `enc` (below 2^33); every felt is non-negative
/// and below 2^72 (A7).
pub fn push_felts(ref out: Array<felt252>, m: @Mobj) {
    out.append((*m.kind).into());
    out.append(*m.x.enc);
    out.append(*m.y.enc);
    out.append(*m.z.enc);
    out.append((*m.angle).into());
    out.append(*m.momx.enc);
    out.append(*m.momy.enc);
    out.append(*m.momz.enc);
    out.append(*m.radius.enc);
    out.append(*m.height.enc);
    out.append((*m.flags).into());
    let health: felt252 = (*m.health).into();
    out.append(health + HEALTH_BIAS);
    out.append((*m.state).into());
    out.append((*m.tics).into());
    out.append((*m.target).into());
    out.append((*m.reaction_time).into());
    out.append((*m.threshold).into());
    out.append((*m.move_dir).into());
    out.append((*m.move_count).into());
    out.append((*m.cell).into());
    out.append((*m.subsector).into());
    out.append((*m.sector).into());
    out.append(*m.floorz.enc);
    out.append(*m.ceilingz.enc);
    out.append((*m.sight_expires).into());
    out.append((*m.sight_sector).into());
    out.append(if *m.sight_ok {
        1
    } else {
        0
    });
}

/// `true` for a slot `remove_mobj` has freed.
pub fn is_removed(m: @Mobj) -> bool {
    *m.kind == KIND_NONE
}

/// `true` when the thing lives in the blockmap (Doom links everything
/// without `MF_NOBLOCKMAP`, and lets `PIT_CheckThing` skip what cannot
/// collide).
pub fn in_blockmap(m: @Mobj) -> bool {
    !has(*m.flags, MF_NOBLOCKMAP) && *m.cell != NO_CELL && !is_removed(m)
}

// ---------------------------------------------------------------------------
// The list
// ---------------------------------------------------------------------------

/// Replace slot `i` of `mobjs` with `m`, rebuilding the array.
///
/// An `Array` has no random write, so this is O(n): **measured ~31 steps per
/// slot**, i.e. ~6 500 steps on a 210-mobj list. It is the fallback for a
/// write to a mobj the tic loop has already passed (a missile spawned later
/// in the list hitting the player at index 0); `doom_game` should batch such
/// patches and apply them in one rebuild at the end of the tic, and write
/// forward patches in place as its pass reaches the index. S1 §7 measured
/// the alternatives (a `Felt252Dict` costs 51 steps per insert/get pair
/// *plus* its squash, on every access, every tic) and this is the cheaper
/// shape for a list that is rebuilt once per tic anyway.
pub fn replace(ref mobjs: Array<Mobj>, i: u32, m: Mobj) {
    let mut old = mobjs.span();
    let mut out: Array<Mobj> = array![];
    let mut k: u32 = super::maputl::opaque_zero(i);
    while let Option::Some(o) = old.pop_front() {
        if k == i {
            out.append(m);
        } else {
            out.append(*o);
        }
        k = super::maputl::inc(k);
    }
    mobjs = out;
}

/// Append `m` as a new slot, or return [`NO_MOBJ`] when the list is full
/// (D3's fixed maximum). The caller then links it into the thing grid with
/// the returned index (`position::link_thing`).
pub fn push(ref mobjs: Array<Mobj>, m: Mobj) -> u32 {
    let n = mobjs.len();
    if n >= MAX_MOBJS {
        return NO_MOBJ;
    }
    mobjs.append(m);
    n
}

/// The index of the first removed slot, or [`NO_MOBJ`]. `doom_game` reuses
/// it for a spawn once the list is full (O(n), cold path).
pub fn first_free(mut mobjs: Span<Mobj>) -> u32 {
    let mut k: u32 = super::maputl::opaque_zero(mobjs.len());
    loop {
        match mobjs.pop_front() {
            Option::Some(m) => {
                if is_removed(m) {
                    break k;
                }
                k = super::maputl::inc(k);
            },
            Option::None => { break NO_MOBJ; },
        }
    }
}

/// The record of a removed slot: keeps the index stable for every `target`
/// that still points at it, costs nothing per tic, collides with nothing.
pub fn removed_mobj() -> Mobj {
    Mobj {
        kind: KIND_NONE,
        x: fixed::ZERO,
        y: fixed::ZERO,
        z: fixed::ZERO,
        angle: 0,
        momx: fixed::ZERO,
        momy: fixed::ZERO,
        momz: fixed::ZERO,
        radius: fixed::ZERO,
        height: fixed::ZERO,
        flags: MF_NOBLOCKMAP,
        health: 0,
        state: 0,
        tics: fsm::FOREVER,
        target: NO_MOBJ,
        reaction_time: 0,
        threshold: 0,
        move_dir: 0,
        move_count: 0,
        cell: NO_CELL,
        subsector: 0,
        sector: 0,
        floorz: fixed::ZERO,
        ceilingz: fixed::ZERO,
        sight_expires: 0,
        sight_sector: 0,
        sight_ok: false,
    }
}

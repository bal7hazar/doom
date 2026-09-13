// SPDX-License-Identifier: GPL-2.0-only
//! The movement, collision, sight, hitscan and damage rules of a Doom-like
//! tic, over `doom_map`'s compiled-in level and `doom_things`' tables:
//! the `p_map.c`, `p_maputl.c`, `p_mobj.c`, `p_sight.c` and `p_inter.c`
//! half of linuxdoom-1.10, as pure functions on a [`Mobj`] value.
//!
//! # Shape
//!
//! * A [`World`] is what a call reads: the level's hot spans (D24), the
//!   **current** sector heights, the state tables and the RNG table.
//! * A [`Mobj`] is a value; the list is an `Array<Mobj>` read as a
//!   `Span<Mobj>` and rebuilt by the tic loop (S1 §7). A [`ThingGrid`]
//!   holds the blockmap's per-cell thing lists, the one piece of mutable
//!   spatial state.
//! * A function that would touch *another* mobj reports it instead:
//!   [`MoveEvent`]s from a move, [`Hit`] from a shot, the dropped item from a
//!   kill. `doom_game` applies them.
//!
//! # Cost discipline
//!
//! Felt-first arithmetic below 2^72, no allocation in `try_move` (R2-A10:
//! cell lists are read in place), spans hoisted out of every loop (D24),
//! REJECT before any traversal (R2-A2), the mobj's cell carried in its state
//! (R2-A11), no `if`-tree tables. `bench/measure.py` asserts the per-function
//! budgets the README lists.

pub mod damage;
pub mod grid;
pub mod hitscan;
pub mod maputl;
pub mod mobj;
pub mod movement;
pub mod position;
pub mod ray;
pub mod sight;
pub mod spawn;

#[cfg(test)]
mod tests;
pub mod world;

pub use damage::{BASETHRESHOLD, DamageOutcome, damage_mobj, kill_mobj};
pub use grid::{ThingGrid, link, new_grid, rebuild, things_in, unlink};
pub use hitscan::{
    AIMRANGE, Aim, Hit, Intercept, MELEERANGE, MISSILERANGE, aim_line_attack, bleeds, line_attack,
    path_traverse,
};
pub use mobj::{
    HEALTH_BIAS, KIND_NONE, MAX_MOBJS, MF_AMBUSH, MF_CORPSE, MF_COUNTITEM, MF_COUNTKILL, MF_DROPOFF,
    MF_DROPPED, MF_FLOAT, MF_INFLOAT, MF_JUSTATTACKED, MF_JUSTHIT, MF_MISSILE, MF_NOBLOCKMAP,
    MF_NOBLOOD, MF_NOCLIP, MF_NOGRAVITY, MF_NOSECTOR, MF_NOTDMATCH, MF_PICKUP, MF_SHADOW,
    MF_SHOOTABLE, MF_SKULLFLY, MF_SLIDE, MF_SOLID, MF_SPAWNCEILING, MF_SPECIAL, MF_TELEPORT,
    MOBJ_FELTS, Mobj, NO_CELL, NO_MOBJ, first_free, has, in_blockmap, is_removed, push, push_felts,
    removed_mobj, replace, without,
};
pub use movement::{
    Blocker, Check, FRICTION, GRAVITY, MAXMOVE, MAXRADIUS, MAXSTEP, MoveEvent, STOPSPEED, Verdict,
    XyOutcome, ZOutcome, check_position, slide_move, slide_move_lite, try_move, xy_movement,
    z_movement,
};
pub use position::{
    Location, link_thing, locate, place, set_thing_position, subsector_from_root, subsector_in_cell,
    unset_thing_position,
};
pub use sight::{check_sight, check_sight_cached};
pub use spawn::{
    FIREBALL, MTF_AMBUSH, SpawnZ, explode_missile, set_state, spawn_cell, spawn_map_thing,
    spawn_missile, spawn_mobj, spawn_player,
};
pub use world::{World, ceiling_of, floor_of, with_heights, world_of};

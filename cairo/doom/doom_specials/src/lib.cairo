// SPDX-License-Identifier: GPL-2.0-only
//! Doom's sector specials: the doors, lifts, moving floors, lights, damaging
//! and secret sectors, switches and the exit of one compiled-in level.
//!
//! Semantics are linuxdoom-1.10's `p_spec.c`, `p_doors.c`, `p_plats.c`,
//! `p_floor.c`, `p_lights.c` and `p_switch.c`, restricted to the specials
//! Freedoom E1M1 actually carries (`tools/wad/REPORT-e1m1.md`): linedef
//! types **1, 2, 11, 23, 26, 62, 88, 117** and sector types **1, 7, 9, 12**.
//! Everything else — crushers, teleporters, donuts, elevators, glowing
//! lights, the level timer — is absent on purpose, and
//! `scripts/gen_specials.py` refuses to generate tables for a map that needs
//! one, rather than letting it fail silently at run time.
//!
//! # The three things this crate owns
//!
//! * **[`SpecialsState`]**, the dynamic half of the level: which planes have
//!   moved, which lights are on, which secrets are counted, which once-only
//!   linedefs are spent. `doom_map` is immutable; **every sector height read
//!   by `doom_physics` comes from here**, through [`heights`] + [`floor_of`]
//!   / [`ceiling_of`]. See [`state`] for the representation and its cost.
//! * **The thinkers**, as fixed-capacity typed lists rather than Doom's
//!   linked `thinkercap`: one [`Mover`] per running door, lift or floor
//!   (bounded by the number of sectors the map's specials can address — 20
//!   on E1M1) and one [`Light`] per light-special sector, spawned once and
//!   never removed. [`specials_ticker`] runs them all.
//! * **The triggers**: [`use_line`], [`cross_line`],
//!   [`player_in_special_sector`], and the `EV_Do*` spawners underneath.
//!
//! # What it asks of the rest of the game
//!
//! Two interfaces, both deliberately tiny, because `doom_physics` is written
//! in parallel with this crate and neither may depend on the other:
//!
//! * [`SectorBlocking`] — one method, `nofit(sector, floor, ceiling)`. It is
//!   `P_ChangeSector` (p_map.c): "with the planes there, is any mobj in this
//!   sector now too tall to fit?". A closing door reverses when it answers
//!   yes. [`NeverBlocked`] is the stand-in until `doom_physics` provides the
//!   real one.
//! * [`Actor`] — two booleans, `is_player` and `blue_key`, which is
//!   everything `P_UseSpecialLine` and `P_CrossSpecialLine` read off the
//!   `mobj_t` that touched the line.
//!
//! And two pieces of geometry stay on the other side of the fence: the
//! `USERANGE` trace of `P_UseLines` and the line-crossing test inside
//! `P_TryMove`. `doom_physics` finds the line; this crate says what it does.

pub mod compat;
pub mod level;
pub mod state;

#[cfg(test)]
mod tests;
pub mod thinkers;
pub mod triggers;

pub use compat::{Door, DoorState, start_opening, think_door};
pub use level::{NO_SLOT, SpecialsMap, load};
pub use state::{
    Heights, Light, LightKind, Mover, MoverKind, Phase, SectorTables, SpecialsState, ceiling_of,
    fields, floor_of, has_mover, hash, heights, heights_of, line_special, sector_ceiling,
    sector_floor, sector_light, sector_special, sector_tables, serialize,
};
pub use thinkers::{
    Event, NeverBlocked, SectorBlocking, event, move_plane, next_light_tic, slot_of,
    specials_ticker, speed_of, wait_of,
};
pub use triggers::{
    Actor, PlayerSector, SectorEffect, cross_line, ev_do_door, ev_do_floor, ev_do_plat,
    find_highest_floor_surrounding, find_lowest_ceiling_surrounding, find_lowest_floor_surrounding,
    monster, player, player_in_special_sector, sector_damage, spawn_specials, use_line,
};

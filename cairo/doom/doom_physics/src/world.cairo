// SPDX-License-Identifier: GPL-2.0-only
//! The read-only world a physics call sees: the level's hot spans (D24), the
//! **current** sector heights, and the `doom_things` tables.

use doom_map::{HotMap, LevelMap, hot};
use doom_things::{rndtable, states};
use fixed::Fixed;
use fsm::StateTables;

/// Everything a physics operation reads and never writes.
///
/// `floor`/`ceil` are the *current* sector heights (`Fixed::enc` per
/// sector): a door or a lift changes them, so they come from the game state
/// rather than from `doom_map`'s constants — [`world_of`] starts them at the
/// level's own values. `hot` is the same `HotMap` as `map`, behind one
/// pointer: it is what every internal call of this crate carries
/// (docs/spikes/S7.md — a `Box` costs one felt per call and per loop
/// iteration where the struct costs ~30, and reading a field out of it is
/// free), while `map` stays for the callers that address the spans
/// directly (`set_thing_position(@w.map, ..)`).
#[derive(Copy, Drop)]
pub struct World {
    pub map: HotMap,
    /// `map` behind one pointer (S7); built once by [`world_of`].
    pub hot: Box<HotMap>,
    /// Current floor height of every sector, `Fixed::enc`.
    pub floor: Span<felt252>,
    /// Current ceiling height of every sector, `Fixed::enc`.
    pub ceil: Span<felt252>,
    /// `doom_things::states()`, the `info.c` machine.
    pub states: StateTables,
    /// `doom_things::rndtable()`, the `P_Random` table.
    pub rndtable: Span<u8>,
}

/// What the geometry reads, and what every internal function of the crate
/// takes instead of a [`World`]: five felts.
#[derive(Copy, Drop)]
pub struct Level {
    pub hot: Box<HotMap>,
    pub floor: Span<felt252>,
    pub ceil: Span<felt252>,
}

/// The [`Level`] of a world. Inlined: at a public entry point `w` is a
/// parameter, so this reads three fields and copies nothing.
#[inline(always)]
pub fn level_of(w: World) -> Level {
    Level { hot: w.hot, floor: w.floor, ceil: w.ceil }
}

/// The world of a freshly loaded level: every sector at its map height.
pub fn world_of(m: @LevelMap) -> World {
    let map = hot(m);
    World {
        map,
        hot: BoxTrait::new(map),
        floor: *m.s_floor,
        ceil: *m.s_ceil,
        states: states(),
        rndtable: rndtable(),
    }
}

/// The same world with other sector heights (what `doom_game` passes once a
/// door has moved).
pub fn with_heights(w: World, floor: Span<felt252>, ceil: Span<felt252>) -> World {
    World { map: w.map, hot: w.hot, floor, ceil, states: w.states, rndtable: w.rndtable }
}

/// Current floor height of `sector`.
pub fn floor_of(floor: Span<felt252>, sector: u32) -> Fixed {
    Fixed { enc: *floor.at(sector) }
}

/// Current ceiling height of `sector`.
pub fn ceiling_of(ceil: Span<felt252>, sector: u32) -> Fixed {
    Fixed { enc: *ceil.at(sector) }
}

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
/// level's own values. This is a struct of spans, so like `doom_map::HotMap`
/// it is passed **once per top-level operation** (`try_move`, `check_sight`,
/// `line_attack`); every inner loop hoists the fields it needs into locals
/// first (D24: the copy of a ~50-felt bundle costs ~50 steps per call).
#[derive(Copy, Drop)]
pub struct World {
    pub map: HotMap,
    /// Current floor height of every sector, `Fixed::enc`.
    pub floor: Span<felt252>,
    /// Current ceiling height of every sector, `Fixed::enc`.
    pub ceil: Span<felt252>,
    /// `doom_things::states()`, the `info.c` machine.
    pub states: StateTables,
    /// `doom_things::rndtable()`, the `P_Random` table.
    pub rndtable: Span<u8>,
}

/// The world of a freshly loaded level: every sector at its map height.
pub fn world_of(m: @LevelMap) -> World {
    World {
        map: hot(m), floor: *m.s_floor, ceil: *m.s_ceil, states: states(), rndtable: rndtable(),
    }
}

/// The same world with other sector heights (what `doom_game` passes once a
/// door has moved).
pub fn with_heights(w: World, floor: Span<felt252>, ceil: Span<felt252>) -> World {
    World { map: w.map, floor, ceil, states: w.states, rndtable: w.rndtable }
}

/// Current floor height of `sector`.
pub fn floor_of(floor: Span<felt252>, sector: u32) -> Fixed {
    Fixed { enc: *floor.at(sector) }
}

/// Current ceiling height of `sector`.
pub fn ceiling_of(ceil: Span<felt252>, sector: u32) -> Fixed {
    Fixed { enc: *ceil.at(sector) }
}

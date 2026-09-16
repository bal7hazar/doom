// SPDX-License-Identifier: GPL-2.0-only
//! Worst-case journal history without any change to committed state.
//! Subtract main(n, false) from main(n, true) to isolate boundary hashing.
//! Every unlink/link pair leaves the chosen singleton cell unchanged.

#[executable]
fn main(updates: u32, measure_hash: bool) -> felt252 {
    let mut game = doom_game::genesis(doom_map::LevelId::E1M1);
    let cell = *game.mobjs.at(0).cell;
    let before = doom_physics::things_in(ref game.grid, cell);
    assert(before.len() == 1 && *before.at(0) == 0, 'singleton player cell');
    let mut n = updates;
    while n != 0 {
        doom_physics::unlink(ref game.grid, cell, 0);
        doom_physics::link(ref game.grid, cell, 0);
        n -= 1;
    }
    if measure_hash {
        doom_game::hash(@game)
    } else {
        0
    }
}

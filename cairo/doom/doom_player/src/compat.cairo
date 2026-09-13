// SPDX-License-Identifier: GPL-2.0-only
//! **Transitional** (D17): the Phase-0 skeleton's `PlayerState`, `spawn`,
//! `think` and `apply_damage`, kept only because `doom_game`'s own skeleton
//! imports them. Nothing in the real code path touches this module; it goes
//! with the PR that ports `doom_game` onto [`super::state::Player`].

use doom_things::tables::KIND_PLAYER;
use doom_things::thing_info;
use geom2d::Point;
use ticcmd::TicCmd;

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct PlayerState {
    pub position: Point,
    pub health: u32,
}

pub fn spawn(position: Point) -> PlayerState {
    PlayerState { position, health: thing_info(KIND_PLAYER).spawnhealth }
}

/// One tic of movement: `cmd.forward` map units along `y`, no collision.
pub fn think(player: PlayerState, cmd: TicCmd) -> PlayerState {
    let delta = fixed::from_int(cmd.forward);
    PlayerState {
        position: Point { x: player.position.x, y: fixed::add(player.position.y, delta) },
        health: player.health,
    }
}

/// Apply `amount` damage, saturating at zero health.
pub fn apply_damage(player: PlayerState, amount: u32) -> PlayerState {
    let health = if amount >= player.health {
        0
    } else {
        player.health - amount
    };
    PlayerState { position: player.position, health }
}

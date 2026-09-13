// SPDX-License-Identifier: GPL-2.0-only
//! **Skeleton** (rewritten in P1.7 on top of `doom_physics`): a player is a
//! position and a health, moved along `y` by `cmd.forward` with no collision.

use doom_things::tables::KIND_PLAYER;
use doom_things::thing_info;
use fixed::{add, from_int};
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

/// One tic of movement: `cmd.forward` map units along `y`. Collision is
/// `doom_physics::try_move`'s job and is wired in by P1.7.
pub fn think(player: PlayerState, cmd: TicCmd) -> PlayerState {
    let delta = from_int(cmd.forward);
    PlayerState {
        position: Point { x: player.position.x, y: add(player.position.y, delta) },
        health: player.health,
    }
}

/// Apply `amount` damage, saturating at zero health (never underflows).
pub fn apply_damage(player: PlayerState, amount: u32) -> PlayerState {
    let health = if amount >= player.health {
        0
    } else {
        player.health - amount
    };
    PlayerState { position: player.position, health }
}

#[cfg(test)]
mod tests {
    use fixed::from_int;
    use geom2d::Point;
    use ticcmd::TicCmd;
    use super::{apply_damage, spawn, think};

    fn origin() -> Point {
        Point { x: from_int(0), y: from_int(0) }
    }

    fn cmd(forward: i64) -> TicCmd {
        TicCmd { forward, side: 0, angle_turn: 0, buttons: 0 }
    }

    #[test]
    fn test_spawn_has_doom_health() {
        assert(spawn(origin()).health == 100, 'spawns with 100');
    }

    #[test]
    fn test_think_moves_forward() {
        let moved = think(spawn(origin()), cmd(10));
        assert(moved.position.y == from_int(10), 'moved forward');
    }

    #[test]
    fn test_apply_damage_saturates_at_zero() {
        let player = spawn(origin());
        let dead = apply_damage(player, player.health + 1000);
        assert(dead.health == 0, 'saturates at zero');
    }

    #[test]
    fn test_apply_damage_monotonically_decreases() {
        let player = spawn(origin());
        let hurt = apply_damage(player, 5);
        assert(hurt.health <= player.health, 'health does not increase');
    }
}

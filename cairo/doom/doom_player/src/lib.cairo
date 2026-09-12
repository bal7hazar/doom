// SPDX-License-Identifier: GPL-2.0-or-later

use doom_map::Level;
use doom_physics::can_move;
use doom_things::{MobjType, info_of};
use fixed::{add, from_int};
use geom2d::Point;
use ticcmd::TicCmd;

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct PlayerState {
    pub position: Point,
    pub health: u32,
}

pub fn spawn() -> PlayerState {
    let info = info_of(MobjType::Player);
    PlayerState { position: Point { x: from_int(0), y: from_int(0) }, health: info.health }
}

/// One tic of `P_PlayerThink`'s movement path: attempt to move forward by
/// `cmd.forward` fixed-point units along y; rejected moves leave the
/// player exactly where it was (no partial sliding yet, see README).
pub fn think(level: @Level, player: PlayerState, cmd: TicCmd) -> PlayerState {
    let delta = from_int(cmd.forward);
    let new_position = Point { x: player.position.x, y: add(player.position.y, delta) };
    if can_move(level, player.position, new_position) {
        PlayerState { position: new_position, health: player.health }
    } else {
        player
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
    use doom_map::sample_level;
    use fixed::from_int;
    use geom2d::Point;
    use ticcmd::TicCmd;
    use super::{PlayerState, apply_damage, spawn, think};

    fn cmd(forward: i64) -> TicCmd {
        TicCmd { forward, side: 0, angle_turn: 0, buttons: 0 }
    }

    #[test]
    fn test_spawn_has_positive_health() {
        let player = spawn();
        assert(player.health > 0, 'spawns alive');
    }

    #[test]
    fn test_think_moves_when_clear() {
        let level = sample_level();
        // Start well clear of the sample blocking line (y=0, x in [0,64])
        // so this step neither starts on it nor crosses it.
        let player = PlayerState {
            position: Point { x: from_int(32), y: from_int(50) }, health: 100,
        };
        let moved = think(@level, player, cmd(10));
        assert(moved.position.y != player.position.y, 'moved forward');
    }

    #[test]
    fn test_think_blocked_by_wall_stays_put() {
        let level = sample_level();
        // Sample line blocks y=0 between x in [0,64]; moving from below it
        // to above it is rejected and the player stays put.
        let player = PlayerState {
            position: Point { x: from_int(32), y: from_int(-10) }, health: 100,
        };
        let moved = think(@level, player, cmd(20));
        assert(moved.position == player.position, 'blocked stays put');
    }

    #[test]
    fn test_apply_damage_saturates_at_zero() {
        let player = spawn();
        let dead = apply_damage(player, player.health + 1000);
        assert(dead.health == 0, 'saturates at zero');
    }

    #[test]
    fn test_apply_damage_monotonically_decreases() {
        let player = spawn();
        let hurt = apply_damage(player, 5);
        assert(hurt.health <= player.health, 'health does not increase');
    }
}

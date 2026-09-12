// SPDX-License-Identifier: GPL-2.0-only
//! **Skeleton** (rewritten in P1.9): the aggregate `GameState`, its genesis
//! from `doom_map`'s player start, one tic of the player skeleton and the
//! canonical serialization/hash.

use doom_map::{LevelId, genesis as level_genesis, load, sector_floor};
use doom_monsters::{MonsterState, spawn as spawn_monster};
use doom_player::{PlayerState, spawn as spawn_player, think as player_think};
use doom_specials::{Door, SectorHeights, start_opening};
use doom_things::tables::KIND_POSSESSED;
use fixed::{from_int, to_raw};
use geom2d::Point;
use segment::{SegmentOutput, chain_commands};
use state_hash::hash_state;
use ticcmd::TicCmd;

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct GameState {
    pub tic: u32,
    pub player: PlayerState,
}

/// Tic 0: the player at E1M1's Player 1 start.
pub fn genesis() -> GameState {
    let g = level_genesis(LevelId::E1M1);
    GameState { tic: 0, player: spawn_player(g.start) }
}

pub fn step_tic(state: GameState, cmd: TicCmd) -> GameState {
    GameState { tic: state.tic + 1, player: player_think(state.player, cmd) }
}

/// Canonical felt serialization of a `GameState`, in a fixed field order.
pub fn serialize(state: GameState) -> Array<felt252> {
    let mut out: Array<felt252> = array![];
    out.append(state.tic.into());
    // `fixed::Fixed` is an offset-encoded felt (`enc`): serializing the
    // encoded value keeps every serialized word non-negative and below
    // 2^33, which is what the provability bound of A7 asks for.
    out.append(state.player.position.x.enc);
    out.append(state.player.position.y.enc);
    out.append(state.player.health.into());
    out
}

pub fn hash_of(state: GameState) -> felt252 {
    hash_state(serialize(state).span())
}

/// Aggregation helper: spawn one zombieman from `doom_monsters` — exercises
/// the `doom_monsters` edge of the dependency graph this crate assembles.
pub fn spawn_sample_monster() -> MonsterState {
    spawn_monster(KIND_POSSESSED, Point { x: from_int(100), y: from_int(0) })
}

/// Aggregation helper: start opening E1M1's sector 0 as a door, exercising
/// the `doom_specials` edge of the dependency graph.
pub fn spawn_sample_door() -> Door {
    let m = load(LevelId::E1M1);
    let floor: i64 = to_raw(sector_floor(@m, 0)).try_into().unwrap();
    let sector = SectorHeights { floor_height: floor, ceiling_height: floor };
    start_opening(sector, floor + 100 * 65536, 20 * 65536)
}

/// The header `doom_run::run_segment` will attach real public outputs to.
pub fn run_segment_header(h_in: felt252, tic_start: u32, cmds: Span<TicCmd>) -> SegmentOutput {
    chain_commands(h_in, tic_start, cmds)
}

#[cfg(test)]
mod tests {
    use ticcmd::TicCmd;
    use super::{
        genesis, hash_of, run_segment_header, spawn_sample_door, spawn_sample_monster, step_tic,
    };

    #[test]
    fn test_genesis_starts_at_tic_zero() {
        let state = genesis();
        assert(state.tic == 0, 'genesis starts at tic 0');
    }

    #[test]
    fn test_step_tic_advances_tic_counter() {
        let state = genesis();
        let cmd = TicCmd { forward: 0, side: 0, angle_turn: 0, buttons: 0 };
        let next = step_tic(state, cmd);
        assert(next.tic == 1, 'tic advances by one');
    }

    #[test]
    fn test_hash_of_is_deterministic_and_sensitive_to_state() {
        let a = genesis();
        let mut b = genesis();
        b.tic = 1;
        assert(hash_of(a) == hash_of(genesis()), 'deterministic');
        assert(hash_of(a) != hash_of(b), 'sensitive to state');
    }

    #[test]
    fn test_aggregation_wires_monsters_and_specials() {
        let monster = spawn_sample_monster();
        assert(!monster.awake, 'spawns asleep');
        let door = spawn_sample_door();
        assert(door.sector.ceiling_height != door.target_ceiling, 'door has room to open');
    }

    #[test]
    fn test_run_segment_header_chains_like_segment_crate() {
        let cmds: Array<TicCmd> = array![TicCmd { forward: 1, side: 0, angle_turn: 0, buttons: 0 }];
        let out = run_segment_header(0, 0, cmds.span());
        assert(out.tic_end == 1, 'one tic elapsed');
    }
}

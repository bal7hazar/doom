// SPDX-License-Identifier: GPL-2.0-or-later

use doom_map::{Level, sector_at};
use doom_monsters::{MonsterState, spawn as spawn_monster};
use doom_player::{PlayerState, spawn as spawn_player, think as player_think};
use doom_specials::{Door, start_opening};
use doom_things::MobjType;
use fixed::from_int;
use fsm::StateDef;
use geom2d::Point;
use segment::{SegmentOutput, chain_commands};
use state_hash::hash_state;
use ticcmd::TicCmd;

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct GameState {
    pub tic: u32,
    pub player: PlayerState,
}

pub fn genesis() -> GameState {
    GameState { tic: 0, player: spawn_player() }
}

pub fn step_tic(level: @Level, state: GameState, cmd: TicCmd) -> GameState {
    GameState { tic: state.tic + 1, player: player_think(level, state.player, cmd) }
}

/// Canonical felt serialization of a `GameState`, in a fixed field order.
pub fn serialize(state: GameState) -> Array<felt252> {
    let mut out: Array<felt252> = array![];
    out.append(state.tic.into());
    out.append(state.player.position.x.raw.into());
    out.append(state.player.position.y.raw.into());
    out.append(state.player.health.into());
    out
}

pub fn hash_of(state: GameState) -> felt252 {
    hash_state(serialize(state).span())
}

/// Aggregation helper: spawn one monster from `doom_monsters`, using
/// `doom_things`'s catalogue and an `fsm` state table -- exercises the
/// `doom_monsters` edge of the dependency graph this crate assembles.
pub fn spawn_sample_monster(states: Span<StateDef>) -> MonsterState {
    spawn_monster(MobjType::Zombieman, Point { x: from_int(100), y: from_int(0) }, states, 0)
}

/// Aggregation helper: start opening the level's first sector as a door,
/// exercising the `doom_specials` edge of the dependency graph.
pub fn spawn_sample_door(level: @Level) -> Door {
    let sector = sector_at(level, 0);
    start_opening(sector, sector.ceiling_height + 100, 20)
}

/// The header `doom_run::run_segment` will attach real public outputs to.
pub fn run_segment_header(h_in: felt252, tic_start: u32, cmds: Span<TicCmd>) -> SegmentOutput {
    chain_commands(h_in, tic_start, cmds)
}

#[cfg(test)]
mod tests {
    use doom_map::sample_level;
    use fsm::StateDef;
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
        let level = sample_level();
        let state = genesis();
        let cmd = TicCmd { forward: 0, side: 0, angle_turn: 0, buttons: 0 };
        let next = step_tic(@level, state, cmd);
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
        let level = sample_level();
        let mut states = array![];
        states.append(StateDef { duration: 4, next: 0 });
        let monster = spawn_sample_monster(states.span());
        assert(!monster.awake, 'spawns asleep');
        let door = spawn_sample_door(@level);
        assert(door.sector.ceiling_height != door.target_ceiling, 'door has room to open');
    }

    #[test]
    fn test_run_segment_header_chains_like_segment_crate() {
        let cmds: Array<TicCmd> = array![TicCmd { forward: 1, side: 0, angle_turn: 0, buttons: 0 }];
        let out = run_segment_header(0, 0, cmds.span());
        assert(out.tic_end == 1, 'one tic elapsed');
    }
}

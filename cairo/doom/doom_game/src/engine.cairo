// SPDX-License-Identifier: GPL-2.0-only
//! D15: the one `SegmentEngine` impl that lets the generic
//! `segment::run_segment` drive the game. `C` is the ticcmd **word**
//! (`step_tic` decodes it), so `word` is the identity and the input-log
//! commitment folds exactly the felts the client journals.

use segment::{SegmentEngine, SegmentOutput, Stats, Status};
use super::state::{GameState, hash};
use super::tic::step_tic;

/// D14's counters, read off the player record (`P_KillMobj`'s
/// `killcount`, `P_TouchSpecialThing`'s `itemcount`,
/// `P_PlayerInSpecialSector`'s `secretcount`).
pub fn stats_of(s: @GameState) -> Stats {
    Stats { kills: *s.player.killcount, items: *s.player.itemcount, secrets: *s.player.secretcount }
}

pub impl GameEngine of SegmentEngine<GameState, felt252> {
    fn step(state: GameState, cmd: felt252) -> (GameState, Status) {
        step_tic(state, cmd)
    }
    fn hash(state: @GameState) -> felt252 {
        hash(state)
    }
    fn stats(state: @GameState) -> Stats {
        stats_of(state)
    }
    fn word(cmd: @felt252) -> felt252 {
        *cmd
    }
}

/// `segment::run_segment` over the game: up to `max_tics` of `cmds` from
/// `state`, the state hashed once before and once after (D16), the ten
/// public felts of D14.
pub fn run_segment(
    state: GameState, cmds: Span<felt252>, tic_start: u32, max_tics: u32,
) -> (GameState, SegmentOutput) {
    segment::run_segment::<GameState, felt252, GameEngine>(state, cmds, tic_start, max_tics)
}

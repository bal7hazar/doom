// SPDX-License-Identifier: GPL-2.0-only
//! Isolated S11 wrappers. Every engine operation is imported from production;
//! only the candidate's state hash differs. No production golden is replaced.
mod hash9;
use doom_game::{GameEngine, GameState};
use segment::{SegmentEngine, SegmentOutput, Stats, Status};

impl Blake9Engine of SegmentEngine<GameState, felt252> {
    fn step(state: GameState, cmd: felt252) -> (GameState, Status) {
        doom_game::step_tic(state, cmd)
    }
    fn hash(state: @GameState) -> felt252 {
        hash9::hash(doom_game::serialize(state).span()).expect('schema2 domain')
    }
    fn stats(state: @GameState) -> Stats {
        doom_game::stats_of(state)
    }
    fn word(cmd: @felt252) -> felt252 {
        *cmd
    }
}

// Minimal shared reproduction of doom_run's admission plumbing. Malformed
// states retain production's Poseidon ABORT commitment, including out-of-domain
// felts: BLAKE9 is defined only for valid schema-2 records.
fn aborted(state: Span<felt252>, tic_start: u32) -> SegmentOutput {
    let h = state_hash::seal(state);
    SegmentOutput {
        version: segment::VERSION,
        h_in: h,
        h_out: h,
        tic_start,
        tic_end: tic_start,
        status: Status::Abort,
        inputs_commitment: state_hash::inputs_seed(),
        stats: Stats { kills: 0, items: 0, secrets: 0 },
    }
}

fn evaluate<impl Engine: SegmentEngine<GameState, felt252>>(
    state: Span<felt252>, words: Span<felt252>, tic_start: u32, max_tics: u32,
) -> (Option<GameState>, SegmentOutput) {
    match doom_game::from_felts(state) {
        Option::Some(game) => {
            if game.leveltime != tic_start {
                return (Option::None, aborted(state, tic_start));
            }
            let (next, out) = segment::run_segment::<
                GameState, felt252, Engine,
            >(game, words, tic_start, max_tics);
            (Option::Some(next), out)
        },
        Option::None => (Option::None, aborted(state, tic_start)),
    }
}

#[executable]
fn segment_poseidon(
    state: Span<felt252>, words: Span<felt252>, tic_start: u32, max_tics: u32,
) -> SegmentOutput {
    let (_, out) = evaluate::<GameEngine>(state, words, tic_start, max_tics);
    out
}
#[executable]
fn segment_blake9(
    state: Span<felt252>, words: Span<felt252>, tic_start: u32, max_tics: u32,
) -> SegmentOutput {
    let (_, out) = evaluate::<Blake9Engine>(state, words, tic_start, max_tics);
    out
}

fn inspect<impl Engine: SegmentEngine<GameState, felt252>>(
    state: Span<felt252>, words: Span<felt252>, tic_start: u32, max_tics: u32,
) -> (SegmentOutput, Array<felt252>, Array<felt252>) {
    let (game, out) = evaluate::<Engine>(state, words, tic_start, max_tics);
    match game {
        Option::Some(g) => (out, doom_game::serialize(@g), doom_game::snapshot(@g)),
        Option::None => (out, array![], array![]),
    }
}
#[executable]
fn inspect_poseidon(
    state: Span<felt252>, words: Span<felt252>, tic_start: u32, max_tics: u32,
) -> (SegmentOutput, Array<felt252>, Array<felt252>) {
    inspect::<GameEngine>(state, words, tic_start, max_tics)
}
#[executable]
fn inspect_blake9(
    state: Span<felt252>, words: Span<felt252>, tic_start: u32, max_tics: u32,
) -> (SegmentOutput, Array<felt252>, Array<felt252>) {
    inspect::<Blake9Engine>(state, words, tic_start, max_tics)
}
#[executable]
fn genesis_poseidon() -> (Array<felt252>, felt252) {
    let g = doom_game::genesis(doom_map::LevelId::E1M1);
    let state = doom_game::serialize(@g);
    let hash = state_hash::seal(state.span());
    (state, hash)
}
#[executable]
fn genesis_blake9() -> (Array<felt252>, felt252) {
    let g = doom_game::genesis(doom_map::LevelId::E1M1);
    let state = doom_game::serialize(@g);
    let hash = hash9::hash(state.span()).expect('schema2 domain');
    (state, hash)
}
#[executable]
fn hash_poseidon(data: Span<felt252>) -> felt252 {
    state_hash::seal(data)
}
#[executable]
fn hash_blake9(data: Span<felt252>) -> Option<felt252> {
    hash9::hash(data)
}
#[executable]
fn vector_blake9(data: Span<felt252>) -> (u32, [u32; 8], felt252) {
    match hash9::digest(data) {
        Option::Some(digest) => (1, digest, hash9::reduce(digest)),
        Option::None => (0, [0, 0, 0, 0, 0, 0, 0, 0], 0),
    }
}

#[cfg(test)]
mod tests;

// SPDX-License-Identifier: GPL-2.0-only
//! The provable entry points (PLAN.md §3.1 task 7, D14, D26).
//!
//! * [`run_segment`] — **the proved program**: `K` tics of the game from a
//!   serialized state, returning the ten public felts of D14. `h_in` is
//!   computed from the state actually used (no trusted argument): a segment
//!   whose state is not the previous segment's output fails the
//!   `h_out[i] = h_in[i+1]` chain on its own.
//! * [`step_tic`] — the real-time Worker's call: `n` tics from a serialized
//!   state, returning the status, the new state and the render snapshot.
//! * [`genesis`] — the state a run starts from, and its hash.
//!
//! Every function is total: a malformed state or an inconsistent
//! `tic_start` yields an `ABORT` output (or an empty state with status 3),
//! never a trap (R4-A2).

mod wire;
use doom_game::{GameState, from_felts, serialize, snapshot};
use doom_map::LevelId;
use segment::{SegmentOutput, Stats, Status, status_felt};
use state_hash::{inputs_seed, seal};
use wire::{Felts, felts};

/// D14's `status = 3`.
const ABORT: felt252 = 3;

/// The level of a `genesis` argument. Only E1M1 exists; anything else is
/// `None`.
fn level_of(id: u32) -> Option<LevelId> {
    if id == 0 {
        Option::Some(LevelId::E1M1)
    } else {
        Option::None
    }
}

/// An `ABORT` output for an input that never became a game: `h_in` and
/// `h_out` are the Poseidon hash of the felts that were given, so the
/// output still says what it was about; no tic ran; the log commitment is
/// the empty log's.
fn aborted(state: Span<felt252>, tic_start: u32) -> SegmentOutput {
    let h = seal(state);
    SegmentOutput {
        version: segment::VERSION,
        h_in: h,
        h_out: h,
        tic_start,
        tic_end: tic_start,
        status: Status::Abort,
        inputs_commitment: inputs_seed(),
        stats: Stats { kills: 0, items: 0, secrets: 0 },
    }
}

/// `run_segment(state, words, tic_start, max_tics) -> [10 felts]`.
///
/// `state` is a serialized `GameState` (`doom_game::serialize`, header
/// included); `words` the segment's ticcmd words, one felt each;
/// `tic_start` must equal the state's `leveltime` (else `ABORT`);
/// `max_tics` caps the tics run (D26: the planner cuts by `resources()`).
#[executable]
fn run_segment(
    state: Span<felt252>, words: Span<felt252>, tic_start: u32, max_tics: u32,
) -> SegmentOutput {
    run_segment_impl(state, words, tic_start, max_tics)
}

/// [`run_segment`] on spans, for the tests.
pub fn run_segment_impl(
    state: Span<felt252>, words: Span<felt252>, tic_start: u32, max_tics: u32,
) -> SegmentOutput {
    match from_felts(state) {
        Option::Some(game) => {
            if game.leveltime != tic_start {
                return aborted(state, tic_start);
            }
            let (_, out) = doom_game::run_segment(game, words, tic_start, max_tics);
            out
        },
        Option::None => aborted(state, tic_start),
    }
}

/// `step_tic(state, words) -> (status, state_out, snapshot)`.
///
/// Runs one tic per word (the Worker passes one; the pipeline may pass a
/// whole segment to recover its end state). Stops at the first terminal
/// status. On a malformed state: `(3, [], [])`.
#[executable]
fn step_tic(state: Span<felt252>, words: Span<felt252>) -> (felt252, Felts, Felts) {
    let (status, state_out, snapshot_out) = step_tic_impl(state, words);
    (status, felts(state_out.span()), felts(snapshot_out.span()))
}

/// [`step_tic`] on spans, for the tests.
pub fn step_tic_impl(
    state: Span<felt252>, mut words: Span<felt252>,
) -> (felt252, Array<felt252>, Array<felt252>) {
    match from_felts(state) {
        Option::Some(game) => {
            let mut g: GameState = game;
            let mut status = g.status;
            while let Option::Some(w) = words.pop_front() {
                let (next, st) = doom_game::step_tic(g, *w);
                g = next;
                status = st;
                if status != Status::Running {
                    break;
                }
            }
            (status_felt(status), serialize(@g), snapshot(@g))
        },
        Option::None => (ABORT, array![], array![]),
    }
}

/// `genesis(level) -> (state, h)`: the serialized state a run starts from
/// and its hash — `h_in` of the first segment. Level 0 is E1M1; an unknown
/// level gives `([], 0)`.
#[executable]
fn genesis(level: u32) -> (Felts, felt252) {
    let (state, hash) = genesis_impl(level);
    (felts(state.span()), hash)
}

/// [`genesis`], for the tests.
pub fn genesis_impl(level: u32) -> (Array<felt252>, felt252) {
    match level_of(level) {
        Option::Some(id) => {
            let g = doom_game::genesis(id);
            let state = serialize(@g);
            let h = seal(state.span());
            (state, h)
        },
        Option::None => (array![], 0),
    }
}

#[cfg(test)]
mod tests {
    use doom_map::LevelId;
    use segment::{Status, to_felts};
    use ticcmd::{TicCmd, encode};
    use super::{genesis_impl, run_segment_impl, step_tic_impl};

    fn idle_words(n: u32) -> Array<felt252> {
        let w = encode(TicCmd { forward: 25, side: 0, angle_turn: 0, buttons: 0 });
        let mut out: Array<felt252> = array![];
        let mut k: u32 = 0;
        while k != n {
            out.append(w);
            k += 1;
        }
        out
    }

    #[test]
    fn test_genesis_returns_the_state_and_its_hash() {
        let (state, h) = genesis_impl(0);
        assert(state.len() > 100, 'a state');
        assert(h == doom_game::hash(@doom_game::genesis(LevelId::E1M1)), 'its hash');
        let (none, zero) = genesis_impl(7);
        assert(none.len() == 0 && zero == 0, 'unknown level');
    }

    #[test]
    fn test_run_segment_chains_from_genesis() {
        let (state, h) = genesis_impl(0);
        let words = idle_words(3);
        let out = run_segment_impl(state.span(), words.span(), 0, 100);
        assert(out.h_in == h, 'h_in is the genesis hash');
        assert(out.tic_start == 0 && out.tic_end == 3, 'three tics');
        assert(out.status == Status::Running, 'running');
        assert(to_felts(out).len() == 10, 'ten felts');
        // The Worker's step_tic over the same words reaches the same state.
        let (status, state_out, snap) = step_tic_impl(state.span(), words.span());
        assert(status == 0, 'running');
        assert(snap.len() > 40, 'a snapshot');
        let again = run_segment_impl(state_out.span(), array![].span(), 3, 10);
        assert(again.h_in == out.h_out, 'the end state hashes to h_out');
    }

    #[test]
    fn test_inconsistent_tic_start_aborts() {
        let (state, _) = genesis_impl(0);
        let out = run_segment_impl(state.span(), idle_words(1).span(), 5, 100);
        assert(out.status == Status::Abort, 'abort');
        assert(out.tic_start == 5 && out.tic_end == 5, 'no tic ran');
    }

    #[test]
    fn test_malformed_state_aborts_everywhere() {
        let junk = array![1, 2, 3];
        let out = run_segment_impl(junk.span(), idle_words(1).span(), 0, 100);
        assert(out.status == Status::Abort, 'abort');
        assert(out.h_in == out.h_out, 'h_in = h_out');
        let (status, state, snap) = step_tic_impl(junk.span(), idle_words(1).span());
        assert(status == 3 && state.len() == 0 && snap.len() == 0, 'empty abort');
    }
}

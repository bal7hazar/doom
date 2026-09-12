//! Segment stub, **ten-felt** output layout (P4.2b).
//!
//! `segment_stub` returns the four felts `[h_in, h_out, n, status]` the S4 recursion spike
//! needed to check chaining. That is one felt short of every field `DoomRuns` reads, so a root
//! proved over it cannot exercise the consumer contract on real data. This program returns
//! exactly the public output of D14 — the ten felts `cairo/crates/segment`'s `SegmentOutput`
//! serializes, in `Serde` order:
//!
//! ```text
//! 0 version            layout version, 1
//! 1 h_in               state hash before the segment
//! 2 h_out              ... and after it  (= poseidon(h_in, n_tics), the stub's chaining rule)
//! 3 tic_start          absolute tic index of the first tic
//! 4 tic_end            tic_start + n_tics
//! 5 status             0 RUNNING, 1 DEAD, 2 EXIT, 3 ABORT
//! 6 inputs_commitment  fold of this segment's own packed input log (D13, per segment)
//! 7 kills
//! 8 items
//! 9 secrets
//! ```
//!
//! so the leaf bootloader's output preimage is `[program_hash, out_0 … out_9]`, which is what
//! `doom_runs::segment::to_preimage` builds from a `LeafOutput` and what the recursive tree
//! folds into the root the on-chain verifier hashes.
//!
//! It still does **not** play Doom: the game is the ~2^17-step arithmetic loop of
//! `segment_stub` (kept so the leaf circuit keeps its shape), the state hash is
//! `poseidon(h_in, n_tics)`, and the stats arrive as arguments. What *is* real is the
//! `inputs_commitment`: the packed input log is built here, seven 32-bit tic words to a
//! transport felt, and folded with the **exact** `inputs_seed` / `commit_input` functions of
//! `cairo/crates/state_hash` (ported below, not re-invented), so a replay published by
//! `DoomRuns` can be checked against it.
//!
//! Arguments: `(h_in, tic_start, n_tics, seed, status, kills, items, secrets)`.
//! `seed` offsets the synthetic input words, so two segments of the same length have different
//! logs and therefore different commitments — which is what makes a run id unique.

use core::num::traits::{WrappingAdd, WrappingMul};
use core::poseidon::{hades_permutation, poseidon_hash_span};

/// ~61 steps per iteration with u32 wrapping arithmetic (CONTEXT §4.3) -> ~2^17 steps.
/// Unchanged from `segment_stub`, so both stubs land in the same circuit size class.
const N_ITERS: u32 = 2100;

/// Layout version of the ten felts (`segment::VERSION`).
const VERSION: felt252 = 1;

/// `ticcmd::TICS_PER_FELT`: input words per transport felt.
const TICS_PER_FELT: u32 = 7;
/// `2^32`, the lane width of the packing.
const LANE: felt252 = 0x100000000;

/// `state_hash::tag::INPUT_LOG` and `state_hash::SCHEMA_VERSION`.
const TAG_INPUT_LOG: felt252 = 'HP.INPUTS';
const SCHEMA_VERSION: felt252 = 1;

/// Base of the synthetic tic words — a plausible `ticcmd` bit pattern, the same constant
/// `cairo/doom_contracts/tools/doomruns_model.py` uses for its synthetic logs.
const WORD_BASE: u32 = 0x00808080;

/// The ten public felts of one segment, in `Serde` order. Byte-for-byte the layout of
/// `segment::SegmentOutput` (`cairo/crates/segment/README.md`, "Public output layout").
#[derive(Drop, Serde)]
struct SegmentOutput {
    version: felt252,
    h_in: felt252,
    h_out: felt252,
    tic_start: u32,
    tic_end: u32,
    status: u8,
    inputs_commitment: felt252,
    kills: u32,
    items: u32,
    secrets: u32,
}

/// `state_hash::inputs_seed()`: the commitment of the empty log.
fn inputs_seed() -> felt252 {
    poseidon_hash_span(array![TAG_INPUT_LOG, SCHEMA_VERSION, 0].span())
}

/// `state_hash::commit_input`: Starknet's 2-to-1 Poseidon, one Hades permutation.
fn commit_input(prev: felt252, packed: felt252) -> felt252 {
    let (commitment, _, _) = hades_permutation(prev, packed, 2);
    commitment
}

/// This segment's own input-log commitment: `n_tics` synthetic tic words packed seven to a
/// felt (little-endian lanes, `ticcmd::Packer`) and folded from `inputs_seed()`.
///
/// Per segment, never chained across segments (D13), so it survives a re-cut of the run.
fn commit_inputs(seed: u32, n_tics: u32) -> felt252 {
    let mut commitment = inputs_seed();
    let mut j: u32 = 0;
    while j < n_tics {
        // One transport felt: up to seven words, the last group left short (the tic span in
        // the output is what disambiguates it).
        let mut packed: felt252 = 0;
        let mut lane: felt252 = 1;
        let mut k: u32 = 0;
        while k < TICS_PER_FELT && j + k < n_tics {
            let word: u32 = WORD_BASE.wrapping_add(seed).wrapping_add(j + k);
            packed += word.into() * lane;
            lane *= LANE;
            k += 1;
        }
        commitment = commit_input(commitment, packed);
        j += TICS_PER_FELT;
    }
    commitment
}

#[executable]
fn main(
    h_in: felt252,
    tic_start: u32,
    n_tics: u32,
    seed: u32,
    status: u8,
    kills: u32,
    items: u32,
    secrets: u32,
) -> SegmentOutput {
    // The "game": ~2^17 steps of u32 arithmetic, folded into the output below so it cannot be
    // optimized away.
    let mut a: u32 = n_tics;
    let mut b: u32 = 0x9e3779b9;
    let mut i: u32 = 0;
    while i < N_ITERS {
        let t = a.wrapping_mul(b).wrapping_add(7);
        b = b.wrapping_add(a.wrapping_mul(3));
        a = t.wrapping_mul(t).wrapping_add(b);
        i += 1;
    }
    // A degenerate loop result would abort the segment; it never happens for our inputs, and
    // binding it here is what keeps the loop in the trace.
    let status = if a == b {
        3_u8
    } else {
        status
    };

    SegmentOutput {
        version: VERSION,
        h_in,
        h_out: poseidon_hash_span(array![h_in, n_tics.into()].span()),
        tic_start,
        tic_end: tic_start + n_tics,
        status,
        inputs_commitment: commit_inputs(seed, n_tics),
        kills,
        items,
        secrets,
    }
}

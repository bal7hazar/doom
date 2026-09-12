// SPDX-License-Identifier: Apache-2.0
//! The consumer-side model of one segment's public output (D14) and of its input-log
//! commitment (D13).
//!
//! This is a **port** of `cairo/crates/segment` and `cairo/crates/state_hash`, not a
//! dependency: those crates live in the `cairo/` workspace, which compiles with
//! `enable-gas = false` (`doom_run` needs it) while a `starknet-contract` target requires the
//! opposite. The port covers only what the contract needs — the ten felts, the status codes,
//! the continuity rule and the commitment fold — and every ported value is pinned against the
//! original crate's own test vectors and against `cairo/crates/segment/bench/reference.py`
//! (see `tests/test_segment.cairo`).
//!
//! ```text
//! #  field                meaning
//! 0  version              layout version, currently 1
//! 1  h_in                 Poseidon hash of the state before the segment
//! 2  h_out                ... and after it
//! 3  tic_start            absolute tic index of the first tic
//! 4  tic_end              one past the last tic actually run
//! 5  status               0 RUNNING, 1 DEAD, 2 EXIT, 3 ABORT
//! 6  inputs_commitment    commitment to this segment's slice of the input log
//! 7  kills                cumulative counters at the end of the segment
//! 8  items
//! 9  secrets
//! ```
use core::poseidon::{hades_permutation, poseidon_hash_span};

/// Layout version of the ten felts. `from_felts` of the segment crate refuses any other.
pub const VERSION: felt252 = 1;
/// Number of public felts per segment.
pub const OUTPUT_LEN: u32 = 10;

pub const STATUS_RUNNING: u8 = 0;
pub const STATUS_DEAD: u8 = 1;
pub const STATUS_EXIT: u8 = 2;
pub const STATUS_ABORT: u8 = 3;

/// Input words per transport felt (`ticcmd::TICS_PER_FELT`).
pub const TICS_PER_FELT: u32 = 7;

/// `state_hash::tag::INPUT_LOG` and `state_hash::SCHEMA_VERSION`.
pub const TAG_INPUT_LOG: felt252 = 'HP.INPUTS';
pub const SCHEMA_VERSION: felt252 = 1;

/// One leaf's ten public felts, in the order `SegmentOutput`'s `Serde` writes them — so the
/// calldata of `submit_batch` is, leaf by leaf, exactly the tail of the bootloader preimage.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct LeafOutput {
    pub version: felt252,
    pub h_in: felt252,
    pub h_out: felt252,
    pub tic_start: u32,
    pub tic_end: u32,
    pub status: u8,
    pub inputs_commitment: felt252,
    pub kills: u32,
    pub items: u32,
    pub secrets: u32,
}

/// The leaf simple bootloader's output preimage: `[program_hash, out_0 … out_9]` (S4 §1).
///
/// The program hash is not sent per leaf — it is the one pinned by the version table, so
/// pinning it here *is* the check "`preimage[0] == program_hash` of the pinned version": a
/// batch proved with another program recomposes to a different `output_hash` and its fact is
/// not registered.
pub fn to_preimage(program_hash: felt252, leaf: @LeafOutput) -> Array<felt252> {
    array![
        program_hash, *leaf.version, *leaf.h_in, *leaf.h_out, (*leaf.tic_start).into(),
        (*leaf.tic_end).into(), (*leaf.status).into(), *leaf.inputs_commitment,
        (*leaf.kills).into(), (*leaf.items).into(), (*leaf.secrets).into(),
    ]
}

/// `state_hash::inputs_seed()`: the commitment of an empty log,
/// `poseidon(tag ‖ schema_version ‖ 0)`.
pub fn inputs_seed() -> felt252 {
    poseidon_hash_span(array![TAG_INPUT_LOG, SCHEMA_VERSION, 0].span())
}

/// `state_hash::commit_input`: Starknet's 2-to-1 Poseidon over `(prev, packed)` — one Hades
/// permutation, the same function as `poseidon_hash(a, b)` in starknet.js and `poseidon_py`.
pub fn commit_input(prev: felt252, packed: felt252) -> felt252 {
    let (commitment, _, _) = hades_permutation(prev, packed, 2);
    commitment
}

/// `reference.py::commit_log`: a segment's `inputs_commitment` recomputed from its own slice of
/// the packed input log (D13 — per segment, never chained across segments).
pub fn commit_log(packed: Span<felt252>) -> felt252 {
    let mut commitment = inputs_seed();
    for word in packed {
        commitment = commit_input(commitment, *word);
    }
    commitment
}

/// Number of transport felts a segment of `tics` tics packs into (7 tics per felt, the last
/// group padded). Pins the published log's length to the tic span the proof commits to.
pub fn packed_len(tics: u32) -> u32 {
    (tics + TICS_PER_FELT - 1) / TICS_PER_FELT
}

/// `segment::continues`: `later` resumes exactly where `earlier` stopped.
pub fn continues(earlier: @LeafOutput, later: @LeafOutput) -> bool {
    *earlier.h_out == *later.h_in
        && *earlier.tic_end == *later.tic_start
        && *earlier.status == STATUS_RUNNING
}

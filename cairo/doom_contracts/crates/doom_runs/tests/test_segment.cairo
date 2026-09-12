// SPDX-License-Identifier: Apache-2.0
//! The ported half of `cairo/crates/segment` + `cairo/crates/state_hash`, pinned against those
//! crates' own test vectors and against the Python model (`tools/doomruns_model.py`, which is
//! `bench/reference.py`'s commitment re-implemented with `poseidon_py`).
use doom_runs::segment::{
    LeafOutput, OUTPUT_LEN, STATUS_ABORT, STATUS_DEAD, STATUS_EXIT, STATUS_RUNNING, VERSION,
    commit_input, commit_log, continues, inputs_seed, packed_len, to_preimage,
};
use crate::fixtures;

/// `state_hash::inputs_seed()` — the value the Python model prints and the segment crate folds
/// from.
#[test]
fn inputs_seed_matches_the_model() {
    assert_eq!(inputs_seed(), fixtures::INPUTS_SEED);
}

/// `cairo/crates/segment`'s `test_inputs_commitment_reference_vector`: nine tics, two transport
/// felts, folded from the seed.
#[test]
fn nine_tic_commitment_reference_vector() {
    let log = fixtures::nine_tic_log();
    assert_eq!(log.len(), 2);
    assert_eq!(commit_log(log.span()), fixtures::NINE_TIC_COMMITMENT);
    assert_eq!(
        fixtures::NINE_TIC_COMMITMENT,
        0x5a1a00832b34d6773e3ac371ddb6dfa8fef9813b137df243faf9539da38cad2,
    );
}

#[test]
fn commitment_is_order_sensitive() {
    let forward = commit_input(commit_input(inputs_seed(), 1), 2);
    let backward = commit_input(commit_input(inputs_seed(), 2), 1);
    assert_ne!(forward, backward);
    assert_eq!(commit_log(array![1, 2].span()), forward);
}

#[test]
fn empty_log_commits_to_the_seed() {
    assert_eq!(commit_log(array![].span()), inputs_seed());
}

/// 7 tics per transport felt, last group padded.
#[test]
fn packed_len_rounds_up() {
    assert_eq!(packed_len(0), 0);
    assert_eq!(packed_len(1), 1);
    assert_eq!(packed_len(7), 1);
    assert_eq!(packed_len(8), 2);
    assert_eq!(packed_len(35), 5);
    assert_eq!(packed_len(160), 23);
}

/// The preimage is `[program_hash, out_0 … out_9]`, in `Serde` order (S4 §1, D14).
#[test]
fn preimage_layout() {
    let leaf = LeafOutput {
        version: VERSION,
        h_in: 11,
        h_out: 22,
        tic_start: 0,
        tic_end: 80,
        status: STATUS_EXIT,
        inputs_commitment: 33,
        kills: 1,
        items: 2,
        secrets: 3,
    };
    let preimage = to_preimage(0xABC, @leaf);
    assert_eq!(preimage.len(), OUTPUT_LEN + 1);
    assert_eq!(preimage, array![0xABC, 1, 11, 22, 0, 80, 2, 33, 1, 2, 3]);
}

#[test]
fn status_codes_are_d14() {
    assert_eq!(STATUS_RUNNING, 0);
    assert_eq!(STATUS_DEAD, 1);
    assert_eq!(STATUS_EXIT, 2);
    assert_eq!(STATUS_ABORT, 3);
}

/// `segment::continues` and its failure modes.
#[test]
fn continuity_predicate() {
    let a = LeafOutput {
        version: VERSION,
        h_in: 1,
        h_out: 2,
        tic_start: 0,
        tic_end: 80,
        status: STATUS_RUNNING,
        inputs_commitment: 0,
        kills: 0,
        items: 0,
        secrets: 0,
    };
    let b = LeafOutput { h_in: 2, h_out: 3, tic_start: 80, tic_end: 160, ..a };
    assert!(continues(@a, @b));
    assert!(!continues(@a, @LeafOutput { h_in: 9, ..b }));
    assert!(!continues(@a, @LeafOutput { tic_start: 81, ..b }));
    assert!(!continues(@LeafOutput { status: STATUS_EXIT, ..a }, @b));
}

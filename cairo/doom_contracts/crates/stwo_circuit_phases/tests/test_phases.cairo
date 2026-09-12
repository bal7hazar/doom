// SPDX-License-Identifier: Apache-2.0
//! The phase machine over the S4 fixture: end-to-end equivalence with the monolithic verifier,
//! a Serde round-trip of every checkpoint between phases, tamper rejections, and the cumulative
//! cost probe (`cost_*` tests: read the per-test gas and subtract).
use stwo_circuit_phases::machine::{FriState, MerkleState, answers, begin, fri_layers, merkle};
use super::fixture::{expected_output_hash, load_proof};
use stwo_circuit_phases::sections::{Sections, fri_chunk, split};

fn roundtrip_merkle(state: MerkleState) -> MerkleState {
    let mut s = array![];
    state.serialize(ref s);
    let mut span = s.span();
    let back: MerkleState = Serde::deserialize(ref span).expect('merkle state deser');
    assert!(span.is_empty(), "merkle state trailing");
    back
}

fn roundtrip_fri(state: FriState) -> FriState {
    let mut s = array![];
    state.serialize(ref s);
    let mut span = s.span();
    let back: FriState = Serde::deserialize(ref span).expect('fri state deser');
    assert!(span.is_empty(), "fri state trailing");
    back
}

fn serialized_len<T, +Serde<T>>(v: @T) -> u32 {
    let mut s = array![];
    v.serialize(ref s);
    s.len()
}

fn sections() -> Sections {
    split(load_proof().span())
}

/// Every phase in sequence, with a serde round-trip of the checkpoint between transactions,
/// the FRI walk cut as {first + inner 0} then {inner 1..4}.
#[test]
fn phases_end_to_end_n4() {
    let sec = sections();
    let mut state = roundtrip_merkle(begin(sec.head.span()));
    assert!(state.params.query_positions.len() == 70, "70 queries");

    // Tx 2: trees 0 and 1; tx 3: trees 2 and 3.
    merkle(ref state, 0, sec.queried_values.at(0).span(), sec.decommitments.at(0).span());
    merkle(ref state, 1, sec.queried_values.at(1).span(), sec.decommitments.at(1).span());
    let mut state = roundtrip_merkle(state);
    merkle(ref state, 2, sec.queried_values.at(2).span(), sec.decommitments.at(2).span());
    merkle(ref state, 3, sec.queried_values.at(3).span(), sec.decommitments.at(3).span());
    let state = roundtrip_merkle(state);
    assert!(state.trees_done == 0b1111, "trees done");

    // Tx 4: answers.
    let queried = array![
        sec.queried_values.at(0).span(), sec.queried_values.at(1).span(),
        sec.queried_values.at(2).span(), sec.queried_values.at(3).span(),
    ];
    let mut state = roundtrip_fri(answers(state, sec.sampled_values.span(), queried.span()));
    assert!(state.layer_query_evals.len() == 70, "70 answers");
    assert!(sec.fri_layers.len() == 6, "6 fri layers");

    // Tx 5: first layer + inner layer 0; tx 6: inner layers 1..4 (last layer check inside).
    let r = fri_layers(ref state, fri_chunk(@sec.fri_layers, 0, 2).span());
    assert!(r.is_none(), "not done after 2 layers");
    let mut state = roundtrip_fri(state);
    assert!(state.layers_done == 2, "layers done");
    let r = fri_layers(ref state, fri_chunk(@sec.fri_layers, 2, 6).span());
    assert!(r.unwrap() == expected_output_hash(), "output hash");
}

/// The FRI walk in a single chunk (the "fits in one tx" variant) and per-layer chunks.
#[test]
fn fri_walk_chunkings_n4() {
    let sec = sections();
    let mut state = begin(sec.head.span());
    for i in 0..4_u32 {
        merkle(ref state, i, sec.queried_values.at(i).span(), sec.decommitments.at(i).span());
    }
    let queried = array![
        sec.queried_values.at(0).span(), sec.queried_values.at(1).span(),
        sec.queried_values.at(2).span(), sec.queried_values.at(3).span(),
    ];
    let state = answers(state, sec.sampled_values.span(), queried.span());

    // One chunk.
    let mut s1 = roundtrip_fri(state);
    let r = fri_layers(ref s1, fri_chunk(@sec.fri_layers, 0, 6).span());
    assert!(r.unwrap() == expected_output_hash(), "single chunk");

    // Six chunks of one layer, round-tripping between each.
    let mut s6 = s1_reset(@sec);
    let mut i = 0;
    loop {
        let r = fri_layers(ref s6, fri_chunk(@sec.fri_layers, i, i + 1).span());
        i += 1;
        if i == 6 {
            assert!(r.unwrap() == expected_output_hash(), "six chunks");
            break;
        }
        assert!(r.is_none(), "not done");
        s6 = roundtrip_fri(s6);
    }
}

fn s1_reset(sec: @Sections) -> FriState {
    let mut state = begin(sec.head.span());
    for i in 0..4_u32 {
        merkle(ref state, i, sec.queried_values.at(i).span(), sec.decommitments.at(i).span());
    }
    let queried = array![
        sec.queried_values.at(0).span(), sec.queried_values.at(1).span(),
        sec.queried_values.at(2).span(), sec.queried_values.at(3).span(),
    ];
    answers(state, sec.sampled_values.span(), queried.span())
}

#[test]
#[should_panic(expected: "answers: sampled digest")]
fn answers_rejects_tampered_sampled_values() {
    let sec = sections();
    let mut state = begin(sec.head.span());
    for i in 0..4_u32 {
        merkle(ref state, i, sec.queried_values.at(i).span(), sec.decommitments.at(i).span());
    }
    let mut tampered = sec.sampled_values.clone();
    let last = tampered.pop_front().unwrap();
    tampered.append(last + 1);
    let queried = array![
        sec.queried_values.at(0).span(), sec.queried_values.at(1).span(),
        sec.queried_values.at(2).span(), sec.queried_values.at(3).span(),
    ];
    answers(state, tampered.span(), queried.span());
}

#[test]
#[should_panic(expected: "answers: merkle phase incomplete")]
fn answers_requires_all_trees() {
    let sec = sections();
    let mut state = begin(sec.head.span());
    for i in 0..3_u32 {
        merkle(ref state, i, sec.queried_values.at(i).span(), sec.decommitments.at(i).span());
    }
    let queried = array![
        sec.queried_values.at(0).span(), sec.queried_values.at(1).span(),
        sec.queried_values.at(2).span(), sec.queried_values.at(3).span(),
    ];
    answers(state, sec.sampled_values.span(), queried.span());
}

#[test]
#[should_panic(expected: "answers: queried digest")]
fn answers_rejects_queried_values_not_decommitted() {
    let sec = sections();
    let mut state = begin(sec.head.span());
    for i in 0..4_u32 {
        merkle(ref state, i, sec.queried_values.at(i).span(), sec.decommitments.at(i).span());
    }
    // Swap trees 0 and 3 in the re-supply.
    let queried = array![
        sec.queried_values.at(3).span(), sec.queried_values.at(1).span(),
        sec.queried_values.at(2).span(), sec.queried_values.at(0).span(),
    ];
    answers(state, sec.sampled_values.span(), queried.span());
}

#[test]
#[should_panic(expected: "merkle: tree already done")]
fn merkle_is_write_once_per_tree() {
    let sec = sections();
    let mut state = begin(sec.head.span());
    merkle(ref state, 1, sec.queried_values.at(1).span(), sec.decommitments.at(1).span());
    merkle(ref state, 1, sec.queried_values.at(1).span(), sec.decommitments.at(1).span());
}

#[test]
#[should_panic(expected: "Merkle Verification Error: Root Mismatch")]
fn merkle_rejects_tampered_queried_value() {
    let sec = sections();
    let mut state = begin(sec.head.span());
    // Flip the first queried value of tree 0 (index 0 is the length prefix).
    let qv = sec.queried_values.at(0);
    let mut tampered = array![*qv.at(0), *qv.at(1) + 1];
    let mut i = 2;
    while i < qv.len() {
        tampered.append(*qv.at(i));
        i += 1;
    }
    merkle(ref state, 0, tampered.span(), sec.decommitments.at(0).span());
}

#[test]
#[should_panic(expected: "fri: inner commitment")]
fn fri_rejects_layer_out_of_order() {
    let sec = sections();
    let mut state = s1_reset(@sec);
    fri_layers(ref state, fri_chunk(@sec.fri_layers, 0, 1).span());
    // Skip inner layer 0: feed inner layer 1 in its place.
    fri_layers(ref state, fri_chunk(@sec.fri_layers, 2, 3).span());
}

#[test]
#[should_panic(expected: "Merkle Verification Error: Root Mismatch")]
fn fri_rejects_tampered_witness() {
    let sec = sections();
    let mut state = s1_reset(@sec);
    fri_layers(ref state, fri_chunk(@sec.fri_layers, 0, 4).span());
    // Inner layer 3 (index 4): 192 witness QM31s and no hash witness; flip its first word.
    let layer = sec.fri_layers.at(4);
    let mut tampered = array![1, *layer.at(0), *layer.at(1) + 1];
    let mut i = 2;
    while i < layer.len() {
        tampered.append(*layer.at(i));
        i += 1;
    }
    fri_layers(ref state, tampered.span());
}

/// A tampered carried evaluation (i.e. a forged state echo) is caught by the next layer's Merkle
/// check: the last inner layer has no hash witness, so its root is recomputed from the evals.
#[test]
#[should_panic(expected: "Merkle Verification Error: Root Mismatch")]
fn fri_rejects_tampered_carried_evals() {
    let sec = sections();
    let mut state = s1_reset(@sec);
    fri_layers(ref state, fri_chunk(@sec.fri_layers, 0, 5).span());
    let mut evals = array![];
    let mut first = true;
    for e in state.layer_query_evals.span() {
        if first {
            evals.append(*e + *e);
            first = false;
        } else {
            evals.append(*e);
        }
    }
    state.layer_query_evals = evals;
    fri_layers(ref state, fri_chunk(@sec.fri_layers, 5, 6).span());
}

// ---- Checkpoint sizes (felts echoed as calldata by the router) ----

#[test]
fn checkpoint_sizes_n4() {
    let sec = sections();
    let mut state = begin(sec.head.span());
    let merkle_len = serialized_len(@state);
    for i in 0..4_u32 {
        merkle(ref state, i, sec.queried_values.at(i).span(), sec.decommitments.at(i).span());
    }
    let queried = array![
        sec.queried_values.at(0).span(), sec.queried_values.at(1).span(),
        sec.queried_values.at(2).span(), sec.queried_values.at(3).span(),
    ];
    let mut state = answers(state, sec.sampled_values.span(), queried.span());
    let fri_len_0 = serialized_len(@state);
    fri_layers(ref state, fri_chunk(@sec.fri_layers, 0, 2).span());
    let fri_len_2 = serialized_len(@state);
    println!(
        "checkpoint felts: merkle {} fri(before walk) {} fri(after 2 layers) {}",
        merkle_len,
        fri_len_0,
        fri_len_2,
    );
    println!(
        "section felts: head {} sampled {} qv {} {} {} {} dec {} {} {} {} fri {} {} {} {} {} {}",
        sec.head.len(),
        sec.sampled_values.len(),
        sec.queried_values.at(0).len(),
        sec.queried_values.at(1).len(),
        sec.queried_values.at(2).len(),
        sec.queried_values.at(3).len(),
        sec.decommitments.at(0).len(),
        sec.decommitments.at(1).len(),
        sec.decommitments.at(2).len(),
        sec.decommitments.at(3).len(),
        sec.fri_layers.at(0).len(),
        sec.fri_layers.at(1).len(),
        sec.fri_layers.at(2).len(),
        sec.fri_layers.at(3).len(),
        sec.fri_layers.at(4).len(),
        sec.fri_layers.at(5).len(),
    );
    assert!(merkle_len < 400, "merkle checkpoint too large");
    assert!(fri_len_0 < 700, "fri checkpoint too large");
}

// ---- Cumulative cost probe: gas(cost_k) - gas(cost_{k-1}) = the k-th step ----

#[test]
fn cost_0_load_and_split() {
    let sec = sections();
    assert!(sec.head.len() > 0);
}

#[test]
fn cost_1_begin() {
    let sec = sections();
    let state = begin(sec.head.span());
    assert!(state.trees_done == 0);
}

#[test]
fn cost_2_merkle_tree0() {
    let sec = sections();
    let mut state = begin(sec.head.span());
    merkle(ref state, 0, sec.queried_values.at(0).span(), sec.decommitments.at(0).span());
}

#[test]
fn cost_3_merkle_tree1() {
    let sec = sections();
    let mut state = begin(sec.head.span());
    merkle(ref state, 1, sec.queried_values.at(1).span(), sec.decommitments.at(1).span());
}

#[test]
fn cost_4_merkle_tree2() {
    let sec = sections();
    let mut state = begin(sec.head.span());
    merkle(ref state, 2, sec.queried_values.at(2).span(), sec.decommitments.at(2).span());
}

#[test]
fn cost_5_merkle_tree3() {
    let sec = sections();
    let mut state = begin(sec.head.span());
    merkle(ref state, 3, sec.queried_values.at(3).span(), sec.decommitments.at(3).span());
}

#[test]
fn cost_6_answers() {
    let sec = sections();
    let mut state = begin(sec.head.span());
    for i in 0..4_u32 {
        merkle(ref state, i, sec.queried_values.at(i).span(), sec.decommitments.at(i).span());
    }
    let queried = array![
        sec.queried_values.at(0).span(), sec.queried_values.at(1).span(),
        sec.queried_values.at(2).span(), sec.queried_values.at(3).span(),
    ];
    let state = answers(state, sec.sampled_values.span(), queried.span());
    assert!(state.layers_done == 0);
}

#[test]
fn cost_7_all_merkle() {
    let sec = sections();
    let mut state = begin(sec.head.span());
    for i in 0..4_u32 {
        merkle(ref state, i, sec.queried_values.at(i).span(), sec.decommitments.at(i).span());
    }
    assert!(state.trees_done == 0b1111);
}

#[test]
fn cost_8_fri_first_and_inner0() {
    let sec = sections();
    let mut state = s1_reset(@sec);
    fri_layers(ref state, fri_chunk(@sec.fri_layers, 0, 2).span());
}

#[test]
fn cost_9_fri_all() {
    let sec = sections();
    let mut state = s1_reset(@sec);
    let r = fri_layers(ref state, fri_chunk(@sec.fri_layers, 0, 6).span());
    assert!(r.is_some());
}

#[test]
fn cost_10_fri_first_only() {
    let sec = sections();
    let mut state = s1_reset(@sec);
    fri_layers(ref state, fri_chunk(@sec.fri_layers, 0, 1).span());
}

#[test]
fn cost_11_fri_first_to_inner1() {
    let sec = sections();
    let mut state = s1_reset(@sec);
    fri_layers(ref state, fri_chunk(@sec.fri_layers, 0, 3).span());
}

#[test]
fn cost_12_fri_first_to_inner2() {
    let sec = sections();
    let mut state = s1_reset(@sec);
    fri_layers(ref state, fri_chunk(@sec.fri_layers, 0, 4).span());
}

#[test]
fn cost_13_fri_first_to_inner3() {
    let sec = sections();
    let mut state = s1_reset(@sec);
    fri_layers(ref state, fri_chunk(@sec.fri_layers, 0, 5).span());
}

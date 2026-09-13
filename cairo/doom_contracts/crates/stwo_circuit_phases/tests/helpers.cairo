// SPDX-License-Identifier: Apache-2.0
//! Drives the phase machine over `Sections` the way the router does: every section packed
//! (`packed_section`) with its felt count.
use stwo_circuit_phases::machine::{FriState, MerkleState, answers, begin, fri_layers, merkle};
use stwo_circuit_phases::sections::{Sections, packed, packed_fri_chunk, packed_section};

/// Merkle phase of tree `i`.
pub fn mk(ref state: MerkleState, sec: @Sections, i: u32) {
    let (qv, n_qv) = packed(sec.qv_packed.at(i), sec.queried_values.at(i));
    let (dec, n_dec) = packed(sec.dec_packed.at(i), sec.decommitments.at(i));
    merkle(ref state, i, qv, n_qv, dec, n_dec);
}

/// `begin` + the four Merkle trees.
pub fn merkle_state(sec: @Sections) -> MerkleState {
    let mut state = begin(sec.head.span());
    for i in 0..4_u32 {
        mk(ref state, sec, i);
    }
    state
}

/// Answers phase with the proof's own sections.
pub fn ans(state: MerkleState, sec: @Sections) -> FriState {
    let (sv, n_sv) = packed(sec.sampled_packed, sec.sampled_values);
    let mut qvs = array![];
    let mut ns = array![];
    for t in 0..4_u32 {
        let (q, n) = packed(sec.qv_packed.at(t), sec.queried_values.at(t));
        qvs.append(q);
        ns.append(n);
    }
    answers(state, sv, n_sv, qvs.span(), ns.span())
}

/// Answers phase with an arbitrary sampled-values section and tree order of the re-supply.
pub fn ans_with(
    state: MerkleState, sec: @Sections, sampled: Span<felt252>, order: [u32; 4],
) -> FriState {
    let (sv, n_sv) = packed_section(sampled);
    let mut qvs = array![];
    let mut ns = array![];
    for t in order.span() {
        let (q, n) = packed_section(sec.queried_values.at(*t).span());
        qvs.append(q);
        ns.append(n);
    }
    answers(state, sv, n_sv, qvs.span(), ns.span())
}

/// `begin` + Merkle + answers: the state before the FRI walk.
pub fn fri_state(sec: @Sections) -> FriState {
    ans(merkle_state(sec), sec)
}

/// FRI phase over the layers `[from, to)`.
pub fn fri(ref state: FriState, sec: @Sections, from: u32, to: u32) -> Option<[u32; 8]> {
    let (slots, n) = packed_fri_chunk(sec, from, to);
    fri_layers(ref state, slots, n)
}

/// FRI phase over an arbitrary (e.g. tampered) chunk.
pub fn fri_raw(ref state: FriState, chunk: Span<felt252>) -> Option<[u32; 8]> {
    let (slots, n) = packed_section(chunk);
    fri_layers(ref state, slots, n)
}

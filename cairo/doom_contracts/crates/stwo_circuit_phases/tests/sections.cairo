// SPDX-License-Identifier: Apache-2.0
//! Splits a cairo-serde `CircuitProof` felt stream into the per-phase calldata sections
//! (the in-Cairo twin of `tools/emit_calldata.py`, used by the tests).
use stwo_circuit_air::claims::{CircuitClaim, CircuitInteractionClaim};
use stwo_circuit_phases::machine::FriHead;
use stwo_verifier_core::Hash;
use stwo_verifier_core::fields::m31::M31;
use stwo_verifier_core::fields::qm31::{QM31, QM31Serde};
use stwo_verifier_core::fri::FriLayerProof;
use stwo_verifier_core::pcs::PcsConfig;
use stwo_verifier_core::poly::line::LinePoly;
use stwo_verifier_core::vcs::blake2s_hasher::Blake2sMerkleHasher;
use stwo_verifier_core::vcs::verifier::MerkleDecommitment;

#[derive(Drop)]
pub struct Sections {
    /// `begin` calldata.
    pub head: Array<felt252>,
    /// Per tree: cairo-serde `Span<M31>`.
    pub queried_values: Array<Array<felt252>>,
    /// Per tree: cairo-serde `MerkleDecommitment`.
    pub decommitments: Array<Array<felt252>>,
    /// Cairo-serde `sampled_values` (the `answers` re-supply).
    pub sampled_values: Array<felt252>,
    /// Per FRI layer (first, then inner): cairo-serde `FriLayerProof`.
    pub fri_layers: Array<Array<felt252>>,
}

/// Serializes `layers[from..to)` as a cairo-serde `Array<FriLayerProof>` chunk.
pub fn fri_chunk(layers: @Array<Array<felt252>>, from: u32, to: u32) -> Array<felt252> {
    let mut out = array![(to - from).into()];
    let mut i = from;
    while i < to {
        out.append_span(layers.at(i).span());
        i += 1;
    }
    out
}

pub fn split(values: Span<felt252>) -> Sections {
    let mut span = values;
    let claim: CircuitClaim = Serde::deserialize(ref span).expect('claim');
    let interaction_pow: u64 = Serde::deserialize(ref span).expect('pow');
    let interaction_claim: CircuitInteractionClaim = Serde::deserialize(ref span).expect('icl');
    let pcs_config: PcsConfig = Serde::deserialize(ref span).expect('config');
    let commitments: Span<Hash> = Serde::deserialize(ref span).expect('roots');
    let sampled_values: Span<Span<Span<QM31>>> = Serde::deserialize(ref span).expect('sampled');
    let decommitments: Array<MerkleDecommitment<Blake2sMerkleHasher>> = Serde::deserialize(
        ref span,
    )
        .expect('decommitments');
    let queried_values: Array<Span<M31>> = Serde::deserialize(ref span).expect('queried');
    let proof_of_work_nonce: u64 = Serde::deserialize(ref span).expect('nonce');
    let first_layer: FriLayerProof = Serde::deserialize(ref span).expect('first layer');
    let inner_layers: Array<FriLayerProof> = Serde::deserialize(ref span).expect('inner layers');
    let last_layer_poly: LinePoly = Serde::deserialize(ref span).expect('last layer');
    let channel_salt: u32 = Serde::deserialize(ref span).expect('salt');
    assert!(span.is_empty(), "trailing proof data");

    let mut sampled = array![];
    sampled_values.serialize(ref sampled);

    let mut inner_commitments = array![];
    for l in inner_layers.span() {
        inner_commitments.append(*l.commitment);
    }
    let fri_head = FriHead {
        first_commitment: first_layer.commitment, inner_commitments, last_layer_poly,
    };

    let mut head = array![];
    claim.serialize(ref head);
    interaction_pow.serialize(ref head);
    interaction_claim.serialize(ref head);
    pcs_config.serialize(ref head);
    commitments.serialize(ref head);
    head.append_span(sampled.span());
    proof_of_work_nonce.serialize(ref head);
    fri_head.serialize(ref head);
    channel_salt.serialize(ref head);

    let mut qv = array![];
    for v in queried_values.span() {
        let mut s = array![];
        v.serialize(ref s);
        qv.append(s);
    }
    let mut dec = array![];
    for d in decommitments.span() {
        let mut s = array![];
        d.serialize(ref s);
        dec.append(s);
    }
    let mut fri_layers = array![];
    let mut s = array![];
    first_layer.serialize(ref s);
    fri_layers.append(s);
    for l in inner_layers.span() {
        let mut s = array![];
        l.serialize(ref s);
        fri_layers.append(s);
    }

    Sections { head, queried_values: qv, decommitments: dec, sampled_values: sampled, fri_layers }
}

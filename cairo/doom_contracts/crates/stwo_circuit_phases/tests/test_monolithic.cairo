// SPDX-License-Identifier: Apache-2.0
//! Monolithic reference: the vendored `verify_circuit` over the S4 fixture, built with gas
//! enabled and the naive (non-opcode) QM31 arithmetic — i.e. what a contract would execute.
use stwo_circuit_air::{
    CircuitProof, compute_circuit_hash, get_verification_output, verify_circuit,
};
use stwo_verifier_core::Hash;
use super::fixture::{expected_output_hash, load_proof};

#[test]
fn monolithic_verify_n4() {
    let values = load_proof();
    let mut span = values.span();
    let proof: CircuitProof = Serde::deserialize(ref span).expect('proof deser');
    assert!(span.is_empty(), "trailing data");

    let commitments: @Box<[Hash; 4]> = proof
        .stark_proof
        .commitment_scheme_proof
        .commitments
        .try_into()
        .unwrap();
    let output_values = proof.claim.public_data.output_values.span();
    let [preprocessed_commitment, _, _, _] = commitments.unbox();
    let circuit_hash = compute_circuit_hash(
        proof.stark_proof.commitment_scheme_proof.config.fri_config.log_blowup_factor,
        preprocessed_commitment,
    );
    verify_circuit(:proof, :circuit_hash);
    let out = get_verification_output(:circuit_hash, :output_values);
    assert!(out.output_hash.hash.unbox() == expected_output_hash(), "output hash");
}

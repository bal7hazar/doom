// SPDX-License-Identifier: Apache-2.0
//! Measurement-only class: the whole vendored `verify_circuit` behind one entrypoint, with
//! the proof passed entirely as calldata. It cannot be used on a public network (the proof is
//! ~96 k felts, the calldata cap is 5 000) — it exists to measure the monolithic class size,
//! the audited-libfunc compliance of the vendored verifier and the "if the cap did not exist"
//! gas on devnet/snforge (docs/design/onchain-verifier.md §2).

#[starknet::interface]
pub trait IStwoCircuitMonolithic<TContractState> {
    /// Verifies a full cairo-serde `CircuitProof` and returns `blake2s(circuit_hash ‖ outputs)`.
    fn verify(self: @TContractState, proof: Span<felt252>) -> [u32; 8];
}

#[starknet::contract]
pub mod StwoCircuitMonolithic {
    use stwo_circuit_air_ref::{
        CircuitProof, compute_circuit_hash, get_verification_output, verify_circuit,
    };
    use stwo_verifier_core_ref::Hash;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl Impl of super::IStwoCircuitMonolithic<ContractState> {
        fn verify(self: @ContractState, proof: Span<felt252>) -> [u32; 8] {
            let mut span = proof;
            let proof: CircuitProof = Serde::deserialize(ref span).expect('proof deser');
            assert(span.is_empty(), 'trailing proof data');
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
            get_verification_output(:circuit_hash, :output_values).output_hash.hash.unbox()
        }
    }
}

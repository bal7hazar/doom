// SPDX-License-Identifier: Apache-2.0
//! Stateless library classes running the phases of `stwo_circuit_phases::machine`:
//! `StwoPhasesBegin` (transcript), `StwoPhasesMerkle` (Merkle trees + FRI answers),
//! `StwoPhasesFri` (FRI decommit walk) — three classes because the whole verifier does not fit
//! the 81 920-felt CASM cap once the checkpoint serde is added (docs/design §5).
//! They are `library_call`ed by the router (`router.cairo`), which owns the only storage.
//! Sections arrive unpacked (the router unpacks the 7-limb calldata); states are the
//! cairo-serde `MerkleState` / `FriState` streams.
use stwo_circuit_phases::machine::{FriState, MerkleState, answers, begin, fri_layers, merkle};

/// One tree of the Merkle phase.
#[derive(Drop, Serde)]
pub struct TreeSection {
    pub tree_idx: u32,
    /// cairo-serde `Span<M31>`.
    pub queried_values: Span<felt252>,
    /// cairo-serde `MerkleDecommitment`.
    pub decommitment: Span<felt252>,
}

#[starknet::interface]
pub trait IStwoPhasesBegin<TContractState> {
    /// Phase `begin`: the whole transcript over the head section. Returns the `MerkleState`.
    fn run_begin(self: @TContractState, head: Span<felt252>) -> Array<felt252>;
}

#[starknet::interface]
pub trait IStwoPhasesMerkle<TContractState> {
    /// Merkle phase: decommits `trees` against a `MerkleState`. Returns the new `MerkleState`.
    fn run_merkle(
        self: @TContractState, state: Span<felt252>, trees: Span<TreeSection>,
    ) -> Array<felt252>;
    /// Answers phase: `MerkleState` → `FriState`.
    fn run_answers(
        self: @TContractState,
        state: Span<felt252>,
        sampled_values: Span<felt252>,
        queried_values: Span<Span<felt252>>,
    ) -> Array<felt252>;
}

#[starknet::interface]
pub trait IStwoPhasesFri<TContractState> {
    /// FRI phase: decommits and folds `layers` (cairo-serde `Array<FriLayerProof>`) against a
    /// `FriState`. Returns the new `FriState` and, once the last layer is checked, the
    /// `(circuit_hash, output_hash)` words.
    fn run_fri(
        self: @TContractState, state: Span<felt252>, layers: Span<felt252>,
    ) -> (Array<felt252>, Option<([u32; 8], [u32; 8])>);
}

pub fn deserialize_merkle_state(state: Span<felt252>) -> MerkleState {
    let mut span = state;
    let s: MerkleState = Serde::deserialize(ref span).expect('bad merkle state');
    assert(span.is_empty(), 'merkle state: trailing');
    s
}

pub fn deserialize_fri_state(state: Span<felt252>) -> FriState {
    let mut span = state;
    let s: FriState = Serde::deserialize(ref span).expect('bad fri state');
    assert(span.is_empty(), 'fri state: trailing');
    s
}

fn run_trees(ref state: MerkleState, trees: Span<TreeSection>) {
    for t in trees {
        merkle(ref state, *t.tree_idx, *t.queried_values, *t.decommitment);
    }
}

#[starknet::contract]
pub mod StwoPhasesBegin {
    use super::begin;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl Impl of super::IStwoPhasesBegin<ContractState> {
        fn run_begin(self: @ContractState, head: Span<felt252>) -> Array<felt252> {
            let state = begin(head);
            let mut out = array![];
            state.serialize(ref out);
            out
        }
    }
}

#[starknet::contract]
pub mod StwoPhasesMerkle {
    use super::{TreeSection, answers, deserialize_merkle_state, run_trees};

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl Impl of super::IStwoPhasesMerkle<ContractState> {

        fn run_merkle(
            self: @ContractState, state: Span<felt252>, trees: Span<TreeSection>,
        ) -> Array<felt252> {
            let mut state = deserialize_merkle_state(state);
            run_trees(ref state, trees);
            let mut out = array![];
            state.serialize(ref out);
            out
        }

        fn run_answers(
            self: @ContractState,
            state: Span<felt252>,
            sampled_values: Span<felt252>,
            queried_values: Span<Span<felt252>>,
        ) -> Array<felt252> {
            let state = deserialize_merkle_state(state);
            let state = answers(state, sampled_values, queried_values);
            let mut out = array![];
            state.serialize(ref out);
            out
        }
    }
}

#[starknet::contract]
pub mod StwoPhasesFri {
    use super::{deserialize_fri_state, fri_layers};

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl Impl of super::IStwoPhasesFri<ContractState> {
        fn run_fri(
            self: @ContractState, state: Span<felt252>, layers: Span<felt252>,
        ) -> (Array<felt252>, Option<([u32; 8], [u32; 8])>) {
            let mut state = deserialize_fri_state(state);
            let done = fri_layers(ref state, layers);
            let result = match done {
                Some(output_hash) => Some((state.params.circuit_hash, output_hash)),
                None => None,
            };
            let mut out = array![];
            state.serialize(ref out);
            (out, result)
        }
    }
}

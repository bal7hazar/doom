// SPDX-License-Identifier: Apache-2.0
//! `StwoCircuitRouter`: drives the phase classes across transactions and registers facts.
//!
//! Storage holds one checkpoint slot per `(caller, proof_id)`: `(tag, poseidon(state))`.
//! The caller echoes the previous state as calldata; the router checks its hash and tag,
//! library-calls the phase class, stores the new tagged hash and returns the new state.
//! Proof data itself is never written to storage (calldata only, S5 §8.5). Sections arrive
//! packed (7 u32 limbs per felt, `stwo_circuit_phases::pack`): the head (the only section with
//! u64 values) in the escaped encoding, every other section in the fast-path encoding, each
//! section packed independently and concatenated into one `payload` whose per-section unpacked
//! lengths are `lens`.
//!
//! (P4.1) The router no longer unpacks anything: it slices the payload into its packed sections
//! and forwards the slices with their felt counts; the phase classes decode them
//! (`stwo_circuit_phases::decode`), so the library calls carry 7× less calldata.
//!
//! Facts: `fact = poseidon(circuit_hash words ‖ output_hash words)` (16 felts), registered by
//! the last FRI transaction; `is_valid(fact)` is the consumer interface (`DoomRuns`).
//! The phase class hashes are pinned in the constructor: a router is one immutable verifier
//! version (docs/design/onchain-verifier.md §6).
use starknet::ClassHash;

/// Tags of the checkpoint slot (`0` = free).
pub const TAG_FREE: u8 = 0;
pub const TAG_MERKLE: u8 = 1;
pub const TAG_FRI: u8 = 2;
pub const TAG_DONE: u8 = 3;

#[derive(Drop, Serde, starknet::Store, Copy)]
pub struct Checkpoint {
    pub tag: u8,
    pub state_hash: felt252,
}

#[starknet::interface]
pub trait IStwoCircuitRouter<TContractState> {
    /// Tx 1: `head` = the escaped-packed head section of `head_n` felts; `payload` = packed
    /// `(queried_values ‖ decommitment)*`, `lens` = the unpacked length of each of those
    /// sections, `trees` = the tree index of each pair (may be empty).
    fn begin(
        ref self: TContractState,
        proof_id: felt252,
        head: Span<felt252>,
        head_n: u32,
        payload: Span<felt252>,
        lens: Span<u32>,
        trees: Span<u32>,
    ) -> Array<felt252>;
    /// Merkle tx: `payload` = packed `(queried_values ‖ decommitment)*`.
    fn merkle(
        ref self: TContractState,
        proof_id: felt252,
        state: Span<felt252>,
        payload: Span<felt252>,
        lens: Span<u32>,
        trees: Span<u32>,
    ) -> Array<felt252>;
    /// Answers tx: `payload` = packed `sampled_values ‖ qv_0 ‖ qv_1 ‖ qv_2 ‖ qv_3`.
    fn answers(
        ref self: TContractState,
        proof_id: felt252,
        state: Span<felt252>,
        payload: Span<felt252>,
        lens: Span<u32>,
    ) -> Array<felt252>;
    /// FRI tx: `payload` = fast-path packed cairo-serde `Array<FriLayerProof>` of `n_values`
    /// felts.
    /// Registers the fact when the last layer is checked.
    fn fri(
        ref self: TContractState,
        proof_id: felt252,
        state: Span<felt252>,
        payload: Span<felt252>,
        n_values: u32,
    ) -> Array<felt252>;

    fn is_valid(self: @TContractState, fact: felt252) -> bool;
    /// Calibration probes (no state): `probe_unpack` unpacks a fast-path payload and returns
    /// the value count; `probe_noop` only returns the payload length. Their devnet receipts
    /// isolate the transport cost per packed slot (docs/design/onchain-verifier.md §7).
    fn probe_unpack(self: @TContractState, payload: Span<felt252>, n_values: u32) -> u32;
    fn probe_noop(self: @TContractState, payload: Span<felt252>) -> u32;
    fn checkpoint(
        self: @TContractState, caller: starknet::ContractAddress, proof_id: felt252,
    ) -> Checkpoint;
    fn phase_classes(self: @TContractState) -> (ClassHash, ClassHash, ClassHash);
}

/// `fact = poseidon(circuit_hash ‖ output_hash)` over the 16 u32 words.
pub fn compute_fact(circuit_hash: [u32; 8], output_hash: [u32; 8]) -> felt252 {
    let mut words: Array<felt252> = array![];
    for w in circuit_hash.span() {
        words.append((*w).into());
    }
    for w in output_hash.span() {
        words.append((*w).into());
    }
    core::poseidon::poseidon_hash_span(words.span())
}

#[starknet::contract]
pub mod StwoCircuitRouter {
    use core::poseidon::poseidon_hash_span;
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ClassHash, ContractAddress, get_caller_address};
    use stwo_circuit_phases::pack::{n_slots, unpack_u32};
    use crate::phases::{
        IStwoPhasesBeginDispatcherTrait, IStwoPhasesBeginLibraryDispatcher,
        IStwoPhasesFriDispatcherTrait, IStwoPhasesFriLibraryDispatcher,
        IStwoPhasesMerkleDispatcherTrait, IStwoPhasesMerkleLibraryDispatcher, TreeSection,
    };
    use super::{Checkpoint, TAG_DONE, TAG_FREE, TAG_FRI, TAG_MERKLE, compute_fact};

    #[storage]
    struct Storage {
        class_begin: ClassHash,
        class_merkle: ClassHash,
        class_fri: ClassHash,
        checkpoints: Map<(ContractAddress, felt252), Checkpoint>,
        facts: Map<felt252, bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Step: Step,
        FactRegistered: FactRegistered,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Step {
        #[key]
        pub caller: ContractAddress,
        #[key]
        pub proof_id: felt252,
        pub tag: u8,
        pub state_hash: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FactRegistered {
        #[key]
        pub fact: felt252,
        pub caller: ContractAddress,
        pub proof_id: felt252,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        class_begin: ClassHash,
        class_merkle: ClassHash,
        class_fri: ClassHash,
    ) {
        self.class_begin.write(class_begin);
        self.class_merkle.write(class_merkle);
        self.class_fri.write(class_fri);
    }

    #[abi(embed_v0)]
    impl Impl of super::IStwoCircuitRouter<ContractState> {
        fn begin(
            ref self: ContractState,
            proof_id: felt252,
            head: Span<felt252>,
            head_n: u32,
            payload: Span<felt252>,
            lens: Span<u32>,
            trees: Span<u32>,
        ) -> Array<felt252> {
            let caller = get_caller_address();
            let slot = self.checkpoints.entry((caller, proof_id));
            assert(slot.read().tag == TAG_FREE, 'router: proof id in use');

            let mut sections = split_sections(payload, lens);
            let tree_sections = tree_sections(ref sections, trees);
            let state = IStwoPhasesBeginLibraryDispatcher { class_hash: self.class_begin.read() }
                .run_begin(head, head_n);
            let state = if tree_sections.is_empty() {
                state
            } else {
                IStwoPhasesMerkleLibraryDispatcher { class_hash: self.class_merkle.read() }
                    .run_merkle(state.span(), tree_sections.span())
            };
            self.store(slot_key(caller, proof_id), TAG_MERKLE, state.span());
            state
        }

        fn merkle(
            ref self: ContractState,
            proof_id: felt252,
            state: Span<felt252>,
            payload: Span<felt252>,
            lens: Span<u32>,
            trees: Span<u32>,
        ) -> Array<felt252> {
            let caller = get_caller_address();
            self.check(slot_key(caller, proof_id), TAG_MERKLE, state);
            let mut sections = split_sections(payload, lens);
            let tree_sections = tree_sections(ref sections, trees);
            let state = IStwoPhasesMerkleLibraryDispatcher { class_hash: self.class_merkle.read() }
                .run_merkle(state, tree_sections.span());
            self.store(slot_key(caller, proof_id), TAG_MERKLE, state.span());
            state
        }

        fn answers(
            ref self: ContractState,
            proof_id: felt252,
            state: Span<felt252>,
            payload: Span<felt252>,
            lens: Span<u32>,
        ) -> Array<felt252> {
            let caller = get_caller_address();
            self.check(slot_key(caller, proof_id), TAG_MERKLE, state);
            let mut sections = split_sections(payload, lens);
            let (sampled, n_sampled) = sections.pop_front().unwrap();
            let mut queried = array![];
            let mut n_qv = array![];
            for (slots, n) in sections {
                queried.append(slots);
                n_qv.append(n);
            }
            let state = IStwoPhasesMerkleLibraryDispatcher { class_hash: self.class_merkle.read() }
                .run_answers(state, sampled, n_sampled, queried.span(), n_qv.span());
            self.store(slot_key(caller, proof_id), TAG_FRI, state.span());
            state
        }

        fn fri(
            ref self: ContractState,
            proof_id: felt252,
            state: Span<felt252>,
            payload: Span<felt252>,
            n_values: u32,
        ) -> Array<felt252> {
            let caller = get_caller_address();
            self.check(slot_key(caller, proof_id), TAG_FRI, state);
            assert(payload.len() == n_slots(n_values), 'router: payload length');
            let (state, done) = IStwoPhasesFriLibraryDispatcher { class_hash: self.class_fri.read() }
                .run_fri(state, payload, n_values);
            match done {
                Some((circuit_hash, output_hash)) => {
                    let fact = compute_fact(circuit_hash, output_hash);
                    self.facts.entry(fact).write(true);
                    self.store(slot_key(caller, proof_id), TAG_DONE, array![fact].span());
                    self.emit(FactRegistered { fact, caller, proof_id });
                },
                None => { self.store(slot_key(caller, proof_id), TAG_FRI, state.span()); },
            }
            state
        }

        fn is_valid(self: @ContractState, fact: felt252) -> bool {
            self.facts.entry(fact).read()
        }

        fn probe_unpack(self: @ContractState, payload: Span<felt252>, n_values: u32) -> u32 {
            unpack_u32(payload, n_values).len()
        }

        fn probe_noop(self: @ContractState, payload: Span<felt252>) -> u32 {
            payload.len()
        }

        fn checkpoint(
            self: @ContractState, caller: ContractAddress, proof_id: felt252,
        ) -> Checkpoint {
            self.checkpoints.entry((caller, proof_id)).read()
        }

        fn phase_classes(self: @ContractState) -> (ClassHash, ClassHash, ClassHash) {
            (self.class_begin.read(), self.class_merkle.read(), self.class_fri.read())
        }
    }

    #[generate_trait]
    impl Private of PrivateTrait {
        /// The slot must hold `tag` and the hash of the echoed `state`.
        fn check(
            self: @ContractState, key: (ContractAddress, felt252), tag: u8, state: Span<felt252>,
        ) {
            let cp = self.checkpoints.entry(key).read();
            assert(cp.tag == tag, 'router: wrong phase');
            assert(cp.state_hash == poseidon_hash_span(state), 'router: bad state echo');
        }

        fn store(
            ref self: ContractState, key: (ContractAddress, felt252), tag: u8, state: Span<felt252>,
        ) {
            let state_hash = poseidon_hash_span(state);
            self.checkpoints.entry(key).write(Checkpoint { tag, state_hash });
            let (caller, proof_id) = key;
            self.emit(Step { caller, proof_id, tag, state_hash });
        }
    }

    fn slot_key(caller: ContractAddress, proof_id: felt252) -> (ContractAddress, felt252) {
        (caller, proof_id)
    }

    /// Cuts `payload` into its independently fast-path-packed sections of `lens` felts:
    /// `(slots, n_felts)` per section, still packed.
    fn split_sections(payload: Span<felt252>, lens: Span<u32>) -> Array<(Span<felt252>, u32)> {
        let mut sections = array![];
        let mut offset = 0;
        for l in lens {
            let slots = n_slots(*l);
            sections.append((payload.slice(offset, slots), *l));
            offset += slots;
        }
        assert(offset == payload.len(), 'router: payload length');
        sections
    }

    /// Pairs the remaining sections `(queried_values, decommitment)*` with `trees`.
    fn tree_sections(
        ref sections: Array<(Span<felt252>, u32)>, trees: Span<u32>,
    ) -> Array<TreeSection> {
        let mut out = array![];
        for tree_idx in trees {
            let (queried_values, n_qv) = sections.pop_front().expect('router: missing qv');
            let (decommitment, n_dec) = sections.pop_front().expect('router: missing dec');
            out
                .append(
                    TreeSection {
                        tree_idx: *tree_idx, queried_values, n_qv, decommitment, n_dec,
                    },
                );
        }
        assert(sections.is_empty(), 'router: extra sections');
        out
    }
}

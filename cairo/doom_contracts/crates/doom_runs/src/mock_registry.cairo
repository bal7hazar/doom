// SPDX-License-Identifier: Apache-2.0
//! A stand-in for P4.0's `StwoCircuitRouter` fact store, for **tests and devnet drives only**.
//!
//! `DoomRuns` uses exactly one entrypoint of the router, the read-only `is_valid(fact)`
//! (`docs/design/onchain-verifier.md` §6). Registering a fact for real costs the five-phase
//! verification of a 96 k-felt root proof (3.81e9 L2 gas); this class lets the consumer's own
//! rules and gas be measured without paying for it. It is never deployed in production — the
//! version table points at a real router address.
#[starknet::contract]
pub mod MockFactRegistry {
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };

    #[storage]
    struct Storage {
        facts: Map<felt252, bool>,
    }

    #[starknet::interface]
    pub trait IMockFactRegistry<TContractState> {
        fn is_valid(self: @TContractState, fact: felt252) -> bool;
        fn register(ref self: TContractState, fact: felt252);
    }

    #[abi(embed_v0)]
    impl Impl of IMockFactRegistry<ContractState> {
        fn is_valid(self: @ContractState, fact: felt252) -> bool {
            self.facts.entry(fact).read()
        }

        fn register(ref self: ContractState, fact: felt252) {
            self.facts.entry(fact).write(true);
        }
    }
}

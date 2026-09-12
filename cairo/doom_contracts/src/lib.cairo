// SPDX-License-Identifier: Apache-2.0

#[starknet::interface]
pub trait ICounter<TContractState> {
    fn get(self: @TContractState) -> u32;
    fn increment(ref self: TContractState);
}

/// Trivial contract skeleton standing in for `DoomRuns` (PLAN.md §2, §4)
/// until Phase 4 wires in real Stwo fact verification and run submission.
#[starknet::contract]
mod Counter {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    struct Storage {
        value: u32,
    }

    #[abi(embed_v0)]
    impl CounterImpl of super::ICounter<ContractState> {
        fn get(self: @ContractState) -> u32 {
            self.value.read()
        }

        fn increment(ref self: ContractState) {
            self.value.write(self.value.read() + 1);
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
//! A minimal ERC20 stand-in for the fee token (STRK) of the commitment tests: `mint`,
//! `approve`, `transfer`, `transfer_from`, `balance_of`, `allowance`. The snake-case
//! entrypoints are the ones `DoomRuns::IERC20` calls. Never deployed outside snforge.
#[starknet::contract]
pub mod MockERC20 {
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
    }

    #[starknet::interface]
    pub trait IMockERC20<TContractState> {
        fn mint(ref self: TContractState, to: ContractAddress, amount: u256);
        fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;
        fn allowance(
            self: @TContractState, owner: ContractAddress, spender: ContractAddress,
        ) -> u256;
        fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
        fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
        fn transfer_from(
            ref self: TContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool;
    }

    #[abi(embed_v0)]
    impl Impl of IMockERC20<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, amount: u256) {
            self.balances.entry(to).write(self.balances.entry(to).read() + amount);
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            self.allowances.entry((get_caller_address(), spender)).write(amount);
            true
        }

        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress,
        ) -> u256 {
            self.allowances.entry((owner, spender)).read()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.entry(account).read()
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            self.move(get_caller_address(), recipient, amount);
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            let spender = get_caller_address();
            let allowed = self.allowances.entry((sender, spender)).read();
            assert(allowed >= amount, 'mock: allowance');
            self.allowances.entry((sender, spender)).write(allowed - amount);
            self.move(sender, recipient, amount);
            true
        }
    }

    #[generate_trait]
    impl Private of PrivateTrait {
        fn move(ref self: ContractState, from: ContractAddress, to: ContractAddress, amount: u256) {
            let balance = self.balances.entry(from).read();
            assert(balance >= amount, 'mock: balance');
            self.balances.entry(from).write(balance - amount);
            self.balances.entry(to).write(self.balances.entry(to).read() + amount);
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

use doom_contracts::{ICounterDispatcher, ICounterDispatcherTrait};
use snforge_std::{ContractClassTrait, DeclareResultTrait, declare};

#[test]
fn test_increment() {
    let contract = declare("Counter").unwrap().contract_class();
    let (contract_address, _) = contract.deploy(@array![]).unwrap();
    let dispatcher = ICounterDispatcher { contract_address };

    assert(dispatcher.get() == 0, 'initial not zero');
    dispatcher.increment();
    assert(dispatcher.get() == 1, 'increment failed');
}

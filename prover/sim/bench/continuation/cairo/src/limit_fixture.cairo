// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0
//! Tiny protocol-only counter for VM lifecycle tests, not a game replacement.
use starknet::testing::cheatcode;

#[executable]
pub fn counter(initial: Span<felt252>) -> Array<felt252> {
    let mut input = initial;
    let mut value = *input.pop_front().expect('counter requires value');
    loop {
        let mut args = cheatcode::<'hp_poll'>(array![].span());
        let action = *args.pop_front().expect('action');
        if action == 0 {
            value += *args.pop_front().expect('word');
            let _ = cheatcode::<'hp_status'>(array![0].span());
            let _ = cheatcode::<'hp_frame'>(array![value].span());
        } else if action == 1 {
            let _ = cheatcode::<'hp_state'>(array![value].span());
        } else {
            return array![];
        }
    }
}

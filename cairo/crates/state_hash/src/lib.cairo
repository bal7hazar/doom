// SPDX-License-Identifier: Apache-2.0

use core::poseidon::poseidon_hash_span;

/// Canonical Poseidon hash of a serialized state.
pub fn hash_state(values: Span<felt252>) -> felt252 {
    poseidon_hash_span(values)
}

/// Fold a previous hash together with a new batch of felts into one hash.
pub fn chain(prev: felt252, values: Span<felt252>) -> felt252 {
    let mut combined: Array<felt252> = array![prev];
    let mut i: u32 = 0;
    loop {
        if i == values.len() {
            break;
        }
        combined.append(*values.at(i));
        i += 1;
    }
    poseidon_hash_span(combined.span())
}

#[cfg(test)]
mod tests {
    use super::{chain, hash_state};

    #[test]
    fn test_hash_state_is_deterministic() {
        let values: Array<felt252> = array![1, 2, 3];
        assert(hash_state(values.span()) == hash_state(values.span()), 'deterministic');
    }

    #[test]
    fn test_hash_state_changes_with_input() {
        let a: Array<felt252> = array![1, 2, 3];
        let b: Array<felt252> = array![1, 2, 4];
        assert(hash_state(a.span()) != hash_state(b.span()), 'differs on differing input');
    }

    #[test]
    fn test_hash_state_sensitive_to_order() {
        let a: Array<felt252> = array![1, 2];
        let b: Array<felt252> = array![2, 1];
        assert(hash_state(a.span()) != hash_state(b.span()), 'order matters');
    }

    #[test]
    fn test_chain_is_deterministic_and_depends_on_prev() {
        let values: Array<felt252> = array![10, 20];
        let h1 = chain(0, values.span());
        let h2 = chain(0, values.span());
        let h3 = chain(1, values.span());
        assert(h1 == h2, 'deterministic chain');
        assert(h1 != h3, 'depends on prev hash');
    }
}

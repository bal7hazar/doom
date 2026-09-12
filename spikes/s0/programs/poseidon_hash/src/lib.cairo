//! Poseidon hash of an array of `n` felts (poseidon builtin).
//!
//! Stand-in for the per-segment state hash `h = poseidon(serialized state)`
//! (CONTEXT §9). Run with `n = 1000`.

use core::poseidon::poseidon_hash_span;

#[executable]
fn main(n: u32) -> felt252 {
    let mut arr: Array<felt252> = ArrayTrait::new();
    let mut i: u32 = 0;
    while i != n {
        let v: felt252 = i.into();
        arr.append(v * 7 + 3);
        i += 1;
    }
    poseidon_hash_span(arr.span())
}

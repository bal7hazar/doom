//! Segment stub: stands in for `run_segment` (K tics of the game) in the recursion spike.
//!
//! Input `(h_in, n)`; does ~2^17 steps of "Doom-like" u32 arithmetic (the loop result is folded
//! into a tiny check so it cannot be optimized away); outputs `[h_in, h_out, n, status]` with
//! `h_out = poseidon(h_in, n)`, so a chain of N leaves is verifiable by `h_out[i] == h_in[i+1]`.
use core::num::traits::{WrappingAdd, WrappingMul};
use core::poseidon::poseidon_hash_span;

/// ~61 steps per iteration with u32 wrapping arithmetic (CONTEXT §4.3) -> ~2^17 steps.
const N_ITERS: u32 = 2100;
const STATUS_OK: felt252 = 1;

#[executable]
fn main(h_in: felt252, n: u32) -> (felt252, felt252, felt252, felt252) {
    let mut a: u32 = n;
    let mut b: u32 = 0x9e3779b9;
    let mut i: u32 = 0;
    while i < N_ITERS {
        let t = a.wrapping_mul(b).wrapping_add(7);
        b = b.wrapping_add(a.wrapping_mul(3));
        a = t.wrapping_mul(t).wrapping_add(b);
        i += 1;
    }
    // Bind the loop to the output without changing the public interface.
    let status = if a == b { STATUS_OK + 1 } else { STATUS_OK };
    let h_out = poseidon_hash_span(array![h_in, n.into()].span());
    (h_in, h_out, n.into(), status)
}

//! `segment_stub` with a much longer run (S4b measurement 3): a segment of ~1.59 M Cairo steps,
//! i.e. more than the 2^20 steps the segment budget was assumed to be capped at.
//!
//! `N_ITERS` is rewritten in place by `scripts/trace_log_probe.sh`, which sweeps the run length to
//! find where the Cairo AIR's largest component — the thing `trace_log_size` is actually derived
//! from — crosses 2^20.
//!
//! Same interface and chaining as `segment_stub`: input `(h_in, n)`, output
//! `[h_in, h_out, n, status]` with `h_out = poseidon(h_in, n)`.
use core::num::traits::{WrappingAdd, WrappingMul};
use core::poseidon::poseidon_hash_span;

/// ~69 steps per iteration (as in `segment_stub`) -> ~1.59 M steps: more than 2^20 steps, yet
/// still `trace_log_size = 20` (see `scripts/trace_log_probe.sh`), so the `doom` registry proves it.
const N_ITERS: u32 = 23000;
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
    let status = if a == b {
        STATUS_OK + 1
    } else {
        STATUS_OK
    };
    let h_out = poseidon_hash_span(array![h_in, n.into()].span());
    (h_in, h_out, n.into(), status)
}

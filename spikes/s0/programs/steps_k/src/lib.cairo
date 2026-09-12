//! A program whose Cairo step count is ~= 2^k, with `k` given as the argument.
//!
//! The hot loop is felt252-only (add/mul/sub + a `jnz` on the counter), so the
//! trace grows in *steps* and uses **no builtin** beyond what the `#[executable]`
//! wrapper itself needs. That isolates the "steps" axis for the RSS / time curve.
//!
//! `BASE_STEPS` and `STEPS_PER_ITER` are calibrated with
//! `scarb execute --print-resource-usage` (see scripts/calibrate_steps_k.sh).
//! Measured model on Scarb 2.19.4 (stwo_no_ecop layout):
//!
//!     n_steps(k) = (65 + 14*k) + 6 * iters      [the 14*k term is the 2^k loop]
//!     iters      = (2^k - BASE_STEPS) / STEPS_PER_ITER
//!
//! With STEPS_PER_ITER = 6 and BASE_STEPS = 400 this lands 55..111 steps *below*
//! 2^k for k in 16..21 — deliberately under, so "k = 20" means "a hair under the
//! CanonicalSmall 2^20 trace ceiling" rather than one step over it.

/// Nominal step budget consumed outside the hot loop. Tuned so that the realised
/// step count stays just below 2^k for every k in the measured range.
const BASE_STEPS: u64 = 400;
/// Steps per hot-loop iteration (measured exactly).
const STEPS_PER_ITER: u64 = 6;

#[executable]
fn main(k: u32) -> felt252 {
    // target = 2^k
    let mut target: u64 = 1;
    let mut j: u32 = 0;
    while j != k {
        target = target * 2;
        j += 1;
    }

    let iters: u64 = if target > BASE_STEPS {
        (target - BASE_STEPS) / STEPS_PER_ITER
    } else {
        0
    };

    let mut rem: felt252 = iters.into();
    let mut acc: felt252 = 1;
    while rem != 0 {
        acc = acc * 5 + 3;
        rem = rem - 1;
    }
    acc
}

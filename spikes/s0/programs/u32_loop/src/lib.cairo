//! u32 wrapping arithmetic (LCG), exercising the range_check builtin.
//!
//! Argument: `n` — number of iterations.

use core::num::traits::{WrappingAdd, WrappingMul, WrappingSub};

#[executable]
fn main(n: u32) -> u32 {
    let mut a: u32 = 12345;
    let mut b: u32 = 6789;
    let mut i: u32 = 0;
    while i != n {
        a = a.wrapping_mul(1664525).wrapping_add(1013904223);
        b = b.wrapping_add(a).wrapping_sub(i);
        i += 1;
    }
    a.wrapping_add(b)
}

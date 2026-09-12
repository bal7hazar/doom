//! u64 `&` / `^`, which compile to the **bitwise builtin**.
//!
//! R4-A1 fixture: the Scarb 2.16 adapter panicked with `index out of bounds`
//! (adapter/src/memory.rs:96) on traces using this builtin.
//!
//! Argument: `n` — number of iterations.

#[executable]
fn main(n: u32) -> u64 {
    let mut x: u64 = 0x0123456789abcdef;
    let mut y: u64 = 0xfedcba9876543210;
    let mut i: u32 = 0;
    while i != n {
        let t = x ^ y;
        y = x & 0x0f0f0f0f0f0f0f0f;
        x = t;
        i += 1;
    }
    x ^ y
}

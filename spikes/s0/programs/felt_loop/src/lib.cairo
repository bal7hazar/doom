//! felt252-only arithmetic with **negative intermediate values** written to memory.
//!
//! R4-A1 fixture: `5 - acc` underflows in the integers, so the felt252 result is
//! `P - (acc - 5)`, a value `>= 2^128`. `buf.append(d)` forces that value into a
//! *memory cell* (not just a register), which is what made the Scarb 2.16 adapter
//! panic with `Cannot convert F252 to u128` (adapter/src/memory.rs:291).
//!
//! Argument: `n` — number of iterations. Even `n = 1` produces one big felt.

#[executable]
fn main(n: u32) -> felt252 {
    let mut acc: felt252 = 1;
    let mut sum: felt252 = 0;
    let mut buf: Array<felt252> = ArrayTrait::new();
    let mut i: u32 = 0;
    while i != n {
        // Pure felt252 add/mul: ~1-3 steps each, no range checks.
        acc = acc * 3 + 7;
        // Negative intermediate: for acc > 5 this is P - (acc - 5) >= 2^128.
        let d: felt252 = 5 - acc;
        sum = sum + d;
        // Force the big felt into memory.
        buf.append(d);
        i += 1;
    }
    let mut j: u32 = 0;
    let mut check: felt252 = 0;
    while j != buf.len() {
        check = check + *buf.at(j);
        j += 1;
    }
    sum + check
}

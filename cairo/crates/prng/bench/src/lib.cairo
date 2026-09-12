// SPDX-License-Identifier: Apache-2.0

//! Step-budget harness for `prng` (method: see `bench/README.md`).
//!
//! `main(op, n)` runs `n` iterations of one operation. The per-iteration
//! cost is obtained by differencing two run lengths, which cancels every
//! fixed cost (bootstrap, table construction, serialization):
//!
//!   cost(op) = (steps(op, 2N) - steps(op, N)) / N
//!
//! and the operation's own cost is `cost(op) - cost(0)` (op 0 is the bare
//! loop). Each op has its own loop, so no `op` dispatch is paid inside a
//! measured body. Same protocol as spike S1
//! (`spikes/s1/tools/measure.py`).
//!
//! Op 5 is not an API call: it isolates the cost of the cursor wrap alone,
//! which is what pins the floor documented in the crate README.

use prng::{Prng, PrngTrait, TABLE_LEN, new};

fn table() -> Array<u8> {
    let mut t: Array<u8> = array![];
    let mut i: u32 = 0;
    while i != TABLE_LEN {
        let v: u32 = (i * 167 + 61) % 256;
        t.append(v.try_into().unwrap());
        i += 1;
    }
    t
}

/// Bare loop: the accumulator update and the counter, nothing else.
fn bare(n: u32) -> (Prng, felt252) {
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    while i != n {
        acc = acc + 1;
        i += 1;
    }
    (new(), acc)
}

fn draw(table: Span<u8>, n: u32) -> (Prng, felt252) {
    let mut rng = new();
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    while i != n {
        let (r, v) = rng.next(table);
        rng = r;
        acc = acc + v.into();
        i += 1;
    }
    (rng, acc)
}

fn below(table: Span<u8>, n: u32) -> (Prng, felt252) {
    let mut rng = new();
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    while i != n {
        let (r, v) = rng.below(table, 8);
        rng = r;
        acc = acc + v.into();
        i += 1;
    }
    (rng, acc)
}

fn chance(table: Span<u8>, n: u32) -> (Prng, felt252) {
    let mut rng = new();
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    while i != n {
        let (r, hit) = rng.chance(table, 128);
        rng = r;
        acc = acc + if hit {
            1
        } else {
            0
        };
        i += 1;
    }
    (rng, acc)
}

fn sub_random(table: Span<u8>, n: u32) -> (Prng, felt252) {
    let mut rng = new();
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    while i != n {
        let (r, v) = rng.sub_random(table);
        rng = r;
        acc = acc + v.into();
        i += 1;
    }
    (rng, acc)
}

/// Decomposition: the cursor wrap, no table read.
fn wrap_only(n: u32) -> (Prng, felt252) {
    let mut idx: u32 = 0;
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    while i != n {
        idx = if idx == TABLE_LEN - 1 {
            0
        } else {
            idx + 1
        };
        acc = acc + 1;
        i += 1;
    }
    (Prng { index: idx }, acc)
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let t = table();
    let table = t.span();
    let (rng, acc) = if op == 1 {
        draw(table, n)
    } else if op == 2 {
        below(table, n)
    } else if op == 3 {
        chance(table, n)
    } else if op == 4 {
        sub_random(table, n)
    } else if op == 5 {
        wrap_only(n)
    } else {
        bare(n)
    };
    acc + rng.index.into()
}

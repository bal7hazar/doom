// SPDX-License-Identifier: Apache-2.0

//! Step-budget harness for `state_hash` (method: see `bench/README.md`).
//!
//! Here `n` is the **number of felts in the state**, not a repetition
//! count, so the differential
//!
//!   cost(op) = (steps(op, 2N) - steps(op, N)) / N
//!
//! is the cost *per felt hashed*. Op 0 is the bare loop, op 1 builds the
//! array without hashing it, and op 2 builds it and hashes it — so
//! `net(2) - net(1)` isolates Poseidon from the array construction that
//! S1 §5.8 found to be the larger half of the bill.
//!
//! Op 6 is the exception: it folds one commitment per iteration, so its
//! number is per call, not per felt.

use core::poseidon::poseidon_hash_span;
use state_hash::{SCHEMA_VERSION, commit_input, hash_tagged, inputs_seed, open, seal};

fn bare(n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    while i != n {
        acc = acc + 1;
        i += 1;
    }
    acc
}

/// Build the state array, do not hash it.
fn build(n: u32) -> felt252 {
    let mut buf: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i != n {
        buf.append(i.into() * 7 + 3);
        i += 1;
    }
    (*buf.at(0)) + buf.len().into()
}

/// Build the state array and hash it with the tagged scheme.
fn build_and_hash(n: u32) -> felt252 {
    let mut buf: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i != n {
        buf.append(i.into() * 7 + 3);
        i += 1;
    }
    hash_tagged('S', 1, buf.span())
}

/// Build the array and hash it with bare `poseidon_hash_span`, with no
/// domain separation: the reference point for what Poseidon itself costs.
fn build_and_hash_raw(n: u32) -> felt252 {
    let mut buf: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i != n {
        buf.append(i.into() * 7 + 3);
        i += 1;
    }
    poseidon_hash_span(buf.span())
}

/// The cheap path: `open`, append, `seal` -- nothing is ever copied.
fn open_seal(n: u32) -> felt252 {
    let mut buf = open('S', SCHEMA_VERSION, n);
    let mut i: u32 = 0;
    while i != n {
        buf.append(i.into() * 7 + 3);
        i += 1;
    }
    seal(buf.span())
}

/// One `commit_input` fold per iteration: the input-log commitment, one
/// packed transport felt (seven tics) at a time.
fn commit(n: u32) -> felt252 {
    let mut commitment = inputs_seed();
    let mut i: u32 = 0;
    while i != n {
        commitment = commit_input(commitment, i.into() * 7 + 3);
        i += 1;
    }
    commitment
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    if op == 1 {
        build(n)
    } else if op == 2 {
        build_and_hash(n)
    } else if op == 3 {
        open_seal(n)
    } else if op == 5 {
        build_and_hash_raw(n)
    } else if op == 6 {
        commit(n)
    } else {
        bare(n)
    }
}

// SPDX-License-Identifier: Apache-2.0

//! Step-budget harness for `ticcmd` (method: see `bench/README.md`).
//!
//! Differential measurement, one loop per operation:
//!   cost(op) = (steps(op, 2N) - steps(op, N)) / N, minus the bare loop.
//!
//! Every loop reads its input from a small pool with a cycling cursor, and
//! the bare loop (op 0) does the same read. Without that, the compiler
//! hoists a loop-invariant `decode(word)` out of the loop and the measured
//! cost collapses to 2 steps.
//!
//! The headline number is the per-tic decode cost, to be compared with the
//! 106 steps S1 §5.1 measured for a 5-field 16-bit packed record.

use ticcmd::{
    PackerTrait, TicCmd, decode, decode_offsets, encode, pack7, packer, try_decode, unpack7,
};

const POOL: u32 = 8;

/// Eight distinct canonical commands, so that nothing is loop-invariant.
fn pool() -> Array<felt252> {
    let mut out: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i != POOL {
        let k: i64 = i.into();
        out
            .append(
                encode(
                    TicCmd {
                        forward: k - 4,
                        side: 3 - k,
                        angle_turn: (k - 4) * 256,
                        buttons: i.try_into().unwrap(),
                    },
                ),
            );
        i += 1;
    }
    out
}

fn step(cursor: u32) -> u32 {
    if cursor == POOL - 1 {
        0
    } else {
        cursor + 1
    }
}

/// Bare loop: the pool read, the cursor step, the accumulator.
fn bare(pool: Span<felt252>, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut cursor: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        acc = acc + *pool.at(cursor);
        cursor = step(cursor);
        i += 1;
    }
    acc
}

fn decode_loop(pool: Span<felt252>, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut cursor: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        let cmd = decode(*pool.at(cursor));
        acc = acc + cmd.forward.into() + cmd.side.into() + cmd.angle_turn.into();
        cursor = step(cursor);
        i += 1;
    }
    acc
}

fn decode_offsets_loop(pool: Span<felt252>, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut cursor: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        let (forward, side, turn, buttons) = decode_offsets(*pool.at(cursor));
        acc = acc + forward.into() + side.into() + turn.into() + buttons.into();
        cursor = step(cursor);
        i += 1;
    }
    acc
}

fn try_decode_loop(pool: Span<felt252>, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut cursor: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        acc = acc
            + match try_decode(*pool.at(cursor)) {
                Option::Some(cmd) => cmd.forward.into(),
                Option::None => 0,
            };
        cursor = step(cursor);
        i += 1;
    }
    acc
}

fn encode_loop(pool: Span<felt252>, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut cursor: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        acc = acc + encode(decode(*pool.at(cursor)));
        cursor = step(cursor);
        i += 1;
    }
    acc
}

/// One `Packer::push` per tic: what the proving path pays.
fn push_loop(pool: Span<felt252>, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut cursor: u32 = 0;
    let mut p = packer();
    let mut i: u32 = 0;
    while i != n {
        let (next, group) = p.push(*pool.at(cursor));
        p = next;
        acc = acc + match group {
            Option::Some(felt) => felt,
            Option::None => 0,
        };
        cursor = step(cursor);
        i += 1;
    }
    acc
}

/// One `pack7` per iteration (seven span reads): what a batch caller pays
/// per *group*, i.e. per seven tics.
fn pack7_loop(pool: Span<felt252>, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut cursor: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        acc = acc + pack7(pool.slice(0, 7)) + *pool.at(cursor);
        cursor = step(cursor);
        i += 1;
    }
    acc
}

/// One `unpack7` per iteration: the off-path cost of reading a log back.
fn unpack7_loop(pool: Span<felt252>, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut cursor: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        let words = unpack7(*pool.at(cursor));
        acc = acc + *words.at(0) + *words.at(6);
        cursor = step(cursor);
        i += 1;
    }
    acc
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let words = pool();
    let pool = words.span();
    if op == 1 {
        decode_loop(pool, n)
    } else if op == 2 {
        decode_offsets_loop(pool, n)
    } else if op == 3 {
        try_decode_loop(pool, n)
    } else if op == 4 {
        encode_loop(pool, n)
    } else if op == 5 {
        push_loop(pool, n)
    } else if op == 6 {
        pack7_loop(pool, n)
    } else if op == 7 {
        unpack7_loop(pool, n)
    } else {
        bare(pool, n)
    }
}

// SPDX-License-Identifier: Apache-2.0

//! Step-budget harness for `segment` (method: see `bench/README.md`).
//!
//! Here `n` is the **number of tics in the segment**, so the differential
//!
//!   cost(op) = (steps(op, 2N) - steps(op, N)) / N
//!
//! is the cost *per tic*. Building the command span scales with `n` too and
//! does not cancel against the bare loop, so op 1 builds it and nothing
//! else and every other op is netted against op 1 (`base_op` in
//! `budget.json`).
//!
//! The engine under measurement is deliberately trivial — one addition per
//! tic — so that what is left is the runner's own overhead: the span read,
//! the engine dispatch, the input-log packing and the terminal-status test.
//! The target is ≤ 30 steps/tic (S1 §5.8 measured a bare tic loop carrying
//! full state by value at 29).

use segment::{SegmentEngine, Stats, Status, run_segment};
use state_hash::{commit_input, inputs_seed};
use ticcmd::{PackerTrait, packer};

/// A command is the 32-bit word `ticcmd::encode` produces, which is what
/// the proving path actually holds: one felt per tic, no decoding needed to
/// recompute the input-log commitment.
type Word = felt252;

/// The smallest possible game: the state is a felt, a tic adds the command
/// word to it.
#[derive(Copy, Drop, PartialEq)]
struct Counter {
    value: felt252,
}

impl CounterEngine of SegmentEngine<Counter, Word> {
    fn step(state: Counter, cmd: Word) -> (Counter, Status) {
        (Counter { value: state.value + cmd }, Status::Running)
    }
    fn hash(state: @Counter) -> felt252 {
        *state.value
    }
    fn stats(state: @Counter) -> Stats {
        Stats { kills: 0, items: 0, secrets: 0 }
    }
    fn word(cmd: @Word) -> felt252 {
        *cmd
    }
}

fn words(n: u32) -> Array<Word> {
    let mut out: Array<Word> = array![];
    let mut i: u32 = 0;
    while i != n {
        out.append(i.into() * 7 + 3);
        i += 1;
    }
    out
}

fn bare(n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    while i != n {
        acc = acc + 1;
        i += 1;
    }
    acc
}

/// Baseline: build the command span, run nothing.
fn build_only(n: u32) -> felt252 {
    let cmds = words(n);
    *cmds.at(0) + cmds.len().into()
}

/// The runner itself.
fn run(n: u32) -> felt252 {
    let cmds = words(n);
    let (state, output) = run_segment::<
        Counter, Word, CounterEngine,
    >(Counter { value: 0 }, cmds.span(), 0, 0xFFFFFFF);
    state.value + output.inputs_commitment + output.tic_end.into()
}

/// The same loop with the input-log commitment removed, to price it.
fn run_without_commitment(n: u32) -> felt252 {
    let cmds = words(n);
    let mut state = Counter { value: 0 };
    let mut ran: u32 = 0;
    while ran != cmds.len() {
        let cmd = *cmds.at(ran);
        let (next, reported) = CounterEngine::step(state, cmd);
        state = next;
        ran += 1;
        if reported != Status::Running {
            break;
        }
    }
    state.value + ran.into()
}

/// The commitment on its own: pack seven words to a felt and fold.
fn commitment_only(n: u32) -> felt252 {
    let cmds = words(n);
    let mut commitment = inputs_seed();
    let mut group = packer();
    let mut i: u32 = 0;
    while i != cmds.len() {
        let (advanced, complete) = group.push(*cmds.at(i));
        group = advanced;
        match complete {
            Option::Some(felt) => { commitment = commit_input(commitment, felt); },
            Option::None => {},
        }
        i += 1;
    }
    match group.seal() {
        Option::Some(felt) => { commitment = commit_input(commitment, felt); },
        Option::None => {},
    }
    commitment
}

/// The absolute floor: read the span, call the engine, nothing else.
fn step_loop_only(n: u32) -> felt252 {
    let cmds = words(n);
    let mut state = Counter { value: 0 };
    let mut i: u32 = 0;
    while i != cmds.len() {
        let (next, _) = CounterEngine::step(state, *cmds.at(i));
        state = next;
        i += 1;
    }
    state.value
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    if op == 1 {
        build_only(n)
    } else if op == 2 {
        run(n)
    } else if op == 3 {
        run_without_commitment(n)
    } else if op == 4 {
        commitment_only(n)
    } else if op == 5 {
        step_loop_only(n)
    } else {
        bare(n)
    }
}

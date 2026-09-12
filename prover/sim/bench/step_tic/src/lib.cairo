// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Stand-in for the real `step_tic` of the Hellproof game core, used by spike
//! S3 to measure the throughput of cairo-vm in a browser Worker.
//!
//! It has the shape the real thing will have:
//!  * input: the whole game state as an `Array<felt252>` plus one packed
//!    `ticcmd` felt,
//!  * body: pure `felt252` arithmetic that **reads and writes every state
//!    element**, with a data dependency between consecutive elements so that
//!    neither the Sierra optimizer nor the CASM backend can drop any of it,
//!  * output: the updated state, same length.
//!
//! ## Calibration
//!
//! The step count is a linear function of the state length, because the entry
//! code's `Serde` envelope dominates (measured with
//! `scarb execute --print-resource-usage`, Scarb 2.19.4, `enable-gas = false`):
//!
//! | what                                   | steps per state felt |
//! |----------------------------------------|----------------------|
//! | deserializing the `Array<felt252>` arg | 12.0                 |
//! | serializing the returned array         | 10.0                 |
//! | the mixing loop itself                 | 13.0                 |
//! | **total**                              | **35.0**             |
//!
//! `steps(n) = 35 * n + 69`, so the benchmark hits a given step budget by
//! choosing the state length:
//!
//! | case      | state felts | steps  |
//! |-----------|-------------|--------|
//! | 4 k       | 112         | 3 989  |
//! | 10 k      | 284         | 10 009 |
//! | full tic  | 1 500       | 52 569 |
//!
//! A 1 500-felt state can **not** be run in 4 000 steps in Cairo 2: its
//! `Serde` round trip alone is ~33 000 steps. See `docs/spikes/S3.md`.
//!
//! `step_tic_rounds` adds a second knob, `rounds`, which raises the arithmetic
//! cost (~9.4 steps per state felt per round) without changing the payload
//! size, so compute cost and transfer cost can be told apart.

/// Updates every element of `state` from the previous element and `cmd`.
fn mix(state: Array<felt252>, cmd: felt252) -> Array<felt252> {
    let mut out: Array<felt252> = ArrayTrait::new();
    let mut span = state.span();
    let mut carry: felt252 = cmd + 0x9e3779b97f4a7c15;
    while let Option::Some(value) = span.pop_front() {
        let x: felt252 = *value * 5 + carry;
        carry = x + 1;
        out.append(x);
    };
    out
}

/// Same, with `rounds` extra multiply-add rounds per element.
fn mix_rounds(state: Array<felt252>, cmd: felt252, rounds: u32) -> Array<felt252> {
    let mut out: Array<felt252> = ArrayTrait::new();
    let mut span = state.span();
    let mut carry: felt252 = cmd + 0x9e3779b97f4a7c15;
    while let Option::Some(value) = span.pop_front() {
        let mut x: felt252 = *value * 5 + carry;
        let mut k: u32 = 0;
        while k != rounds {
            x = x * 0x100000001b3 + 0x1f;
            k = k + 1;
        };
        carry = x + 1;
        out.append(x);
    };
    out
}

/// The benchmarked tic. Step count is `35 * state.len() + 69`.
#[executable]
pub fn step_tic(state: Array<felt252>, cmd: felt252) -> Array<felt252> {
    mix(state, cmd)
}

/// The benchmarked tic with a compute knob, to raise the step count at a
/// constant payload size.
#[executable]
pub fn step_tic_rounds(state: Array<felt252>, cmd: felt252, rounds: u32) -> Array<felt252> {
    mix_rounds(state, cmd, rounds)
}

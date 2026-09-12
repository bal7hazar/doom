// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

// Shared benchmark configuration.
//
// The step count of `step_tic` is `35 * state.len() + 69` (the `Serde`
// envelope of the state array dominates), so the state length is what selects
// the step budget. See bench/step_tic/src/lib.cairo.

export const WASM = '../pkg/hellproof_sim_bg.wasm';
export const EXECUTABLE = './step_tic/target/dev/step_tic.executable.json';

export const CASES = [
  { name: '4k', stateLen: 112 }, // 3 986 steps
  { name: '10k', stateLen: 284 }, // 10 006 steps
  { name: 'full-1500', stateLen: 1500 }, // 52 566 steps, 48 kB of state
];

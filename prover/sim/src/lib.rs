// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! `hellproof-sim` — real-time execution of a Cairo `#[executable]` (the
//! `step_tic` of the game core) at 35 Hz, in a browser Worker.
//!
//! Spike S3 / risk action R5-A1. The crate is deliberately execution-only: no
//! trace, no memory relocation, no proof mode by default. Proof generation
//! lives in `prover/wasm` (spike S2).

pub mod clock;
pub mod continuation;
pub mod core;

#[cfg(target_arch = "wasm32")]
pub mod wasm;

pub use crate::core::{
    array_body, decode_felts, encode_felts, RunMode, SimError, SimProgram, Timings, FELT_BYTES,
};

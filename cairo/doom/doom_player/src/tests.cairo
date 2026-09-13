// SPDX-License-Identifier: GPL-2.0-only
//! `scarb test -p doom_player`.
//!
//! * [`e1m1`] replays `scripts/model.py`'s reference vectors on the real
//!   Freedoom E1M1 -- thrust, friction, the bobbing curve, a psprite
//!   script, the pickup and damage tables, and a 350-tic scripted walk
//!   with a checksum;
//! * [`synthetic`] exercises every branch of the crate without asserting
//!   a single coordinate, so it also runs on the miniature level that
//!   `bench/coverage.py` compiles in.

mod e1m1;
mod synthetic;
pub mod vectors;

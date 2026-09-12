// SPDX-License-Identifier: GPL-2.0-only
//! Tests. `e1m1` replays the reference vectors `scripts/model.py` computes
//! from the WAD JSON on the real level; `synthetic` builds a six-sector
//! strip of its own (no level data) for the edge cases and the branch
//! coverage, and is what `bench/coverage.py` runs.

mod e1m1;
mod synthetic;
mod vectors;

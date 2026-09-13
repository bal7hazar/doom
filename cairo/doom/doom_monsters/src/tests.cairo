// SPDX-License-Identifier: GPL-2.0-only
//! The crate's test suite: the reference vectors of `scripts/model.py`
//! replayed on the real E1M1 (`e1m1`), the per-arm path tests that hold on
//! any level (`paths`, which is also what `bench/coverage.py` runs), the
//! property tests (`props`) and the table and scheduler tests that need no
//! map (`synthetic`).

mod e1m1;
mod paths;
mod props;
mod synthetic;
mod vectors;

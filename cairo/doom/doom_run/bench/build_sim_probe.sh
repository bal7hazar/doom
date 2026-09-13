#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
SIM_TARGET_DIR="${SIM_TARGET_DIR:-$REPO/prover/sim/target}"
OUT="${1:-/tmp/hellproof-game-sim-probe-lines}"
CARGO_TARGET_DIR="$SIM_TARGET_DIR" cargo build --manifest-path "$REPO/prover/sim/Cargo.toml" --lib --locked --jobs 2
rustc --edition=2021 "$HERE/sim_probe.rs" \
  --extern "hellproof_sim=$SIM_TARGET_DIR/debug/deps/libhellproof_sim.rlib" \
  -L "dependency=$SIM_TARGET_DIR/debug/deps" -o "$OUT"
printf '%s\n' "$OUT"

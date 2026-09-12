#!/usr/bin/env bash
# Baseline: run the Cairo circuit verifier (the on-chain program) on the monorepo's committed
# golden root proof (`four_leaves/root.proof`) and record steps/builtins/time/RSS.
#
# Usage: spikes/s4/scripts/baseline.sh
set -euo pipefail
source "$(dirname "$0")/env.sh"

OUT="$S4_DIR/results/baseline"
mkdir -p "$OUT"
GOLDEN="$PROVING/crates/stwo_run_and_prove_recursive_tree/test_data/goldens/four_leaves"

cd "$PROVING/stwo_cairo_verifier"
echo "== scarb $(scarb --version | head -1) ; proving @ $(git -C "$PROVING" rev-parse --short HEAD) =="

echo "== build stwo_circuit_verifier (profile proving, feature qm31_opcode) =="
timed "$OUT/build.time" scarb --profile proving build -p stwo_circuit_verifier --features qm31_opcode

echo "== execute on goldens/four_leaves/root.proof =="
timed "$OUT/execute.time" scarb --profile proving execute -p stwo_circuit_verifier \
  --features qm31_opcode --no-build --print-resource-usage --output none \
  --arguments-file "$GOLDEN/root.proof" | tee "$OUT/execute.log"

python3 -c "import json,sys; print('root.proof felts:', len(json.load(open(sys.argv[1]))))" "$GOLDEN/root.proof" | tee -a "$OUT/execute.log"
echo "done: $OUT"

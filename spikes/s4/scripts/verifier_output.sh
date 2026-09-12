#!/usr/bin/env bash
# Prints the on-chain verifier's `VerificationOutput.output_hash` (8 u32 words as felts) for a
# pipeline run's root proof, and saves it as results/N<N>_<reg>/verifier_output.json.
# Usage: spikes/s4/scripts/verifier_output.sh <N> [registry_name]
set -euo pipefail
source "$(dirname "$0")/env.sh"
N="${1:?usage: verifier_output.sh <N> [registry_name]}"
REG_NAME="${2:-doom}"
TAG="${TAG:-}"   # same suffix as run_pipeline.sh, when the run used one
WORK="$S4_WORK/pipeline_${N}_${REG_NAME}${TAG}"
RES="$S4_DIR/results/N${N}_${REG_NAME}${TAG}"
cd "$PROVING/stwo_cairo_verifier"
scarb --profile proving execute -p stwo_circuit_verifier --features qm31_opcode --no-build \
  --output none --print-program-output --arguments-file "$WORK/root.proof" > "$WORK/verifier_output.log" 2>&1
# Format: "Program output:" followed by one felt per line (decimal or hex), then "Saving..."/end.
python3 - "$WORK/verifier_output.log" "$RES/verifier_output.json" <<'EOF'
import json, re, sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if "Program output" in l)
felts = []
for l in lines[start + 1:]:
    l = l.strip()
    if not l or not re.fullmatch(r"(0x[0-9a-fA-F]+|\d+)", l):
        break
    felts.append(int(l, 0))
assert len(felts) == 8, felts
json.dump(felts, open(sys.argv[2], "w"))
print("VerificationOutput.output_hash words:", felts)
EOF

#!/usr/bin/env bash
# Runs the on-chain circuit verifier (the Cairo program a Starknet transaction executes) on a root
# proof the wrapper produced, and prints its resource usage and `VerificationOutput.output_hash`.
#
# Usage: e2e_verify_root.sh <root.proof>
# Environment: PROVING (monorepo clone @ cd7bc5f), ASDF_SCARB_VERSION (2.18.0).
set -euo pipefail

ROOT="${1:?usage: e2e_verify_root.sh <root.proof>}"
SCRATCH="${SCRATCH:-/tmp}"
PROVING="${PROVING:-$SCRATCH/proving-s4}"
export ASDF_SCARB_VERSION="${ASDF_SCARB_VERSION:-2.18.0}"

cd "$PROVING/stwo_cairo_verifier"
scarb --profile proving build -p stwo_circuit_verifier --features qm31_opcode >/dev/null

echo "== resource usage =="
scarb --profile proving execute -p stwo_circuit_verifier --features qm31_opcode --no-build \
  --print-resource-usage --output none --arguments-file "$ROOT"

echo "== VerificationOutput.output_hash =="
scarb --profile proving execute -p stwo_circuit_verifier --features qm31_opcode --no-build \
  --print-program-output --output none --arguments-file "$ROOT" \
  | sed -n '/Program output/,$p' | head -10

python3 -c "import json,sys;print('root.proof felts:', len(json.load(open(sys.argv[1]))))" "$ROOT"

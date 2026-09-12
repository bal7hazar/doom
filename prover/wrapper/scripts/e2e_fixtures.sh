#!/usr/bin/env bash
# Produces the fixtures the end-to-end test needs: N *browser-equivalent* segment proofs.
#
# The browser (`prover/wasm`) returns a bincode-serialized extended `CairoProof` of the segment
# run under the leaf simple bootloader. `stwo-run-and-prove --proof-format extended-binary` on the
# same program, the same input and the same prover parameters produces exactly that byte format,
# so this script stands in for the browser until the client lands.
#
# Usage: e2e_fixtures.sh <out_dir> [N]         (default N = 2)
# Environment (see spikes/s4/scripts/env.sh for the same knobs):
#   PROVING   monorepo clone @ cd7bc5f   (default: $SCRATCH/proving-s4)
#   BIN       its release binaries       (default: $PROVING/target/release)
#   S4_DIR    spikes/s4                  (default: repo's spikes/s4)
#   PARAMS    prover parameters JSON     (default: prover/wasm/harness/params/leaf.json)
set -euo pipefail

OUT="${1:?usage: e2e_fixtures.sh <out_dir> [N]}"
N="${2:-2}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

SCRATCH="${SCRATCH:-/tmp}"
PROVING="${PROVING:-$SCRATCH/proving-s4}"
BIN="${BIN:-$PROVING/target/release}"
S4_DIR="${S4_DIR:-$REPO/spikes/s4}"
PARAMS="${PARAMS:-$REPO/prover/wasm/harness/params/leaf.json}"
BOOTLOADER="$PROVING/crates/stwo_run_and_prove_recursive_tree/test_data/leaf_simple_bootloader_compiled.json"
STUB_DIR="$S4_DIR/programs/segment_stub"
EXE="$STUB_DIR/target/dev/segment_stub.executable.json"

for f in "$BIN/stwo-run-and-prove" "$BOOTLOADER" "$PARAMS"; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done
[ -f "$EXE" ] || ( cd "$STUB_DIR" && scarb build >/dev/null )

mkdir -p "$OUT"
H_IN="0x1"
SEGMENTS=""
for ((i = 0; i < N; i++)); do
  n=$((250 + i))
  printf '["%s","0x%x"]\n' "$H_IN" "$n" > "$OUT/args_$i.json"
  cat > "$OUT/bl_input_$i.json" <<EOF
{
  "tasks": [
    {
      "type": "Cairo1Executable",
      "path": "$EXE",
      "user_args_file": "$OUT/args_$i.json",
      "program_hash_function": "blake"
    }
  ],
  "fact_topologies_path": null,
  "single_page": true,
  "output_preimage_dump_path": "$OUT/preimage_$i.json"
}
EOF
  echo "== segment $i: h_in=$H_IN n=$n =="
  /usr/bin/time -l "$BIN/stwo-run-and-prove" \
    --program "$BOOTLOADER" \
    --program_input "$OUT/bl_input_$i.json" \
    --prover_params_json "$PARAMS" \
    --proof_path "$OUT/segment_$i.proof" \
    --proof-format extended-binary \
    --verify > "$OUT/segment_$i.log" 2>&1 || { tail -20 "$OUT/segment_$i.log"; exit 1; }
  grep -E "real|maximum resident" "$OUT/segment_$i.log" || true
  H_IN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[2])' "$OUT/preimage_$i.json")"
done

python3 - "$OUT" "$N" <<'PY'
import json, sys
out, n = sys.argv[1], int(sys.argv[2])
manifest = {"segments": []}
for i in range(n):
    manifest["segments"].append({
        "index": i,
        "args": json.load(open(f"{out}/args_{i}.json")),
        "output_preimage": json.load(open(f"{out}/preimage_{i}.json")),
        "proof_path": f"{out}/segment_{i}.proof",
    })
json.dump(manifest, open(f"{out}/manifest.json", "w"), indent=1)
print(f"wrote {out}/manifest.json with {n} segments")
PY

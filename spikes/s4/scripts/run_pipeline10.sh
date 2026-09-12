#!/usr/bin/env bash
# End-to-end batch pipeline on the **ten-felt** segment stub (P4.2b), the layout `DoomRuns`
# consumes:
#
#   gen_batch10.py --shape …  →  segment_stub10 × N (chained per game)  →  leaf-prover × N  →
#   stwo_run_and_prove_recursive_tree  →  stwo_circuit_verifier (output_hash)
#
# Unlike run_pipeline.sh (four felts per leaf, one chain), the leaves here carry the full D14
# output — version, h_in, h_out, tic_start, tic_end, status, inputs_commitment, kills, items,
# secrets — and are grouped into *games*, so the resulting root proof is a real batch fact that
# `DoomRuns.submit_batch` can be driven against.
#
# Usage: spikes/s4/scripts/run_pipeline10.sh <shape> [registry_name]
#   <shape>  segments per game, comma separated: "2" = one game of two segments,
#            "2,1" = two games (2 + 1) in one batch.
#
# Environment:
#   HASH_FN=blake|poseidon   the task's `program_hash_function` (D4; default blake)
#   TAG=<suffix>             extra suffix on the results/work directory names
#
# Heavy artifacts stay in $S4_WORK/batch10_<shape>/; the small ones (batch plan, preimages,
# program/packed output, verifier output, timings) land in spikes/s4/results/B<shape>_<reg>/.
set -euo pipefail
source "$(dirname "$0")/env.sh"

SHAPE="${1:?usage: run_pipeline10.sh <shape> [registry_name]}"
REG_NAME="${2:-doom}"
HASH_FN="${HASH_FN:-blake}"
TAG="${TAG:-}"
REG="$S4_DIR/registry/$REG_NAME/registry.json"
[ -f "$REG" ] || { echo "missing $REG (run gen_registry.sh $REG_NAME)" >&2; exit 1; }

SLUG="$(echo "$SHAPE" | tr ',' '-')"
WORK="$S4_WORK/batch10_${SLUG}_${REG_NAME}${TAG}"
RES="$S4_DIR/results/B${SLUG}_${REG_NAME}${TAG}"
rm -rf "$WORK" "$RES" && mkdir -p "$WORK" "$RES"
TIMES="$RES/times.txt"
: > "$TIMES"

record_time() { printf '%-22s %s\n' "$1" "$(grep -E 'real|maximum resident' "$2" | tr -s ' ' | tr '\n' ' ')" >> "$TIMES"; }

# 1. The batch plan: every leaf's arguments and the input log it will commit to.
python3 "$S4_DIR/scripts/gen_batch10.py" --shape "$SHAPE" --out "$RES/batch.json"
N="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["leaves"]))' "$RES/batch.json")"

# 2. Build the ten-felt stub.
STUB_DIR="$S4_DIR/programs/segment_stub10"
( cd "$STUB_DIR" && scarb build >/dev/null )
EXE="$STUB_DIR/target/dev/segment_stub10.executable.json"
echo "stub: segment_stub10 ($(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["program"]["bytecode"]))' "$EXE") bytecode words), shape $SHAPE, program_hash_function: $HASH_FN" | tee -a "$TIMES"

# 3. Leaves. The arguments come from the plan; the preimage the bootloader dumps is checked,
#    felt for felt, against the plan's independently computed ten felts before it is folded.
LEAVES=()
for ((i = 0; i < N; i++)); do
  python3 -c '
import json, sys
plan = json.load(open(sys.argv[1]))["leaves"][int(sys.argv[2])]
json.dump(plan["args"], open(sys.argv[3], "w"))
' "$RES/batch.json" "$i" "$WORK/args_$i.json"
  cat > "$WORK/bl_input_$i.json" <<EOF
{
  "tasks": [
    {
      "type": "Cairo1Executable",
      "path": "$EXE",
      "user_args_file": "$WORK/args_$i.json",
      "program_hash_function": "$HASH_FN"
    }
  ],
  "fact_topologies_path": null,
  "single_page": true,
  "output_preimage_dump_path": "$WORK/preimage_$i.json"
}
EOF
  echo "== leaf $i: $(python3 -c 'import json,sys; l=json.load(open(sys.argv[1]))["leaves"][int(sys.argv[2])]; print("game",l["game"],"segment",l["segment"],"args",l["args"])' "$RES/batch.json") =="
  proof_lock
  timed "$WORK/leaf_$i.time" "$BIN/leaf-prover" --program "$LEAF_BOOTLOADER" \
    --program_input "$WORK/bl_input_$i.json" --circuit_registry_json "$REG" \
    --output_path "$WORK/leaf_$i.raw.json" > "$WORK/leaf_$i.log" 2>&1 || { proof_unlock; tail -30 "$WORK/leaf_$i.log" "$WORK/leaf_$i.time"; exit 1; }
  proof_unlock
  record_time "leaf_$i" "$WORK/leaf_$i.time"
  python3 "$S4_DIR/scripts/inject_preimage.py" "$WORK/leaf_$i.raw.json" "$WORK/preimage_$i.json" "$WORK/leaf_$i.json"
  # The model check: preimage = [program_hash, out_0 … out_9] and out_* is what gen_batch10
  # predicted (in particular the ported inputs_commitment fold).
  python3 -c '
import json, sys
pre = [int(h, 16) for h in json.load(open(sys.argv[1]))]
want = [int(x) for x in json.load(open(sys.argv[2]))["leaves"][int(sys.argv[3])]["output"]]
assert len(pre) == 11, f"preimage is {len(pre)} felts, expected 11 (program_hash + 10)"
assert pre[1:] == want, f"leaf {sys.argv[3]} mismatch:\n proved {pre[1:]}\n model  {want}"
print("  preimage OK: program_hash", hex(pre[0]))
' "$WORK/preimage_$i.json" "$RES/batch.json" "$i"
  cp "$WORK/preimage_$i.json" "$RES/"
  grep -E "Program execution done|Adapter done|Verifier config|program: \(|n_outputs|preprocessed trace|Proof pow bits|Proof FRI|Cairo proving done|Circuit proving done|Circuit hash" "$WORK/leaf_$i.log" | sed 's/^.*INFO //' | head -16 > "$RES/leaf_${i}_info.log" || true
  LEAVES+=("\"$WORK/leaf_$i.json\"")
done

# 4. Fold.
printf '{"leaves": [%s]}\n' "$(IFS=,; echo "${LEAVES[*]}")" > "$WORK/leaves.json"
echo "== recursive tree over $N leaves =="
proof_lock
timed "$WORK/tree.time" "$BIN/stwo_run_and_prove_recursive_tree" --program_input "$WORK/leaves.json" \
  --proof_path "$WORK/root.proof" --program_output "$WORK/program_output.json" \
  --packed_output_path "$WORK/packed_output.json" --circuit_registry_json "$REG" > "$WORK/tree.log" 2>&1 || { proof_unlock; tail -30 "$WORK/tree.log" "$WORK/tree.time"; exit 1; }
proof_unlock
record_time "tree" "$WORK/tree.time"
grep -E "Folding|Reducing|Carrying|Single-leaf|reduction complete|Canonical multiverifier" "$WORK/tree.log" | sed 's/^.*INFO //' | grep -v "close\|enter" | head -20 > "$RES/tree_info.log" || true
grep -E "fold: close|proof_size_estimate" "$WORK/tree.log" | sed 's/^.*INFO //;s/stwo_run_and_prove_recursive_tree::run:stwo_run_and_prove_recursive_tree://' >> "$RES/tree_info.log" || true
cp "$WORK/program_output.json" "$WORK/packed_output.json" "$WORK/root.proof" "$RES/"
gzip -9f "$RES/root.proof"
python3 -c 'import json,sys; print("root.proof felts:", len(json.load(open(sys.argv[1]))))' "$WORK/root.proof" | tee -a "$TIMES"

# 5. The on-chain verifier program: resource usage and the eight-word output_hash.
echo "== stwo_circuit_verifier on root.proof =="
( cd "$PROVING/stwo_cairo_verifier" && scarb --profile proving build -p stwo_circuit_verifier --features qm31_opcode >/dev/null )
( cd "$PROVING/stwo_cairo_verifier" && timed "$WORK/verify.time" scarb --profile proving execute -p stwo_circuit_verifier \
    --features qm31_opcode --no-build --print-resource-usage --output none --arguments-file "$WORK/root.proof" ) | tee "$RES/verify.log"
record_time "verify" "$WORK/verify.time"
( cd "$PROVING/stwo_cairo_verifier" && scarb --profile proving execute -p stwo_circuit_verifier \
    --features qm31_opcode --no-build --output none --print-program-output \
    --arguments-file "$WORK/root.proof" ) > "$WORK/verifier_output.log" 2>&1
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
cp "$REG" "$RES/registry.json"
echo "== timings =="; cat "$TIMES"
echo "done: $RES"

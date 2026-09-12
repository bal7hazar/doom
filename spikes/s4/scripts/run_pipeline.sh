#!/usr/bin/env bash
# End-to-end N-leaf pipeline on our own segments (R3-A3):
#   segment_stub × N (chained: h_in[i+1] = h_out[i])  →  leaf-prover × N  →
#   stwo_run_and_prove_recursive_tree  →  stwo_circuit_verifier (scarb execute, resource usage)
#
# Usage: spikes/s4/scripts/run_pipeline.sh <N> [registry_name]   (default registry: doom)
#
# Heavy artifacts stay in $S4_WORK/pipeline_<N>/; small ones (preimages, outputs, packed tree,
# timings, verifier log) are copied to spikes/s4/results/N<N>/.
set -euo pipefail
source "$(dirname "$0")/env.sh"

N="${1:?usage: run_pipeline.sh <N> [registry_name]}"
REG_NAME="${2:-doom}"
REG="$S4_DIR/registry/$REG_NAME/registry.json"
[ -f "$REG" ] || { echo "missing $REG (run gen_registry.sh $REG_NAME)" >&2; exit 1; }

WORK="$S4_WORK/pipeline_${N}_${REG_NAME}"
RES="$S4_DIR/results/N${N}_${REG_NAME}"
rm -rf "$WORK" "$RES" && mkdir -p "$WORK" "$RES"
TIMES="$RES/times.txt"
: > "$TIMES"

record_time() { # label timefile
  printf '%-22s %s\n' "$1" "$(grep -E 'real|maximum resident' "$2" | tr -s ' ' | tr '\n' ' ')" >> "$TIMES"
}

# 1. Build the segment stub (scarb 2.18, executable target).
STUB_DIR="$S4_DIR/programs/segment_stub"
( cd "$STUB_DIR" && scarb build >/dev/null )
EXE="$STUB_DIR/target/dev/segment_stub.executable.json"

# 2. Leaves. Genesis h_in = 1; n = 250 + i (K tics); the next h_in is the previous h_out, read from
#    the dumped preimage [program_hash, h_in, h_out, n, status].
H_IN="0x1"
LEAVES=()
for ((i = 0; i < N; i++)); do
  n=$((250 + i))
  printf '["%s","0x%x"]\n' "$H_IN" "$n" > "$WORK/args_$i.json"
  cat > "$WORK/bl_input_$i.json" <<EOF
{
  "tasks": [
    {
      "type": "Cairo1Executable",
      "path": "$EXE",
      "user_args_file": "$WORK/args_$i.json",
      "program_hash_function": "blake"
    }
  ],
  "fact_topologies_path": null,
  "single_page": true,
  "output_preimage_dump_path": "$WORK/preimage_$i.json"
}
EOF
  echo "== leaf $i: h_in=$H_IN n=$n =="
  proof_lock
  timed "$WORK/leaf_$i.time" "$BIN/leaf-prover" --program "$LEAF_BOOTLOADER" \
    --program_input "$WORK/bl_input_$i.json" --circuit_registry_json "$REG" \
    --output_path "$WORK/leaf_$i.raw.json" > "$WORK/leaf_$i.log" 2>&1 || { proof_unlock; tail -30 "$WORK/leaf_$i.log"; exit 1; }
  proof_unlock
  record_time "leaf_$i" "$WORK/leaf_$i.time"
  python3 "$S4_DIR/scripts/inject_preimage.py" "$WORK/leaf_$i.raw.json" "$WORK/preimage_$i.json" "$WORK/leaf_$i.json"
  cp "$WORK/preimage_$i.json" "$RES/"
  grep -E "Verifier config|program: \(|Cairo proving done|Circuit proving done|Circuit hash|trace" "$WORK/leaf_$i.log" | sed 's/^.*INFO //' | head -12 > "$RES/leaf_${i}_info.log" || true
  H_IN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[2])' "$WORK/preimage_$i.json")"
  LEAVES+=("\"$WORK/leaf_$i.json\"")
done
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("leaf proof bytes:", len(__import__("base64").b64decode(d["proof"])))' "$WORK/leaf_0.raw.json" | tee -a "$TIMES"

# 3. Fold.
printf '{"leaves": [%s]}\n' "$(IFS=,; echo "${LEAVES[*]}")" > "$WORK/leaves.json"
echo "== recursive tree over $N leaves =="
proof_lock
timed "$WORK/tree.time" "$BIN/stwo_run_and_prove_recursive_tree" --program_input "$WORK/leaves.json" \
  --proof_path "$WORK/root.proof" --program_output "$WORK/program_output.json" \
  --packed_output_path "$WORK/packed_output.json" --circuit_registry_json "$REG" > "$WORK/tree.log" 2>&1 || { proof_unlock; tail -30 "$WORK/tree.log"; exit 1; }
proof_unlock
record_time "tree" "$WORK/tree.time"
grep -E "Folding|Reducing|Carrying|Single-leaf|reduction complete|Canonical multiverifier" "$WORK/tree.log" | sed 's/^.*INFO //' | grep -v "close\|enter" | head -20 > "$RES/tree_info.log" || true
grep -E "fold: close|proof_size_estimate" "$WORK/tree.log" | sed 's/^.*INFO //;s/stwo_run_and_prove_recursive_tree::run:stwo_run_and_prove_recursive_tree://' >> "$RES/tree_info.log" || true
cp "$WORK/program_output.json" "$WORK/packed_output.json" "$RES/"
python3 -c 'import json,sys; print("root.proof felts:", len(json.load(open(sys.argv[1]))))' "$WORK/root.proof" | tee -a "$TIMES"

# 4. On-chain verifier program.
echo "== stwo_circuit_verifier on root.proof =="
( cd "$PROVING/stwo_cairo_verifier" && scarb --profile proving build -p stwo_circuit_verifier --features qm31_opcode >/dev/null )
( cd "$PROVING/stwo_cairo_verifier" && timed "$WORK/verify.time" scarb --profile proving execute -p stwo_circuit_verifier \
    --features qm31_opcode --no-build --print-resource-usage --output none --arguments-file "$WORK/root.proof" ) | tee "$RES/verify.log"
record_time "verify" "$WORK/verify.time"
cp "$REG" "$RES/registry.json"
echo "== timings =="; cat "$TIMES"
echo "done: $RES"

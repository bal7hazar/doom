#!/usr/bin/env bash
# Prove a Scarb `#[executable]` program with the pinned monorepo prover.
#
#   ./prove.sh <executable.json> <args.json> <out_dir>
#
# Environment knobs:
#   PARAMS=<file>        prover params JSON      (default: params/canonical_small.json)
#   ROUTE=bootloader|standalone                  (default: bootloader)
#   PROOF_FORMAT=cairo-serde|json|binary         (default: cairo-serde)
#   VERIFY=1|0           verify in-process       (default: 1)
#   LOCK=auto|always|never                       (default: auto — take the shared
#                                                 .proof-lock when n_steps > 2^19)
#   KEEP_PROOF=1|0       keep the proof file     (default: 1)
#
# ROUTE=bootloader is the route the recursion pipeline uses: the executable runs as a
# `Cairo1Executable` task of the Cairo-0 *privacy simple bootloader*, which gives every
# run the fixed 11-builtin-segment shape the leaf circuit expects. ROUTE=standalone runs
# the executable's `Standalone` entrypoint directly (shorter, but see docs/spikes/S0.md —
# it is currently broken for programs whose return value is a felt >= 2^128).
#
# Writes into <out_dir>: bl_input.json, execution_resources.json,
# vm_execution_resources.json, proof.*, program_output.json, output_preimage.json,
# prove.log, prove.time, summary.json.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S0="$(dirname "$HERE")"
# shellcheck source=env.sh
source "$HERE/env.sh"

[ $# -ge 3 ] || { sed -n '2,25p' "$0"; exit 2; }
EXECUTABLE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
ARGS="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
mkdir -p "$3"; OUT="$(cd "$3" && pwd)"

PARAMS="${PARAMS:-$S0/params/canonical_small.json}"
ROUTE="${ROUTE:-bootloader}"
PROOF_FORMAT="${PROOF_FORMAT:-cairo-serde}"
VERIFY="${VERIFY:-1}"
LOCK="${LOCK:-auto}"
KEEP_PROOF="${KEEP_PROOF:-1}"

case "$PROOF_FORMAT" in
  json) PROOF="$OUT/proof.json" ;;
  *)    PROOF="$OUT/proof.cairo_serde.json" ;;
esac
verify_flag=(); [ "$VERIFY" = "1" ] && verify_flag=(--verify)

# ---------------------------------------------------------------- bootloader input
if [ "$ROUTE" = "bootloader" ]; then
  cat > "$OUT/bl_input.json" <<EOF
{
  "tasks": [
    {
      "type": "Cairo1Executable",
      "path": "$EXECUTABLE",
      "program_hash_function": "blake",
      "user_args_file": "$ARGS"
    }
  ],
  "fact_topologies_path": null,
  "single_page": true,
  "output_preimage_dump_path": "$OUT/output_preimage.json"
}
EOF
fi

# --------------------------------------------------- step 1: run the VM, get n_steps
# Cheap pass (no proving) so we know whether to take the shared proof lock, and so the
# tables carry the exact step/builtin counts of the trace that is actually proved.
if [ "$ROUTE" = "bootloader" ]; then
  "$PROVING_BIN/stwo-vm-runner" \
    --program "$BOOTLOADER" \
    --program_input "$OUT/bl_input.json" \
    --layout all_cairo_stwo \
    --output_execution_resources_path "$OUT/execution_resources.json" \
    --output_vm_execution_resources_path "$OUT/vm_execution_resources.json" \
    > "$OUT/vmrun.log" 2>&1
else
  "$PROVING_BIN/get_execution_resources" \
    --program "$EXECUTABLE" --program_type executable \
    --program_arguments_file "$ARGS" \
    --output "$OUT/execution_resources.json" > "$OUT/vmrun.log" 2>&1
fi
N_STEPS="$(grep -oE 'Num steps: [0-9]+' "$OUT/vmrun.log" | tail -1 | grep -oE '[0-9]+$' || echo 0)"
echo "n_steps = $N_STEPS  (route=$ROUTE, params=$(basename "$PARAMS"))"

# --------------------------------------------------------- step 2: the shared lock
take_lock=0
case "$LOCK" in
  always) take_lock=1 ;;
  never)  take_lock=0 ;;
  auto)   [ "$N_STEPS" -gt "$PROOF_LOCK_THRESHOLD_STEPS" ] && take_lock=1 ;;
esac
release_lock() { [ "$take_lock" = "1" ] && rmdir "$PROOF_LOCK" 2>/dev/null; return 0; }
if [ "$take_lock" = "1" ]; then
  echo "waiting for $PROOF_LOCK ..."
  until mkdir "$PROOF_LOCK" 2>/dev/null; do sleep 30; done
  trap release_lock EXIT INT TERM
  echo "lock acquired"
fi

# --------------------------------------------------------------- step 3: run + prove
if [ "$ROUTE" = "bootloader" ]; then
  /usr/bin/time -l "$PROVING_BIN/stwo-run-and-prove" \
      --program "$BOOTLOADER" \
      --program_input "$OUT/bl_input.json" \
      --prover_params_json "$PARAMS" \
      --proof_path "$PROOF" \
      --proof-format "$PROOF_FORMAT" \
      --program_output "$OUT/program_output.json" \
      "${verify_flag[@]}" \
      > "$OUT/prove.log" 2>&1
else
  /usr/bin/time -l "$PROVING_BIN/run_and_prove" \
      --program "$EXECUTABLE" \
      --program_type executable \
      --program_arguments_file "$ARGS" \
      --params_json "$PARAMS" \
      --proof_path "$PROOF" \
      --proof-format "$PROOF_FORMAT" \
      "${verify_flag[@]}" \
      > "$OUT/prove.log" 2>&1
fi
status=$?
release_lock; trap - EXIT INT TERM

# `/usr/bin/time -l` writes its block to stderr, interleaved with the prover's tracing
# logs; split the trailing block out so results/*.time files stay readable.
awk '/[0-9.]+ real/{found=1} found' "$OUT/prove.log" > "$OUT/prove.time"

python3 "$HERE/summarise.py" "$OUT" "$EXECUTABLE" "$ARGS" "$PARAMS" "$ROUTE" "$N_STEPS" "$status"
[ "$KEEP_PROOF" = "1" ] || rm -f "$PROOF"
exit "$status"

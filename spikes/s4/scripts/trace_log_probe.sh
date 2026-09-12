#!/usr/bin/env bash
# S4b measurement 3: what does the leaf circuit's `trace_log_size` actually depend on?
#
#   spikes/s4/scripts/trace_log_probe.sh [n_iters...]      (default: 23000 46000 64000 78000 92000)
#
# `leaf-prover` derives the verified proof's `trace_log_size` from the Cairo AIR's *largest
# component*, not from the step count (prover.rs:134). Running it against the `doom_21` registry
# (which only lists a leaf verifier for trace_log_size 21) turns the prover into an oracle: the
# registry lookup panics with the size it computed. Each point costs one Cairo proof (seconds,
# a few GB) and no circuit proof.
#
# Results -> spikes/s4/results/trace_log_probe.tsv
set -uo pipefail
source "$(dirname "$0")/env.sh"

NS=("$@"); [ ${#NS[@]} -gt 0 ] || NS=(23000 46000 64000 78000 92000)
STUB_DIR="$S4_DIR/programs/segment_stub_big"
SRC="$STUB_DIR/src/lib.cairo"
REG="$S4_DIR/registry/doom_21/registry.json"
[ -f "$REG" ] || { echo "missing $REG (run gen_registry.sh doom_21)" >&2; exit 1; }
WORK="$S4_WORK/trace_log_probe"
mkdir -p "$WORK"
TSV="$S4_DIR/results/trace_log_probe.tsv"
ORIG="$(grep -oE 'const N_ITERS: u32 = [0-9]+;' "$SRC")"
set_iters() { python3 - "$SRC" "$1" <<'PY'
import re, sys
p, n = sys.argv[1], sys.argv[2]
s = open(p).read()
open(p, "w").write(re.sub(r"const N_ITERS: u32 = \d+;", f"const N_ITERS: u32 = {n};", s))
PY
}
# `proof_lock` installs its own EXIT trap (and `proof_unlock` clears it), so the source is restored
# explicitly at the end and by an INT/TERM trap, not by an EXIT trap that would be overwritten.
restore() { set_iters "$(echo "$ORIG" | grep -oE '[0-9]+')"; }
trap 'restore; exit 130' INT TERM

printf 'n_iters\tsteps\ttrace_log_size\toutcome\n' > "$TSV"
printf '["0x1","0xfa"]\n' > "$WORK/args.json"

for n in "${NS[@]}"; do
  set_iters "$n"
  ( cd "$STUB_DIR" && scarb build >/dev/null 2>&1 ) || { echo "build failed n=$n" >&2; continue; }
  steps="$( ( cd "$STUB_DIR" && scarb execute --no-build --print-resource-usage --output none \
      --arguments-file "$WORK/args.json" 2>&1 ) | grep -oE 'steps: [0-9,]+' | head -1 | tr -d 'steps:, ' )"
  EXE="$STUB_DIR/target/dev/segment_stub_big.executable.json"
  cat > "$WORK/bl_$n.json" <<EOF
{
  "tasks": [ { "type": "Cairo1Executable", "path": "$EXE",
               "program_hash_function": "blake", "user_args_file": "$WORK/args.json" } ],
  "fact_topologies_path": null, "single_page": true,
  "output_preimage_dump_path": "$WORK/preimage_$n.json"
}
EOF
  proof_lock
  "$BIN/leaf-prover" --program "$LEAF_BOOTLOADER" --program_input "$WORK/bl_$n.json" \
    --circuit_registry_json "$REG" --output_path "$WORK/leaf_$n.json" > "$WORK/leaf_$n.log" 2>&1
  proof_unlock
  err="$(grep -A1 panicked "$WORK/leaf_$n.log" | tail -1)"
  case "$err" in
    *"trace log size"*) log="$(echo "$err" | grep -oE 'trace log size [0-9]+' | grep -oE '[0-9]+')"
                        outcome="rejected by doom_21 (leaf circuit for log $log lives in \`doom\`)" ;;
    *seq_21*)           log=21; outcome="canonical_small has no seq_21 column: $err" ;;
    "")                 log=21; outcome="proved with the doom_21 leaf circuit" ;;
    *)                  log="?"; outcome="$err" ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$n" "$steps" "$log" "$outcome" >> "$TSV"
  printf '%-8s steps=%-10s trace_log_size=%-3s %s\n' "$n" "$steps" "$log" "$outcome"
done

restore
( cd "$STUB_DIR" && scarb build >/dev/null 2>&1 ) || true
column -t -s $'\t' "$TSV"

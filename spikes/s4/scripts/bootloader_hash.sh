#!/usr/bin/env bash
# S4b measurement 2 (D4, R2-A12): cost of the *leaf* simple bootloader as a function of the task
# program's bytecode length, with `program_hash_function` = blake vs poseidon.
#
#   spikes/s4/scripts/bootloader_hash.sh [n_statements...]     (default: 225 1960 3950 7920
#                                                               -> ~1 k / 8 k / 16 k / 32 k words)
#
# For each size: generate + build `programs/bigcode`, run it standalone (scarb execute) and as a
# task of the leaf bootloader (stwo-vm-runner, no proof), and report the difference. This is the
# S0 measurement (`spikes/s0/scripts/bootloader_overhead.sh`) redone on the bootloader the
# recursion route actually runs, so the fitted models apply to our segments.
#
# Results -> spikes/s4/results/bootloader_hash.tsv (+ a fitted model printed at the end).
set -uo pipefail
source "$(dirname "$0")/env.sh"

NS=("$@"); [ ${#NS[@]} -gt 0 ] || NS=(225 1960 3950 7920)
PKG="$S4_DIR/programs/bigcode"
WORK="$S4_WORK/bootloader_hash"
mkdir -p "$WORK"
TSV="$S4_DIR/results/bootloader_hash.tsv"
# The VM runner of the same monorepo commit; S0 built it in its own clone, reuse it if present.
VM_RUNNER="${VM_RUNNER:-$BIN/stwo-vm-runner}"
[ -x "$VM_RUNNER" ] || VM_RUNNER="$SCRATCH/proving-s0/target/release/stwo-vm-runner"
[ -x "$VM_RUNNER" ] || { echo "no stwo-vm-runner (build -p stwo-vm-runner in $PROVING)" >&2; exit 1; }

printf 'n_statements\tbytecode_words\thash_fn\tsteps_standalone\tsteps_with_bootloader\toverhead\tposeidon_instances\trange_check_instances\tbitwise_instances\n' > "$TSV"
printf '["0x7"]\n' > "$WORK/args.json"

for n in "${NS[@]}"; do
  python3 "$PKG/generate.py" "$n" >/dev/null
  ( cd "$PKG" && scarb build >/dev/null 2>&1 ) || { echo "scarb build failed for n=$n" >&2; continue; }
  EXE="$PKG/target/dev/bigcode.executable.json"
  cp "$EXE" "$WORK/bigcode_$n.executable.json"
  EXE="$WORK/bigcode_$n.executable.json"
  words="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["program"]["bytecode"]))' "$EXE")"
  standalone="$( ( cd "$PKG" && scarb execute --no-build --print-resource-usage --output none \
      --arguments-file "$WORK/args.json" 2>&1 ) | grep -oE 'steps: [0-9,]+' | head -1 | tr -d 'steps:, ' )"
  for h in blake poseidon; do
    cat > "$WORK/bl_${n}_$h.json" <<EOF
{
  "tasks": [ { "type": "Cairo1Executable", "path": "$EXE",
               "program_hash_function": "$h", "user_args_file": "$WORK/args.json" } ],
  "fact_topologies_path": null, "single_page": true,
  "output_preimage_dump_path": "$WORK/preimage_${n}_$h.json"
}
EOF
    "$VM_RUNNER" --program "$LEAF_BOOTLOADER" --program_input "$WORK/bl_${n}_$h.json" \
      --layout all_cairo_stwo \
      --output_execution_resources_path "$WORK/er_${n}_$h.json" \
      --output_vm_execution_resources_path "$WORK/vm_${n}_$h.json" \
      > "$WORK/run_${n}_$h.log" 2>&1 || { echo "n=$n/$h FAILED (see $WORK/run_${n}_$h.log)"; tail -3 "$WORK/run_${n}_$h.log"; continue; }
    python3 - "$n" "$words" "$h" "$standalone" "$WORK/vm_${n}_$h.json" >> "$TSV" <<'PY'
import json, sys
n, words, h, standalone, vm = sys.argv[1:6]
d = json.load(open(vm))
b = d["builtin_instance_counter"]
print("\t".join([n, words, h, standalone, str(d["n_steps"]), str(d["n_steps"] - int(standalone)),
                 str(b.get("poseidon_builtin", 0)), str(b.get("range_check_builtin", 0)),
                 str(b.get("bitwise_builtin", 0))]))
PY
  done
done

column -t -s $'\t' "$TSV"
# Least-squares fit of `overhead = a + b * bytecode_words`, per hash function (the S0 models were
# fitted on two extreme points; with four sizes we can report the residuals too).
python3 - "$TSV" <<'PY'
import sys
rows = [l.split("\t") for l in open(sys.argv[1]).read().splitlines()[1:]]
for h in ("blake", "poseidon"):
    pts = [(int(r[1]), int(r[5])) for r in rows if r[2] == h]
    if len(pts) < 2:
        continue
    n = len(pts)
    sx = sum(x for x, _ in pts); sy = sum(y for _, y in pts)
    sxx = sum(x * x for x, _ in pts); sxy = sum(x * y for x, y in pts)
    b = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    a = (sy - b * sx) / n
    res = [(x, y, a + b * x, 100 * (a + b * x - y) / y) for x, y in pts]
    print(f"{h:9s} overhead ~= {a:8.0f} + {b:6.3f} x words")
    for x, y, p, e in res:
        print(f"            words={x:6d} measured={y:8d} model={p:9.0f} ({e:+.1f} %)")
PY

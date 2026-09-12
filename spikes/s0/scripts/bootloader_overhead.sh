#!/usr/bin/env bash
# Measure the privacy-simple-bootloader step overhead as a function of the task
# program's bytecode length and of `program_hash_function`.
#
#   ./bootloader_overhead.sh
#
# For each program: run it standalone (scarb execute) and under the bootloader
# (stwo-vm-runner), and report the difference. Results -> results/bootloader-overhead.tsv
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S0="$(dirname "$HERE")"
# shellcheck source=env.sh
source "$HERE/env.sh"

WORK="${RUNS:-${SCRATCH:-/tmp}/s0-runs}/bl-overhead"
OUT="$S0/results"
mkdir -p "$WORK" "$OUT"
TSV="$OUT/bootloader-overhead.tsv"
printf 'program\tbytecode_words\thash_fn\tsteps_standalone\tsteps_with_bootloader\toverhead\tposeidon_instances\trange_check_instances\n' > "$TSV"

for pkg in "${PROGRAMS[@]}"; do
  exe="$S0/programs/$pkg/target/dev/$pkg.executable.json"
  [ -f "$exe" ] || continue
  case "$pkg" in
    poseidon_hash) argf="$S0/args/n1000.json" ;;
    steps_k)       argf="$S0/args/k16.json" ;;
    *)             argf="$S0/args/n1.json" ;;
  esac
  words="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["program"]["bytecode"]))' "$exe")"
  standalone="$( ( cd "$S0/programs/$pkg" && ASDF_SCARB_VERSION="$SCARB_VERSION" \
      scarb execute --no-build --print-resource-usage --arguments-file "$argf" 2>&1 ) \
      | grep -oE 'steps: [0-9,]+' | head -1 | tr -d 'steps:, ' )"
  for h in blake poseidon; do
    cat > "$WORK/${pkg}_$h.json" <<EOF
{
  "tasks": [ { "type": "Cairo1Executable", "path": "$exe",
               "program_hash_function": "$h", "user_args_file": "$argf" } ],
  "fact_topologies_path": null, "single_page": true,
  "output_preimage_dump_path": "$WORK/${pkg}_${h}_preimage.json"
}
EOF
    "$PROVING_BIN/stwo-vm-runner" --program "$BOOTLOADER" \
      --program_input "$WORK/${pkg}_$h.json" --layout all_cairo_stwo \
      --output_execution_resources_path "$WORK/${pkg}_${h}_er.json" \
      --output_vm_execution_resources_path "$WORK/${pkg}_${h}_vm.json" \
      > "$WORK/${pkg}_$h.log" 2>&1 || { echo "$pkg/$h FAILED"; continue; }
    python3 - "$pkg" "$words" "$h" "$standalone" "$WORK/${pkg}_${h}_vm.json" >> "$TSV" <<'PY'
import json, sys
pkg, words, h, standalone, vm = sys.argv[1:6]
d = json.load(open(vm))
b = d["builtin_instance_counter"]
print("\t".join([pkg, words, h, standalone, str(d["n_steps"]),
                 str(d["n_steps"] - int(standalone)),
                 str(b.get("poseidon_builtin", 0)), str(b.get("range_check_builtin", 0))]))
PY
  done
done

column -t -s $'\t' "$TSV"

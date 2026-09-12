#!/usr/bin/env bash
# Run the S0 measurement matrix and collect the small artefacts into results/.
#
#   ./measure.sh [suite ...]
#
# Suites: programs | standalone | steps | canonical | recursion | pow0 | feltwidth | levers | all
#         (default: all)
#
# Proofs are written under $RUNS (scratch, default /tmp/s0-runs) and are NOT copied
# into results/ — only prove.time, summary.json and the execution-resource JSONs are,
# because a single canonical_small proof is several MB.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S0="$(dirname "$HERE")"
# shellcheck source=env.sh
source "$HERE/env.sh"

RUNS="${RUNS:-${SCRATCH:-/tmp}/s0-runs}"
RESULTS="$S0/results"
mkdir -p "$RUNS" "$RESULTS"

exe() { echo "$S0/programs/$1/target/dev/$1.executable.json"; }

# run <tag> <pkg> <args-file> [VAR=VAL ...]
run() {
  local tag="$1" pkg="$2" argf="$3"; shift 3
  echo "################ $tag"
  if [ -f "$RESULTS/$tag/summary.json" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "  (already done, skipping — set FORCE=1 to redo)"; return 0
  fi
  env "$@" bash "$HERE/prove.sh" "$(exe "$pkg")" "$S0/args/$argf" "$RUNS/$tag" \
    2>&1 | tee "$RUNS/$tag.console"
  mkdir -p "$RESULTS/$tag"
  for f in prove.time summary.json execution_resources.json \
           vm_execution_resources.json program_output.json output_preimage.json; do
    [ -f "$RUNS/$tag/$f" ] && cp "$RUNS/$tag/$f" "$RESULTS/$tag/$f"
  done
  # keep the tail of the prover log (panics, per-stage spans) but not the whole thing
  [ -f "$RUNS/$tag/prove.log" ] && tail -c 200000 "$RUNS/$tag/prove.log" > "$RESULTS/$tag/prove.log.tail"
}

CS="$S0/params/canonical_small.json"
CSM="$S0/params/canonical_small_m31.json"
CAN="$S0/params/canonical.json"
REC="$S0/params/recursion_tree_reference.json"
POW0="$S0/params/canonical_small_pow0.json"

suite_programs() {
  for p in felt_loop u32_loop bitwise_loop poseidon_hash; do
    run "${p}_n1000_cs_bl" "$p" n1000.json PARAMS="$CS" ROUTE=bootloader KEEP_PROOF=0
  done
}

suite_standalone() {
  for p in felt_loop u32_loop bitwise_loop poseidon_hash; do
    run "${p}_n1000_cs_sa" "$p" n1000.json PARAMS="$CS" ROUTE=standalone KEEP_PROOF=0
  done
  # minimal R4-A1 reproducers on the standalone route
  run "felt_loop_n0_cs_sa" felt_loop n0.json PARAMS="$CS" ROUTE=standalone KEEP_PROOF=0
  run "felt_loop_n1_cs_sa" felt_loop n1.json PARAMS="$CS" ROUTE=standalone KEEP_PROOF=0
}

suite_steps() {
  for k in 16 18 19 20 21; do
    run "steps_k${k}_cs_bl" steps_k "k$k.json" PARAMS="$CS" ROUTE=bootloader KEEP_PROOF=0
  done
  # blake2s_m31 channel (the one the recursion route needs)
  for k in 16 19; do
    run "steps_k${k}_csm31_bl" steps_k "k$k.json" PARAMS="$CSM" ROUTE=bootloader KEEP_PROOF=0
  done
}

suite_canonical() {
  for k in 16 18; do
    # `canonical` costs ~17 GB of preprocessed trace whatever the step count, so it
    # always takes the shared lock, not just above the step threshold.
    run "steps_k${k}_can_bl" steps_k "k$k.json" \
        PARAMS="$CAN" ROUTE=bootloader KEEP_PROOF=0 LOCK=always
  done
}

# Same scaling run with pow_bits = 0. The PoW grind is a geometric random variable
# seeded by the trace, so at pow 26 it adds 1-3 s of *reproducible but arbitrary*
# CPU per trace and swamps the step-count signal. pow 0 gives the clean curve.
# (Measurement only: pow 0 drops the conjectured security from 96 to 70 bits.)
suite_pow0() {
  for k in 16 18 19 20 21; do
    run "steps_k${k}_pow0_bl" steps_k "k$k.json" PARAMS="$POW0" ROUTE=bootloader KEEP_PROOF=0
  done
}

# The params the recursion registry actually pins (pow 16, include_all = true,
# lifting = at_least_preprocessed) — a hand-off measurement for S4.
suite_recursion() {
  for k in 19 20; do
    run "steps_k${k}_rec_bl" steps_k "k$k.json" PARAMS="$REC" ROUTE=bootloader KEEP_PROOF=0
  done
}

# Controlled A/B on memory-value width: identical opcode stream, values below vs
# above the adapter's 2^72 "small" threshold.
suite_feltwidth() {
  for a in narrow wide; do
    run "felt_width_${a}_cs_bl" felt_width "n1000_$a.json" \
        PARAMS="$CS" ROUTE=bootloader KEEP_PROOF=0
  done
}

# R1-A5: which knob actually moves RSS at k = 19?
suite_levers() {
  local d="$S0/params/levers"
  for f in "$d"/*.json; do
    [ -e "$f" ] || continue
    run "steps_k19_$(basename "$f" .json)" steps_k k19.json \
        PARAMS="$f" ROUTE=bootloader KEEP_PROOF=0
  done
}

suites=("${@:-all}")
for s in "${suites[@]}"; do
  case "$s" in
    all)        suite_programs; suite_standalone; suite_steps; suite_canonical
                suite_recursion; suite_pow0; suite_feltwidth; suite_levers ;;
    programs)   suite_programs ;;
    standalone) suite_standalone ;;
    steps)      suite_steps ;;
    canonical)  suite_canonical ;;
    recursion)  suite_recursion ;;
    pow0)       suite_pow0 ;;
    feltwidth)  suite_feltwidth ;;
    levers)     suite_levers ;;
    *) echo "unknown suite: $s" >&2; exit 2 ;;
  esac
done

python3 "$HERE/tables.py" "$RESULTS"

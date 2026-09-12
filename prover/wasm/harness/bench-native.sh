#!/usr/bin/env bash
# Native reference: same code path (hellproof-prover-native), all cores and single thread.
#   bench-native.sh [--k "14 16 18 19 20"] [--runs 3] [--threads "0 1"] [--params file.json]
# Honours the shared proof lock for k >= 20 (ROADMAP §4: one proof > 2^19 at a time per machine).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KS="14 16 18 19"; RUNS=3; THREADS="0 1"; PARAMS=""
while [[ $# -gt 0 ]]; do case "$1" in
  --k) KS="$2"; shift 2;; --runs) RUNS="$2"; shift 2;; --threads) THREADS="$2"; shift 2;;
  --params) PARAMS="$2"; shift 2;; *) echo "unknown arg $1" >&2; exit 2;; esac; done

BIN="${NATIVE_BIN:-$HERE/../target/release/hellproof-prover-native}"
[[ -x "$BIN" ]] || { echo "missing $BIN (cargo build --release --bin hellproof-prover-native)" >&2; exit 2; }
EXE="$HERE/programs/steps_k/target/dev/main.executable.json"
OUT="$HERE/results"; mkdir -p "$OUT"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%S)"
JSONL="$OUT/native-$STAMP.jsonl"
LOCK="${PROOF_LOCK_DIR:-${SCRATCH:-/tmp}/.proof-lock}"

for k in $KS; do
  for t in $THREADS; do
    for run in $(seq 1 "$RUNS"); do
      lock=0
      if (( k >= 20 )); then until mkdir "$LOCK" 2>/dev/null; do sleep 30; done; lock=1; trap 'rmdir "$LOCK" 2>/dev/null' EXIT; fi
      echo "== native k=$k threads=$t run=$run" >&2
      # shellcheck disable=SC2086
      "$BIN" --executable "$EXE" --args "$HERE/programs/steps_k/args/k$k.json" --threads "$t" \
        --label "k${k}-t${t}-r${run}" ${PARAMS:+--params "$PARAMS"} 2>"$OUT/native-$STAMP-k$k-t$t-r$run.log" | tee -a "$JSONL"
      if (( lock )); then rmdir "$LOCK" 2>/dev/null || true; trap - EXIT; fi
    done
  done
done
echo "results: $JSONL" >&2

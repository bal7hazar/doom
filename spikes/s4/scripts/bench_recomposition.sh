#!/usr/bin/env bash
# Step cost of the on-chain recomposition (recursion_outputs::bench) for several N.
# Usage: spikes/s4/scripts/bench_recomposition.sh [N...]   (default: 1 4 8 50)
set -euo pipefail
source "$(dirname "$0")/env.sh"
NS=("$@"); [ ${#NS[@]} -gt 0 ] || NS=(1 4 8 50)
OUT="$S4_DIR/results/recomposition_bench.txt"
: > "$OUT"
cd "$S4_DIR/recursion_outputs"
for n in "${NS[@]}"; do
  echo "== bench N=$n ==" | tee -a "$OUT"
  scarb execute --executable-name bench --arguments "$n" --output none --print-resource-usage 2>&1 \
    | grep -E "steps|range_check_builtin|bitwise|memory holes" | tee -a "$OUT"
done

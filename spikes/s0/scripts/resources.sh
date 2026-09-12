#!/usr/bin/env bash
# Collect `scarb execute --print-resource-usage` for every S0 program / argument pair.
# Raw outputs land in results/resource-usage/<pkg>_<args>.txt.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S0="$(dirname "$HERE")"
# shellcheck source=env.sh
source "$HERE/env.sh"

OUT="$S0/results/resource-usage"
mkdir -p "$OUT"

run() { # run <pkg> <args-file>
  local pkg="$1" argf="$2" tag
  tag="$(basename "$argf" .json)"
  echo "==> $pkg $tag"
  ( cd "$S0/programs/$pkg" \
    && ASDF_SCARB_VERSION="$SCARB_VERSION" scarb execute --no-build \
         --print-resource-usage --print-program-output \
         --arguments-file "$S0/args/$argf" ) > "$OUT/${pkg}_${tag}.txt" 2>&1 \
    || echo "  (failed, see $OUT/${pkg}_${tag}.txt)"
  grep -E 'steps|builtin|holes' "$OUT/${pkg}_${tag}.txt" | sed 's/^/    /' || true
}

run felt_loop    n1000.json
run felt_loop    n3.json
run u32_loop     n1000.json
run bitwise_loop n1000.json
run poseidon_hash n1000.json
for k in 16 17 18 19 20 21; do run steps_k "k$k.json"; done

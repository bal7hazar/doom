#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Regenerates vendor/patches/0002-*.patch and 0003-*.patch from git: the diff of the vendored
# crates between <base> (the tree before the P4.1 series: upstream cd7bc5f + the visibility
# patch) and the working tree, split by file group, with `a/crates/...` paths so that
# `patch -p1` applies from `vendor/stwo_cairo_verifier/`. The justification headers are kept
# from the existing patch files (everything before the first `diff --git` line).
# Usage: tools/vendor_patches.sh <base-commit>
set -euo pipefail
cd "$(dirname "$0")/.."
BASE=${1:?base commit}
VENDOR=cairo/doom_contracts/vendor/stwo_cairo_verifier
OUT=vendor/patches
gen() {
  local name=$1; shift
  local out="$OUT/$name"
  local header=""
  if [ -f "$out" ]; then
    header=$(awk '/^diff --git/{exit} {print}' "$out")
  fi
  {
    if [ -n "$header" ]; then printf '%s\n' "$header"; fi
    git -C ../.. diff "$BASE" -- "$@" | sed -e "s|a/$VENDOR/|a/|" -e "s|b/$VENDOR/|b/|"
  } > "$out"
  echo "wrote $out"
}
gen 0002-fri-lazy-folds.patch \
  "$VENDOR/crates/verifier_core/src/fri.cairo" \
  "$VENDOR/crates/verifier_core/src/fri/lazy.cairo" \
  "$VENDOR/crates/verifier_core/src/utils.cairo"
gen 0003-fri-answers-lazy.patch \
  "$VENDOR/crates/verifier_core/src/pcs/quotients.cairo"

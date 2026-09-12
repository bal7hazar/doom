#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Hellproof contributors
# SPDX-License-Identifier: Apache-2.0
#
# Applies `prover/wrapper/patches/proving-*.patch` to a `starkware-libs/proving` clone pinned at
# cd7bc5f (R3-A1). See ../patches/README.md for what each one does and why.
#
# Idempotent: a patch already in the tree is skipped, so re-running after a partial build is safe.
#
# Usage: apply_patches.sh [proving_clone]
#   proving_clone   default: $PROVING, then $SCRATCH/proving
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES="$HERE/../patches"
SCRATCH="${SCRATCH:-/tmp}"
TARGET="${1:-${PROVING:-$SCRATCH/proving}}"

[ -d "$TARGET/.git" ] || { echo "$TARGET is not a git clone of starkware-libs/proving" >&2; exit 1; }
[ -d "$TARGET/crates/leaf_prover" ] || { echo "$TARGET does not look like the proving monorepo" >&2; exit 1; }

shopt -s nullglob
patches=("$PATCHES"/proving-*.patch)
if [ ${#patches[@]} -eq 0 ]; then
  echo "no patches in $PATCHES"
  exit 0
fi

for p in "${patches[@]}"; do
  name="$(basename "$p")"
  if git -C "$TARGET" apply --reverse --check "$p" > /dev/null 2>&1; then
    echo "skip    $name (already applied)"
    continue
  fi
  if ! git -C "$TARGET" apply --check "$p" > /dev/null 2>&1; then
    echo "ERROR   $name does not apply to $TARGET" >&2
    git -C "$TARGET" apply --check "$p" >&2 || true
    exit 1
  fi
  git -C "$TARGET" apply "$p"
  echo "applied $name"
done

echo "patched $TARGET ($(git -C "$TARGET" rev-parse --short HEAD) + ${#patches[@]} patch(es))"

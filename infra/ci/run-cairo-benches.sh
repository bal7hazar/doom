#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs every cairo/crates/*/bench/measure.py cairo/doom/*/bench/measure.py, so the per-crate step-cost
# budgets (PLAN.md §3.1 rule 4) are enforced on every merge, not just when a
# developer happens to run them locally. Each script already builds its own
# standalone bench package and fails (exit 1) if any operation is more than
# 10% over its documented budget (cairo/crates/<name>/bench/budgets.json) --
# this wrapper just runs all of them and reports which crate(s) failed.
#
# Requires: scarb (the version cairo/.tool-versions pins) and python3 on PATH.
# Usage: infra/ci/run-cairo-benches.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
status=0
found=0

for bench in "$REPO_ROOT"/cairo/crates/*/bench/measure.py cairo/doom/*/bench/measure.py; do
  [ -f "$bench" ] || continue
  found=1
  crate="$(basename "$(dirname "$(dirname "$bench")")")"
  echo "::group::bench: $crate"
  if ! python3 "$bench"; then
    echo "FAILED: $crate is over its step-cost budget (see budgets.json)"
    status=1
  fi
  echo "::endgroup::"
done

if [ "$found" -eq 0 ]; then
  echo "no cairo/crates/*/bench/measure.py cairo/doom/*/bench/measure.py found -- nothing to run"
fi

exit $status

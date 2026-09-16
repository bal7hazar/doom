#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs the cairo/ workspace's tests in memory-bounded batches, one
# `scarb test` process per batch, and checks that no test was left out.
#
# Why not a single `scarb test`: cairo-test keeps the VM memory of every
# test it ran in the same process, so the 73 tests of `doom_game` -- whose
# E1M1 replays are ~8 GB each (700 tics of the real level) -- add up to far
# more than a 16 GB CI runner and get it killed ("runner has received a
# shutdown signal"). Every other package is small and runs whole.
#
# Batches:
#   * every workspace member except doom_game: `scarb test -p <name>`;
#   * doom_game's test modules that are not E1M1 replays (src/<mod>.cairo
#     with an inline `#[cfg(test)] mod tests`, and src/tests/<mod>.cairo):
#     `scarb test -p doom_game -f <module path>`;
#   * every `#[test]` of doom_game/src/tests/e1m1.cairo on its own.
# The lists are derived from the manifest and the sources at run time, so a
# new package, module or E1M1 test is picked up without editing this file,
# and the total of the "running N tests" lines is compared with the number
# of `#[test]` attributes in doom_game: a test nobody ran, or one that two
# filters both matched, fails the run.
#
# Requires: scarb (the version cairo/.tool-versions pins) on PATH.
# Usage: infra/ci/run-cairo-tests.sh                      (from anywhere)
#   RAYON_NUM_THREADS   test threads per process (default 2: two E1M1 tests
#                       side by side would not fit either).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAIRO="$REPO_ROOT/cairo"
HEAVY=doom_game
HEAVY_DIR="$CAIRO/doom/$HEAVY"
E1M1="$HEAVY_DIR/src/tests/e1m1.cairo"
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-2}"

LOG="$(mktemp -d)"
trap 'rm -rf "$LOG"' EXIT

status=0
total_ran=0
total_passed=0
heavy_ran=0
summary=()

# Peak resident memory (VmHWM) of the scarb-cairo-test process behind a
# batch, sampled from /proc while it runs; "-" where /proc is not there.
peak_mib=-
run_batch() {
  local label="$1"; shift
  local out="$LOG/$(echo "$label" | tr -c 'A-Za-z0-9_.-' '_').log"
  echo "::group::$label"
  echo "\$ (cd cairo && RAYON_NUM_THREADS=$RAYON_NUM_THREADS $*)"
  local rc=0 peak=0 v st
  (cd "$CAIRO" && "$@") > "$out" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ -d /proc ]; then
      # /proc/<pid>/comm is the name cut to 15 bytes: "scarb-cairo-tes".
      for st in /proc/[0-9]*/status; do
        if [ "$(awk '/^Name:/{print $2; exit}' "$st" 2>/dev/null)" = "scarb-cairo-tes" ]; then
          v="$(awk '/^VmHWM:/{print $2; exit}' "$st" 2>/dev/null || true)"
          if [ -n "$v" ] && [ "$v" -gt "$peak" ]; then peak=$v; fi
        fi
      done
    fi
    sleep 1
  done
  wait "$pid" || rc=$?
  cat "$out"
  echo "::endgroup::"
  local ran passed
  ran="$(grep -oE '^running [0-9]+ tests?' "$out" | awk '{s+=$2} END{print s+0}')"
  passed="$(grep -oE '^test result: .*[0-9]+ passed' "$out" | grep -oE '[0-9]+ passed' | awk '{s+=$1} END{print s+0}')"
  if [ -d /proc ]; then peak_mib=$((peak / 1024)); fi
  total_ran=$((total_ran + ran))
  total_passed=$((total_passed + passed))
  local verdict=ok
  if [ "$rc" -ne 0 ]; then verdict="FAILED (exit $rc)"; status=1; fi
  summary+=("$(printf '%-72s %4s ran %4s passed  peak %6s MiB  %s' "$label" "$ran" "$passed" "$peak_mib" "$verdict")")
  echo "$label: $ran ran, $passed passed, peak $peak_mib MiB, $verdict"
  echo
  LAST_RAN=$ran
}

# 1. Every workspace member except the heavy one, whole.
members="$(sed -n '/^members = \[/,/^\]/p' "$CAIRO/Scarb.toml" | grep -oE '"[^"]+"' | tr -d '"')"
for member in $members; do
  name="$(sed -n 's/^name = "\([^"]*\)".*/\1/p' "$CAIRO/$member/Scarb.toml" | head -n1)"
  [ -n "$name" ] || { echo "cannot read the package name of cairo/$member"; exit 1; }
  [ "$name" != "$HEAVY" ] || continue
  run_batch "$name" scarb test -p "$name"
done

# 2. The heavy package by module: inline test modules of src/<mod>.cairo
#    (`crate::<mod>::tests::`), then src/tests/<mod>.cairo (`tests::<mod>::`)
#    except the E1M1 replays.
for file in "$HEAVY_DIR"/src/*.cairo; do
  mod="$(basename "$file" .cairo)"
  case "$mod" in lib|tests) continue ;; esac
  grep -qE '^\s*#\[test\]' "$file" || continue
  run_batch "$HEAVY -f $HEAVY::$mod::tests::" scarb test -p "$HEAVY" -f "$HEAVY::$mod::tests::"
  heavy_ran=$((heavy_ran + LAST_RAN))
done
for file in "$HEAVY_DIR"/src/tests/*.cairo; do
  mod="$(basename "$file" .cairo)"
  [ "$file" != "$E1M1" ] || continue
  run_batch "$HEAVY -f tests::$mod::" scarb test -p "$HEAVY" -f "$HEAVY::tests::$mod::"
  heavy_ran=$((heavy_ran + LAST_RAN))
done

# 3. Every E1M1 test alone: the name is the `fn` that follows each `#[test]`.
e1m1_tests="$(awk '/^\s*#\[test\]/{want=1; next} want && /^\s*(pub )?fn /{sub(/^\s*(pub )?fn /, ""); sub(/\(.*/, ""); print; want=0}' "$E1M1")"
for test in $e1m1_tests; do
  run_batch "$HEAVY -f tests::e1m1::$test" scarb test -p "$HEAVY" -f "$HEAVY::tests::e1m1::$test"
  heavy_ran=$((heavy_ran + LAST_RAN))
done

# 4. Nothing forgotten, nothing run twice: the batches of the heavy package
#    ran exactly as many tests as it declares.
expected="$(grep -rhE '^\s*#\[test\]' "$HEAVY_DIR/src" | wc -l)"

echo "==================== cairo tests: summary ===================="
printf '%s\n' "${summary[@]}"
echo "--------------------------------------------------------------"
echo "total: $total_ran ran, $total_passed passed ($HEAVY: $heavy_ran ran, $expected declared)"
if [ "$heavy_ran" -ne "$expected" ]; then
  echo "FAILED: $HEAVY declares $expected #[test]s but the batches ran $heavy_ran -- a test was skipped or matched twice"
  status=1
fi
if [ "$total_ran" -ne "$total_passed" ]; then
  echo "FAILED: $((total_ran - total_passed)) of $total_ran tests did not pass"
  status=1
fi
if [ "$status" -eq 0 ]; then echo "all $total_ran tests passed"; fi
exit $status

#!/usr/bin/env bash
# Shared environment for the S4 spike scripts.
#
# Everything heavy (the `proving` monorepo clone, its build, proofs) lives in the scratchpad;
# only small artifacts are copied back under spikes/s4/results/.
#
# Override any of these from the environment.

S4_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export S4_DIR

# Scratchpad (session-specific). Set SCRATCH explicitly when running outside the agent session.
export SCRATCH="${SCRATCH:-/private/tmp/claude-501/-Users-bal7hazar-git-doom/052c133d-8e48-4871-8024-3d2fd1081b4c/scratchpad}"

# The monorepo pin (R3-A1). https://github.com/starkware-libs/proving
export PROVING_COMMIT="${PROVING_COMMIT:-cd7bc5f}"
export PROVING="${PROVING:-$SCRATCH/proving-s4}"
export PROVING_TARGET="${PROVING_TARGET:-$PROVING/target}"
export BIN="$PROVING_TARGET/release"

# Scarb: the monorepo's verifier workspace wants 2.18.0 (see stwo_cairo_verifier/.tool-versions).
export ASDF_SCARB_VERSION="${ASDF_SCARB_VERSION:-2.18.0}"

# Where proofs and large intermediates go (never committed).
export S4_WORK="${S4_WORK:-$SCRATCH/s4-work}"
mkdir -p "$S4_WORK"

# The bootloader program every leaf runs (see docs/spikes/S4.md, "Data flow").
export LEAF_BOOTLOADER="$PROVING/crates/stwo_run_and_prove_recursive_tree/test_data/leaf_simple_bootloader_compiled.json"

# Proof lock shared with the other spikes (ROADMAP §4): at most one proof > 2^19 steps at a time.
proof_lock() {
  until mkdir "$SCRATCH/.proof-lock" 2>/dev/null; do sleep 30; done
  trap 'rmdir "$SCRATCH/.proof-lock" 2>/dev/null' EXIT
}
proof_unlock() {
  rmdir "$SCRATCH/.proof-lock" 2>/dev/null || true
  trap - EXIT
}

# `/usr/bin/time -l` wrapper (macOS): wall time + max RSS, appended to a log.
timed() {
  local log="$1"; shift
  /usr/bin/time -l "$@" 2>>"$log"
}

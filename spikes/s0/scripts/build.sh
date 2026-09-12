#!/usr/bin/env bash
# Build the S0 test programs (Scarb `#[executable]` targets) and, on demand, the
# pinned monorepo prover binaries.
#
#   ./build.sh              # build the Cairo programs only
#   ./build.sh --prover     # also build the Rust prover binaries in $PROVING_DIR
#
# Outputs: <pkg>/target/dev/<pkg>.executable.json for each program.
# (`scarb build` has no --release for executable targets; dev is the only profile.)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S0="$(dirname "$HERE")"
# shellcheck source=env.sh
source "$HERE/env.sh"

build_programs() {
  for pkg in "${PROGRAMS[@]}"; do
    echo "==> scarb build $pkg"
    ( cd "$S0/programs/$pkg" && ASDF_SCARB_VERSION="$SCARB_VERSION" scarb build )
  done
  echo
  echo "Executables:"
  for pkg in "${PROGRAMS[@]}"; do
    ls -l "$S0/programs/$pkg/target/dev/$pkg.executable.json"
  done
}

build_prover() {
  [ -d "$PROVING_DIR" ] || { echo "PROVING_DIR=$PROVING_DIR does not exist" >&2; exit 1; }
  echo "==> cargo build --release (monorepo @ $PROVING_COMMIT)"
  ( cd "$PROVING_DIR" \
    && CARGO_TARGET_DIR="$PROVING_DIR/target" \
       RUSTFLAGS="-C target-cpu=native -C opt-level=3" \
       cargo build --release \
         -p stwo-cairo-dev-utils -p stwo-run-and-prove -p stwo-vm-runner )
}

build_programs
if [ "${1:-}" = "--prover" ]; then build_prover; fi

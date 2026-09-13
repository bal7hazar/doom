#!/usr/bin/env bash
# Stages `@hellproof/prover-wasm` as *static assets* under client/public/prover/
# (roadmap P3.2):
#
#   client/public/prover/dist/   - the package's built JS (prover-worker.js, …)
#   client/public/prover/wasm/   - the two 45 MB wasm64 artifacts
#
# Why static rather than bundled: the artifacts are 90 MB, they are gitignored
# (their hashes live in prover/wasm/SHA256SUMS), and the package resolves its
# Worker and its wasm through `import.meta.url` - `dist/` and `wasm/` next to
# each other, exactly as they are laid out here. Rollup would have to be taught
# all three, for no gain: the module is fetched once and cached by the browser.
#
# The artifacts themselves are built by `prover/wasm/build.sh` (long: it compiles
# the Stwo prover for wasm64 twice). This script does not build them; it finds
# them, and says so if it cannot.
#
# Usage:
#   npm run prover                                  # look in the usual places
#   PROVER_WASM_DIST=/path/to/dist npm run prover   # …or in this one
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(dirname "$HERE")"
REPO_DIR="$(dirname "$CLIENT_DIR")"
PKG_DIR="$REPO_DIR/prover/wasm/pkg"
OUT_DIR="$CLIENT_DIR/public/prover"

ARTIFACTS=(hellproof_prover_wasm.wasm hellproof_prover_wasm.threads.wasm)

find_dist() {
  local candidates=()
  [ -n "${PROVER_WASM_DIST:-}" ] && candidates+=("$PROVER_WASM_DIST")
  candidates+=("$REPO_DIR/prover/wasm/dist" "$PKG_DIR/wasm")
  for dir in "${candidates[@]}"; do
    local ok=1
    for artifact in "${ARTIFACTS[@]}"; do
      [ -f "$dir/$artifact" ] || ok=0
    done
    if [ "$ok" = 1 ]; then
      echo "$dir"
      return 0
    fi
  done
  return 1
}

if ! DIST="$(find_dist)"; then
  cat >&2 <<EOF
ERROR: the wasm64 prover artifacts were not found.

Looked for ${ARTIFACTS[*]} in:
  \$PROVER_WASM_DIST (unset)
  $REPO_DIR/prover/wasm/dist
  $PKG_DIR/wasm

Build them with:
  cd $REPO_DIR/prover/wasm && ./build.sh

…or point PROVER_WASM_DIST at a directory that already has them. They are
gitignored on purpose (45 MB each); prover/wasm/SHA256SUMS pins their hashes.
EOF
  exit 1
fi

echo "Building the package (tsc) ..."
(cd "$PKG_DIR" && npm run --silent build)

mkdir -p "$OUT_DIR/dist" "$OUT_DIR/wasm"
echo "Copying $PKG_DIR/dist -> public/prover/dist"
cp "$PKG_DIR"/dist/*.js "$OUT_DIR/dist/"

for artifact in "${ARTIFACTS[@]}"; do
  echo "Copying $DIST/$artifact -> public/prover/wasm/$artifact"
  cp "$DIST/$artifact" "$OUT_DIR/wasm/$artifact"
done

echo "Done:"
ls -lh "$OUT_DIR/dist" "$OUT_DIR/wasm"

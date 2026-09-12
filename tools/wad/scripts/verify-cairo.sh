#!/usr/bin/env bash
# Copies the generated out/<map>.cairo into the throwaway cairo-check/
# package and runs `scarb build` on it, proving the generated Cairo
# constants actually compile (roadmap P0.2, Output B).
#
# Usage: ./scripts/verify-cairo.sh [map-name-lowercase]   (default: e1m1)
# Prerequisite: `npm run extract -- --wad <freedoom1.wad> --map E1M1 --out out/`
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAD_DIR="$(dirname "$SCRIPT_DIR")"
MAP="${1:-e1m1}"

SRC="$WAD_DIR/out/$MAP.cairo"
DEST="$WAD_DIR/cairo-check/src/$MAP.cairo"

if [ ! -f "$SRC" ]; then
  echo "ERROR: $SRC not found. Run \`npm run extract\` first." >&2
  exit 1
fi

cp "$SRC" "$DEST"
echo "Copied $SRC -> $DEST"

if [ "$MAP" != "e1m1" ]; then
  echo "NOTE: cairo-check/src/lib.cairo hardcodes 'mod e1m1;' - update it if MAP != e1m1." >&2
fi

export ASDF_SCARB_VERSION="${ASDF_SCARB_VERSION:-2.16.0}"
cd "$WAD_DIR/cairo-check"
scarb build
echo "OK: cairo-check package compiled successfully."

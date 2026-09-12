#!/usr/bin/env bash
# Prepares the runtime assets the client fetches at startup (roadmap P2.1):
#
#   client/public/freedoom1.wad     - the IWAD, downloaded by tools/wad's fetcher
#   client/public/levels/e1m1.json  - the level JSON produced by tools/wad
#
# Neither is committed (see client/.gitignore): Freedoom is BSD-licensed so a
# production deployment may ship the WAD, but it must not enter git history.
#
# Usage:
#   npm run assets                  # E1M1 (default)
#   MAP=E1M2 npm run assets
#   FREEDOOM_DIR=/elsewhere npm run assets
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(dirname "$HERE")"
REPO_DIR="$(dirname "$CLIENT_DIR")"
WAD_TOOL_DIR="$REPO_DIR/tools/wad"

MAP="${MAP:-E1M1}"
MAP_LOWER="$(echo "$MAP" | tr '[:upper:]' '[:lower:]')"

# tools/wad/scripts/fetch-freedoom.sh owns the download URL and its checksum.
bash "$WAD_TOOL_DIR/scripts/fetch-freedoom.sh"

# Recover the directory the fetcher used (same default it computes itself).
DEFAULT_DIR="$(sed -n 's/^DEFAULT_DIR="\(.*\)"$/\1/p' "$WAD_TOOL_DIR/scripts/fetch-freedoom.sh")"
FREEDOOM_DIR="${FREEDOOM_DIR:-$DEFAULT_DIR}"
WAD_PATH="$FREEDOOM_DIR/freedoom1.wad"

if [ ! -f "$WAD_PATH" ]; then
  echo "ERROR: $WAD_PATH not found after fetch-freedoom.sh" >&2
  exit 1
fi

mkdir -p "$CLIENT_DIR/public/levels"

echo "Copying $WAD_PATH -> client/public/freedoom1.wad"
cp "$WAD_PATH" "$CLIENT_DIR/public/freedoom1.wad"

echo "Extracting $MAP with tools/wad ..."
if [ ! -d "$WAD_TOOL_DIR/node_modules" ]; then
  (cd "$WAD_TOOL_DIR" && npm install --no-audit --no-fund)
fi
# tools/wad writes <out>/<map>.json, <out>/<map>.cairo and ../REPORT-<map>.md;
# extracting into tools/wad/out keeps the committed report untouched, and we
# copy only the JSON the client needs.
(cd "$WAD_TOOL_DIR" && npm run --silent extract -- --wad "$WAD_PATH" --map "$MAP" --out "$WAD_TOOL_DIR/out")
cp "$WAD_TOOL_DIR/out/$MAP_LOWER.json" "$CLIENT_DIR/public/levels/$MAP_LOWER.json"

echo "Done:"
ls -lh "$CLIENT_DIR/public/freedoom1.wad" "$CLIENT_DIR/public/levels/$MAP_LOWER.json"

#!/usr/bin/env bash
# Downloads the Freedoom v0.13.0 release, verifies its checksum, and extracts
# freedoom1.wad (the Phase 1 IWAD used for the E1M1 map) into $FREEDOOM_DIR.
#
# Usage:
#   ./scripts/fetch-freedoom.sh
#   FREEDOOM_DIR=/some/other/dir ./scripts/fetch-freedoom.sh
#
# WAD files must never be committed to the repository (see tools/wad/.gitignore).
set -euo pipefail

RELEASE_URL="https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip"
# Pinned once, from `shasum -a 256 freedoom-0.13.0.zip` on the file downloaded
# from the URL above (2026-09-12). Re-pin only if the release asset changes.
EXPECTED_SHA256="3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59"

DEFAULT_DIR="/private/tmp/claude-501/-Users-bal7hazar-git-doom/052c133d-8e48-4871-8024-3d2fd1081b4c/scratchpad/freedoom"
FREEDOOM_DIR="${FREEDOOM_DIR:-$DEFAULT_DIR}"
ZIP_NAME="freedoom-0.13.0.zip"
ZIP_PATH="$FREEDOOM_DIR/$ZIP_NAME"
WAD_NAME="freedoom1.wad"
WAD_PATH="$FREEDOOM_DIR/$WAD_NAME"

mkdir -p "$FREEDOOM_DIR"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

if [ -f "$WAD_PATH" ]; then
  echo "freedoom1.wad already present at $WAD_PATH, skipping download."
  exit 0
fi

if [ ! -f "$ZIP_PATH" ]; then
  echo "Downloading $RELEASE_URL ..."
  curl -fL --retry 3 -o "$ZIP_PATH.part" "$RELEASE_URL"
  mv "$ZIP_PATH.part" "$ZIP_PATH"
else
  echo "Archive already downloaded at $ZIP_PATH, verifying checksum."
fi

ACTUAL_SHA256="$(sha256_of "$ZIP_PATH")"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "ERROR: sha256 mismatch for $ZIP_PATH" >&2
  echo "  expected: $EXPECTED_SHA256" >&2
  echo "  actual:   $ACTUAL_SHA256" >&2
  rm -f "$ZIP_PATH"
  exit 1
fi
echo "Checksum OK ($ACTUAL_SHA256)."

echo "Extracting $WAD_NAME ..."
# -j: junk paths (freedoom-0.13.0.zip stores the wad under a versioned subdir)
unzip -o -j "$ZIP_PATH" "*/$WAD_NAME" -d "$FREEDOOM_DIR" >/dev/null

if [ ! -f "$WAD_PATH" ]; then
  echo "ERROR: $WAD_NAME not found in archive after extraction." >&2
  exit 1
fi

echo "Done: $WAD_PATH"

#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Applies the Hellproof patch series onto a pristine `crates/` of stwo_cairo_verifier@cd7bc5f.
# Run from `vendor/stwo_cairo_verifier/` (the patches use `a/crates/...` paths):
#   sh ../patches/apply.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
patch -p1 < "$HERE/../stwo_cairo_verifier/hellproof-visibility.patch"
for p in "$HERE"/0*.patch; do
  echo "applying $(basename "$p")"
  patch -p1 < "$p"
done

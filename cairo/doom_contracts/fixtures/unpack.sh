#!/usr/bin/env sh
# SPDX-License-Identifier: Apache-2.0
# Decompresses the committed proof fixtures next to their .gz (the .txt files are gitignored).
set -e
cd "$(dirname "$0")"
for f in *.txt.gz; do gunzip -kf "$f"; done
ls -la *.txt

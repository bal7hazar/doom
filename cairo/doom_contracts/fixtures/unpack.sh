#!/usr/bin/env sh
# SPDX-License-Identifier: Apache-2.0
# Decompresses the committed proof fixtures next to their .gz (the .txt files are gitignored):
# the S4 goldens (`*.txt.gz`, one felt per line) and the two proved ten-felt batches of P4.2b
# (`crates/recursion_outputs/fixtures/B2*_doom/root.proof.gz`, JSON arrays of hex felts,
# rewritten one felt per line as `b2_doom_root_proof.txt` / `b2_1_doom_root_proof.txt`) — the
# real root proofs the P4.1 equivalence tests run on.
set -e
cd "$(dirname "$0")"
for f in *.txt.gz; do gunzip -kf "$f"; done
for b in B2_doom:b2_doom B2-1_doom:b2_1_doom; do
  src=../crates/recursion_outputs/fixtures/${b%%:*}/root.proof.gz
  dst=${b##*:}_root_proof.txt
  gzip -dc "$src" | python3 -c 'import json,sys; print("\n".join(str(int(x,16)) for x in json.load(sys.stdin)))' > "$dst"
done
ls -la *.txt

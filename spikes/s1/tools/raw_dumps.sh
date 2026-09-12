#!/bin/sh
# Spike S1 - capture the raw `scarb execute --print-resource-usage` blocks that
# back the tables in docs/spikes/S1.md.
set -e
export ASDF_SCARB_VERSION=2.16.0
cd "$(dirname "$0")/../proto"
OUT=../results/resource_usage.txt
: > "$OUT"
for sc in 0 1 2 3; do
  for cfg in "1,1,1,0,1,0 optimised" "0,0,0,0,1,0 baseline"; do
    set -- $cfg
    echo "=== scenario $sc, 350 tics, $2 (opts $1) ===" >> "$OUT"
    scarb execute --no-build --executable-name proto --output none \
      --print-resource-usage --arguments "$sc,350,$1" >> "$OUT"
    echo >> "$OUT"
  done
done
echo "wrote $OUT"

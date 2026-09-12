#!/usr/bin/env bash
# S4b measurement 3, second half: `canonical_small` cannot commit a trace of log size > 20
# (no `seq_21` preprocessed column), so a 2^21 leaf would have to use the full `canonical`
# preprocessed trace. At which trace log sizes does a `canonical` leaf circuit even build?
#
#   spikes/s4/scripts/canonical_sweep.sh [log_sizes...]     (default: 20 21 22 23 24 25)
#
# Report pass only (dummy preprocessed root): seconds and ~2 GB per point, no proof.
# Results -> spikes/s4/results/canonical_log_sweep.txt
set -uo pipefail
source "$(dirname "$0")/env.sh"

KS=("$@"); [ ${#KS[@]} -gt 0 ] || KS=(20 21 22 23 24 25)
SRC="$S4_DIR/registry/doom_21_canonical"
DST="$PROVING/circuit_registry_definitions/doom_21_canonical"
OUT="$S4_DIR/results/canonical_log_sweep.txt"
rm -rf "$DST" && mkdir -p "$DST" && cp "$SRC"/*.json "$DST/"

cd "$PROVING"
{
  echo "# circuit-params report, preprocessed_trace = canonical, one trace log size per line"
  echo "# (spikes/s4/scripts/canonical_sweep.sh; proving @ $PROVING_COMMIT)"
} > "$OUT"
for k in "${KS[@]}"; do
  python3 - "$DST/definition.json" "$k" <<'PY'
import json, sys
p, k = sys.argv[1], int(sys.argv[2])
d = json.load(open(p))
d["min_trace_log_size"] = d["max_trace_log_size"] = k
open(p, "w").write(json.dumps(d, indent=4) + "\n")
PY
  out="$("$BIN/circuit-params" --definition "$DST/definition.json" 2>&1)"
  if printf '%s' "$out" | grep -q panicked; then
    line="log $k: PANIC $(printf '%s' "$out" | grep -A1 panicked | tail -1)"
  else
    line="log $k: OK    $(printf '%s' "$out" | sed -n '2p')"
  fi
  echo "$line" | tee -a "$OUT"
done
# Leave the definition at the value it is committed with.
cp "$SRC/definition.json" "$DST/definition.json"

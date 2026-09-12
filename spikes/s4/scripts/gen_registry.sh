#!/usr/bin/env bash
# Generates a circuit registry from one of our definitions (R3-A2).
#
# Usage: spikes/s4/scripts/gen_registry.sh <name> [--registry-only]
#   <name> is a directory under spikes/s4/registry/ (doom, doom_min, doom_19_20).
#
# The definition's paths are relative to the monorepo root (like upstream's), so the directory is
# copied to $PROVING/circuit_registry_definitions/<name>/ and circuit-params runs from $PROVING.
# Outputs (report.txt, registry.json, *.time) are copied back to spikes/s4/registry/<name>/.
set -euo pipefail
source "$(dirname "$0")/env.sh"

NAME="${1:?usage: gen_registry.sh <name> [--registry-only]}"
MODE="${2:-}"
SRC="$S4_DIR/registry/$NAME"
DST="$PROVING/circuit_registry_definitions/$NAME"
[ -d "$SRC" ] || { echo "no definition at $SRC" >&2; exit 1; }
rm -rf "$DST" && mkdir -p "$DST" && cp "$SRC"/*.json "$DST/"
# A previously generated registry.json is not an input.
rm -f "$DST/registry.json"

cd "$PROVING"
if [ "$MODE" != "--registry-only" ]; then
  echo "== circuit-params report ($NAME) =="
  timed "$SRC/report.time" "$BIN/circuit-params" --definition "$DST/definition.json" --output-path "$SRC/report.txt"
  cat "$SRC/report.txt"
fi

echo "== circuit-params --registry ($NAME) =="
# Commits the real Cairo preprocessed trace and preprocesses the padded circuits: several GB.
proof_lock
timed "$SRC/registry.time" "$BIN/circuit-params" --registry --definition "$DST/definition.json" --output-path "$SRC/registry.json"
proof_unlock
grep -E "real|maximum resident" "$SRC/registry.time"
python3 - "$SRC/registry.json" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
print("component_log_sizes:", r["circuit_proof_configs"]["default"]["component_log_sizes"])
for l in r["leaf_verifiers"]:
    print("leaf  trace_log_size", l["trace_log_size"], "circuit_hash", "".join(w[2:] for w in l["circuit_hash"]))
for m in r["multiverifiers"]:
    print("multiverifier circuit_hash", "".join(w[2:] for w in m["circuit_hash"]))
EOF

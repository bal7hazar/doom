#!/usr/bin/env bash
# Runs the whole S4 measurement campaign sequentially (each step takes the shared proof lock).
# Usage: spikes/s4/scripts/run_all.sh [N...]   (default: 2 3 4)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS=("$@"); [ ${#NS[@]} -gt 0 ] || NS=(2 3 4)
for n in "${NS[@]}"; do
  echo "######## N=$n ########"
  "$HERE/run_pipeline.sh" "$n"
done
# Registry determinism (R3-A2 exit criterion): regenerate and diff.
cp "$HERE/../registry/doom/registry.json" "$HERE/../registry/doom/registry.first.json"
"$HERE/gen_registry.sh" doom --registry-only
if cmp -s "$HERE/../registry/doom/registry.json" "$HERE/../registry/doom/registry.first.json"; then
  echo "registry doom: deterministic (byte-identical on regeneration)"
else
  echo "registry doom: DIFFERS on regeneration"; diff "$HERE/../registry/doom/registry.json" "$HERE/../registry/doom/registry.first.json" || true
fi
rm -f "$HERE/../registry/doom/registry.first.json"

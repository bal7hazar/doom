#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Hellproof contributors
# SPDX-License-Identifier: Apache-2.0
#
# P3.4b equivalence check: a leaf proven from an already-made segment proof
# (`leaf_mode = "from_proof"`, patch `proving-0001-leaf-prover-from-proof.patch`) must be
# interchangeable with one proven by re-running and re-proving the segment (`"rerun"`).
#
# For N browser-equivalent segment proofs it produces two sets of leaves, folds each with
# `stwo_run_and_prove_recursive_tree`, and checks that the two roots agree on everything the
# contract sees: the leaf circuit hash, the root `program_output`, the packed output tree, and
# the felt count. It then runs the Cairo circuit verifier on the proof-only root, and finally
# feeds a proof with one felt flipped back into `leaf-prover` to confirm the circuit-building
# step rejects it instead of proving something else.
#
# Usage:  leaf_mode_equivalence.sh <fixtures_dir> [work_dir]
#         (fixtures_dir = output of scripts/e2e_fixtures.sh)
#
# Environment (same knobs as spikes/s4/scripts/env.sh):
#   PROVING        patched monorepo clone @ cd7bc5f + patches/   (default: $SCRATCH/proving-p34b)
#   BIN            its release binaries               (default: $PROVING/target/release)
#   REGISTRY       circuit registry JSON              (default: spikes/s4/registry/doom)
#   SCRATCH        scratchpad, also holds .proof-lock (default: /tmp)
#   SKIP_VERIFIER  set to 1 to skip the scarb circuit-verifier run
set -euo pipefail

FX="${1:?usage: leaf_mode_equivalence.sh <fixtures_dir> [work_dir]}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SCRATCH="${SCRATCH:-/tmp}"
WORK="${2:-$SCRATCH/p34b-equiv}"
PROVING="${PROVING:-$SCRATCH/proving-p34b}"
BIN="${BIN:-$PROVING/target/release}"
REGISTRY="${REGISTRY:-$REPO/spikes/s4/registry/doom/registry.json}"
BOOTLOADER="$PROVING/crates/stwo_run_and_prove_recursive_tree/test_data/leaf_simple_bootloader_compiled.json"
INJECT="$REPO/spikes/s4/scripts/inject_preimage.py"

for f in "$BIN/leaf-prover" "$BIN/stwo_run_and_prove_recursive_tree" "$BOOTLOADER" "$REGISTRY" \
         "$INJECT" "$FX/manifest.json"; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done
"$BIN/leaf-prover" --help | grep -q -- --cairo_proof \
  || { echo "$BIN/leaf-prover has no --cairo_proof: apply patches/ first" >&2; exit 1; }

N="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["segments"]))' "$FX/manifest.json")"
mkdir -p "$WORK"
echo "== $N segments, registry $(basename "$(dirname "$REGISTRY")"), work $WORK"

# One circuit proof at a time: ~32 GB each (S4).
proof_lock()   { until mkdir "$SCRATCH/.proof-lock" 2>/dev/null; do sleep 30; done
                 trap 'rmdir "$SCRATCH/.proof-lock" 2>/dev/null' EXIT; }
proof_unlock() { rmdir "$SCRATCH/.proof-lock" 2>/dev/null || true; trap - EXIT; }

# ---- leaves ------------------------------------------------------------------------------------
for MODE in rerun from_proof; do
  mkdir -p "$WORK/$MODE"
  for ((i = 0; i < N; i++)); do
    raw="$WORK/$MODE/leaf_$i.raw.json"
    log="$WORK/$MODE/leaf_$i.log"
    if [ "$MODE" = rerun ]; then
      set -- --program "$BOOTLOADER" --program_input "$FX/bl_input_$i.json"
    else
      set -- --program "$BOOTLOADER" --cairo_proof "$FX/segment_$i.proof" \
             --proof_format extended-binary
    fi
    echo "== $MODE leaf $i"
    proof_lock
    /usr/bin/time -l "$BIN/leaf-prover" "$@" \
      --circuit_registry_json "$REGISTRY" --output_path "$raw" > "$log" 2>&1 \
      || { tail -20 "$log"; proof_unlock; exit 1; }
    proof_unlock
    grep -E "real|maximum resident" "$log" || true
    # Both modes take the preimage from the same place the wrapper does: `rerun` from the
    # bootloader's own dump, `from_proof` from the submission (here, the fixture manifest).
    python3 "$INJECT" "$raw" "$FX/preimage_$i.json" "$WORK/$MODE/leaf_$i.json" > /dev/null
  done

  python3 - "$WORK/$MODE" "$N" <<'PY'
import json, sys
d, n = sys.argv[1], int(sys.argv[2])
json.dump({"leaves": [f"{d}/leaf_{i}.json" for i in range(n)]}, open(f"{d}/leaves.json", "w"))
PY

  echo "== $MODE fold"
  proof_lock
  /usr/bin/time -l "$BIN/stwo_run_and_prove_recursive_tree" \
    --program_input "$WORK/$MODE/leaves.json" \
    --circuit_registry_json "$REGISTRY" \
    --proof_path "$WORK/$MODE/root.proof" \
    --program_output "$WORK/$MODE/program_output.json" \
    --packed_output_path "$WORK/$MODE/packed_output.json" \
    > "$WORK/$MODE/fold.log" 2>&1 || { tail -20 "$WORK/$MODE/fold.log"; proof_unlock; exit 1; }
  proof_unlock
  grep -E "real|maximum resident" "$WORK/$MODE/fold.log" || true
done

# ---- compare -----------------------------------------------------------------------------------
python3 - "$WORK" "$N" <<'PY'
import json, sys
w, n = sys.argv[1], int(sys.argv[2])
load = lambda p: json.load(open(p))
ok = True
def eq(name, a, b):
    global ok
    same = a == b
    ok &= same
    print(f"{'OK  ' if same else 'FAIL'} {name}")
    if not same:
        print(f"     rerun      = {a}")
        print(f"     from_proof = {b}")

for i in range(n):
    a, b = load(f"{w}/rerun/leaf_{i}.json"), load(f"{w}/from_proof/leaf_{i}.json")
    eq(f"leaf {i} circuit_hash", a["circuit_hash"], b["circuit_hash"])
    eq(f"leaf {i} circuit_preprocessed_root", a["circuit_preprocessed_root"],
       b["circuit_preprocessed_root"])
    eq(f"leaf {i} output_preimage", a["output_preimage"], b["output_preimage"])

eq("root program_output", load(f"{w}/rerun/program_output.json"),
   load(f"{w}/from_proof/program_output.json"))
eq("root packed_output", load(f"{w}/rerun/packed_output.json"),
   load(f"{w}/from_proof/packed_output.json"))
ra, rb = load(f"{w}/rerun/root.proof"), load(f"{w}/from_proof/root.proof")
eq("root proof felt count", len(ra), len(rb))
print(f"     root proof: {len(rb)} felts")
sys.exit(0 if ok else 1)
PY

# ---- the on-chain verifier on the proof-only root -----------------------------------------------
if [ "${SKIP_VERIFIER:-0}" != 1 ]; then
  echo "== circuit verifier on the from_proof root"
  ( cd "$PROVING/stwo_cairo_verifier" \
    && scarb --profile proving execute -p stwo_circuit_verifier --features qm31_opcode \
         --no-build --output none --print-program-output \
         --arguments-file "$WORK/from_proof/root.proof" ) > "$WORK/verifier.log" 2>&1 \
    || { tail -30 "$WORK/verifier.log"; exit 1; }
  python3 - "$WORK/verifier.log" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if "Program output" in l)
felts = []
for l in lines[start + 1:]:
    l = l.strip()
    if not re.fullmatch(r"(0x[0-9a-fA-F]+|\d+)", l or "x"):
        break
    felts.append(int(l, 0))
assert len(felts) == 8, felts
print("OK   circuit verifier accepted; VerificationOutput.output_hash =", felts)
PY
  grep -E "steps|range_check" "$WORK/verifier.log" | head -3 || true
fi

# ---- a tampered proof must be rejected while the circuit is built -------------------------------
echo "== tampered proof"
python3 - "$FX/segment_0.proof" "$WORK/tampered.bin" <<'PY'
import bz2, sys
raw = open(sys.argv[1], "rb").read()
raw = bz2.decompress(raw) if raw[:3] == b"BZh" else raw
# One felt flipped: bump a u32 limb well inside the queried values / FRI region. Raw bincode is
# accepted as is (leaf-prover sniffs the bzip2 magic), so the framing around it is untouched.
off = len(raw) * 3 // 4 & ~3
b = bytearray(raw)
b[off] ^= 1
open(sys.argv[2], "wb").write(bytes(b))
print(f"flipped one bit at byte {off} of {len(raw)}")
PY
if "$BIN/leaf-prover" --program "$BOOTLOADER" --cairo_proof "$WORK/tampered.bin" \
     --proof_format extended-binary --circuit_registry_json "$REGISTRY" \
     --output_path "$WORK/tampered.leaf.json" > "$WORK/tampered.log" 2>&1; then
  echo "FAIL tampered proof was accepted" >&2
  exit 1
fi
echo "OK   tampered proof rejected: $(grep -m1 -iE "panicked|rejected|Error" "$WORK/tampered.log" | cut -c1-160)"
grep -E "real" "$WORK/tampered.log" || true

echo "== all checks passed"

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Prove one real segment of `doom_run::run_segment` natively, the way the
# browser will: as a task of the **leaf simple bootloader** with
# `program_hash_function: blake` (the current prover/wasm implementation), the leaf prover parameters of
# `prover/wasm/harness/params/leaf.json`, under the shared proof lock.
#
#   prove_segment.sh <out_dir> [scenario=fight] [n_tics=8]
#
# Steps: 1. build doom_run (proving profile); 2. genesis -> state felts;
# 3. args = [len, state.., len, words.., tic_start, max_tics] from
#    bench/profile.py's logs; 4. `scarb execute` for the steps and the
#    ten public felts; 5. stwo-vm-runner (trace size, no proof);
# 6. stwo-run-and-prove --verify with /usr/bin/time -l (wall, RSS).
#
# Environment: SCRATCH (the session scratchpad), PROVING (monorepo clone
# @ cd7bc5f with release binaries; default $SCRATCH/proving-s4),
# VM_RUNNER (default $SCRATCH/proving-s0/target/release/stwo-vm-runner).
set -euo pipefail
OUT="${1:?usage: prove_segment.sh <out_dir> [scenario] [n_tics]}"
SCENARIO="${2:-fight}"
N="${3:-8}"
PROOF_TIMEOUT="${PROOF_TIMEOUT:-600}"
PROGRAM_HASH_FUNCTION="${PROGRAM_HASH_FUNCTION:-blake}"
case "$PROGRAM_HASH_FUNCTION" in poseidon|blake) ;; *) echo "invalid hash function" >&2; exit 1 ;; esac
LOCK_TIMEOUT="${LOCK_TIMEOUT:-600}"
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-2}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
CAIRO="$REPO/cairo"
SCRATCH="${SCRATCH:-/private/tmp/claude-501/-Users-bal7hazar-git-doom/052c133d-8e48-4871-8024-3d2fd1081b4c/scratchpad}"
PROVING="${PROVING:-$SCRATCH/proving-s4}"
BIN="$PROVING/target/release"
VM_RUNNER="${VM_RUNNER:-$SCRATCH/proving-s0/target/release/stwo-vm-runner}"
BOOTLOADER="$PROVING/crates/stwo_run_and_prove_recursive_tree/test_data/leaf_simple_bootloader_compiled.json"
PARAMS="$REPO/prover/wasm/harness/params/leaf.json"
export ASDF_SCARB_VERSION=2.16.0
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

for f in "$BIN/stwo-run-and-prove" "$VM_RUNNER" "$BOOTLOADER" "$PARAMS"; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done

for clone in "$PROVING" "$(dirname "$(dirname "$(dirname "$VM_RUNNER")")")"; do
  rev="$(git -C "$clone" rev-parse HEAD)"
  [[ "$rev" == cd7bc5f* ]] || { echo "wrong proving revision: $clone $rev" >&2; exit 1; }
done

echo "== 1. build (proving profile)"
scarb --manifest-path "$CAIRO/Scarb.toml" --profile proving build -p doom_run >/dev/null
EXE="$CAIRO/target/proving/run_segment.executable.json"
WORDS_BC="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["program"]["bytecode"]))' "$EXE")"
echo "run_segment: $WORDS_BC bytecode words"

python3 - "$OUT" "$EXE" "$BIN/stwo-run-and-prove" "$VM_RUNNER" <<'PYMETA'
import hashlib, json, pathlib, sys
out, *paths = sys.argv[1:]
json.dump({str(p): hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in paths},
          open(pathlib.Path(out) / 'artifact_hashes.json', 'w'), indent=2)
PYMETA

echo "== 2. genesis state"
scarb --manifest-path "$CAIRO/Scarb.toml" --profile proving execute -p doom_run --executable-name genesis \
  --no-build --arguments 0 --print-program-output 2>/dev/null \
  | awk '/Program output:/{f=1;next} f && NF {print $1}' > "$OUT/genesis_out.txt"

echo "== 3. arguments ($SCENARIO, $N tics)"
python3 - "$OUT" "$SCENARIO" "$N" "$HERE/../../doom_game/bench" <<'PY'
import json, sys
out, scenario, n, bench = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
sys.path.insert(0, bench)
import profile as P
felts = [int(l, 0) % P.PRIME for l in open(f"{out}/genesis_out.txt").read().split()]
state = felts[1:1 + felts[0]]
words = P.LOGS[scenario]()[:n]
args = [len(state), *state, len(words), *words, 0, n]
json.dump([hex(a) for a in args], open(f"{out}/args.json", "w"))
print(f"state {len(state)} felts, {len(words)} words, {len(args)} argument felts")
PY

echo "== 4. scarb execute (steps, public output)"
scarb --manifest-path "$CAIRO/Scarb.toml" --profile proving execute -p doom_run --executable-name run_segment \
  --no-build --arguments-file "$OUT/args.json" --print-program-output --print-resource-usage \
  > "$OUT/execute.log" 2>&1 || { tail -20 "$OUT/execute.log"; exit 1; }
grep -E "steps|builtin|Program output" -A0 "$OUT/execute.log" | head -12
awk '/Program output:/{f=1;next} f && NF {print $1}' "$OUT/execute.log" | head -10 > "$OUT/output_felts.txt"
python3 - "$OUT/output_felts.txt" <<'PYNORMALIZE'
import pathlib, sys
path = pathlib.Path(sys.argv[1]); prime = (1 << 251) + 17 * (1 << 192) + 1
path.write_text(''.join(str(int(value, 0) % prime) + '\n' for value in path.read_text().split()))
PYNORMALIZE
echo "public output:"; cat "$OUT/output_felts.txt"

echo "== 5. bootloader trace (stwo-vm-runner)"
cat > "$OUT/bl_input.json" <<EOF
{
  "tasks": [
    { "type": "Cairo1Executable", "path": "$EXE",
      "program_hash_function": "$PROGRAM_HASH_FUNCTION", "user_args_file": "$OUT/args.json" }
  ],
  "fact_topologies_path": null,
  "single_page": true,
  "output_preimage_dump_path": "$OUT/output_preimage.json"
}
EOF
"$VM_RUNNER" --program "$BOOTLOADER" --program_input "$OUT/bl_input.json" --layout all_cairo_stwo \
  --output_execution_resources_path "$OUT/execution_resources.json" \
  --output_vm_execution_resources_path "$OUT/vm_execution_resources.json" > "$OUT/vmrun.log" 2>&1 \
  || { tail -20 "$OUT/vmrun.log"; exit 1; }
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("bootloader run: n_steps", d["n_steps"], "builtins", d["builtin_instance_counter"])' "$OUT/vm_execution_resources.json"
python3 - "$OUT" <<'PYPREIMAGE'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
preimage = [int(v, 0) for v in json.loads((out / 'output_preimage.json').read_text())]
expected = [int(v, 0) for v in (out / 'output_felts.txt').read_text().split()]
if len(preimage) != 11 or len(expected) != 10 or preimage[1:] != expected:
    raise SystemExit('bootloader public preimage differs from the real segment output')
print('verified public preimage: program hash + the exact ten segment felts')
PYPREIMAGE

if [[ "${SKIP_PROOF:-0}" == "1" ]]; then exit 0; fi

echo "== 6. prove + verify (lock: $SCRATCH/.proof-lock)"
lock_deadline=$((SECONDS + LOCK_TIMEOUT))
until mkdir "$SCRATCH/.proof-lock" 2>/dev/null; do
  if ((SECONDS >= lock_deadline)); then echo "proof lock busy; owner left untouched" >&2; exit 1; fi
  sleep 10
done
printf '%s\n' "$$" > "$SCRATCH/.proof-lock/owner.pid"
release_lock() {
  if [[ "$(cat "$SCRATCH/.proof-lock/owner.pid" 2>/dev/null)" == "$$" ]]; then
    unlink "$SCRATCH/.proof-lock/owner.pid"
    rmdir "$SCRATCH/.proof-lock"
  fi
}
trap release_lock EXIT
# Python supervises an entire process group and kills all proving threads
# on timeout. A timeout is a failure, never a successful proof.
python3 - "$PROOF_TIMEOUT" "$OUT/prove.log" /usr/bin/time -l "$BIN/stwo-run-and-prove" \
  --program "$BOOTLOADER" --program_input "$OUT/bl_input.json" \
  --prover_params_json "$PARAMS" \
  --proof_path "$OUT/proof.cairo_serde.json" --proof-format cairo-serde \
  --program_output "$OUT/program_output.json" --verify <<'PYTIME'
import json, os, signal, subprocess, sys, time
seconds, logfile, *command = sys.argv[1:]
started = time.monotonic()
peak_rss = 0
with open(logfile, 'w') as log:
    child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    while child.poll() is None:
        listing = subprocess.check_output(['ps', '-axo', 'pgid=,rss='], text=True)
        rss = sum(int(row[1]) * 1024 for line in listing.splitlines()
                  if len(row := line.split()) == 2 and int(row[0]) == child.pid)
        peak_rss = max(peak_rss, rss)
        if time.monotonic() - started >= int(seconds):
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            log.write('\nTIMEOUT: proof process group killed\n')
            result = 124
            break
        try: child.wait(timeout=0.5)
        except subprocess.TimeoutExpired: pass
    else:
        result = child.returncode
json.dump({'exit_code': result, 'wall_seconds': time.monotonic() - started,
           'sampled_process_group_peak_rss_bytes': peak_rss, 'timeout_seconds': int(seconds)},
          open(os.path.join(os.path.dirname(logfile), 'proof_metrics.json'), 'w'), indent=2)
sys.exit(result)
PYTIME
release_lock; trap - EXIT
grep -E "real|maximum resident" "$OUT/prove.log" | tee "$OUT/prove.time"
grep -oE "(trace_log_size|log_size|component)[^,]{0,80}" "$OUT/prove.log" | sort | uniq -c | sort -rn | head -12 || true
python3 -c 'import json,sys; print("proof felts:", len(json.load(open(sys.argv[1]))))' "$OUT/proof.cairo_serde.json"
echo "output preimage:"; cat "$OUT/output_preimage.json"; echo
echo "Local proof verified; registry fit requires the actual AIR claim sizes (see S8)."
echo "done: $OUT"

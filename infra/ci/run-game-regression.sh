#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Exact full-game regressions; nightly mode additionally advances 10,000 fuzz tics.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:?usage: run-game-regression.sh OUTPUT_DIR [corpus|nightly]}
mode=${2:-corpus}
case "$mode" in corpus|nightly) ;; *) echo "unknown mode: $mode" >&2; exit 2 ;; esac
mkdir -p "$out"
out=$(cd "$out" && pwd)
export ASDF_SCARB_VERSION=2.16.0 RAYON_NUM_THREADS=2 CARGO_BUILD_JOBS=2
export SCARB_TARGET_DIR="$repo/cairo/target"
cd "$repo"

# Keep both compiler profiles. No proof or native-probe toolchain is involved.
python3 - "$repo" "$out" <<'PY'
import os, signal, subprocess, sys
from pathlib import Path
repo, out = map(Path, sys.argv[1:])
for profile in ("dev", "proving"):
    command = ["scarb", "--manifest-path", str(repo / "cairo/Scarb.toml"),
               "--profile", profile, "build", "-p", "doom_run"]
    with (out / f"build-{profile}.log").open("w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=600)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
        if code:
            raise SystemExit(code)
PY

status=0
python3 -m unittest discover -s cairo/doom/doom_game/regression -p 'test_*.py' \
  2>&1 | tee "$out/harness-tests.log" || status=1
python3 cairo/doom/doom_game/regression/run.py corpus --out "$out/corpus" \
  --profiles dev proving --timeout 120 --max-seconds 3600 \
  2>&1 | tee "$out/corpus.log" || status=1
if [ "$mode" = nightly ]; then
  python3 cairo/doom/doom_game/regression/run.py fuzz --out "$out/fuzz" \
    --profile proving --tics 10000 --seed "${GAME_FUZZ_SEED:-20260913}" \
    --timeout 120 --max-seconds 3600 \
    2>&1 | tee "$out/fuzz.log" || status=1
fi
# D29 sets 100k as the target and 120k as the distinct hard ceiling; D36 makes the
# target advisory (printed, never silently raised) and keeps the ceiling blocking.
# Run after correctness so a size miss cannot suppress the regression evidence.
# No --report or tolerated exit code turns this gate green.
python3 cairo/doom/doom_run/bench/size.py 2>&1 | tee "$out/bytecode.log" || status=1
exit "$status"

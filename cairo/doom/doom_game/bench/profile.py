#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Per-tic step timeline of the golden scenarios (docs/spikes/S8).

Drives the **real executables** of `doom_run`: `genesis` gives the state
felts, then `step_tic(state, words)` is executed chunk by chunk along a
scenario's input log with `--print-resource-usage`, each execution's step
count netted against a zero-tic execution on the same state (which pays
the argument parsing, `from_felts`, the grid rebuild, `serialize` and the
snapshot). Chunks of one tic over the first `--fine` tics give the per-tic
distribution where the spikes are; chunks of `--chunk` tics after that
give the mean of the rest. Output: one JSON per scenario with the samples,
and a Markdown table (mean, p50, p90, p99, max) to paste into the report.

    python3 profile.py --scenario fight --tics 700 --fine 100 --chunk 10
    python3 profile.py --all

Words are the same logs as `src/tests/e1m1.cairo` (`script()` below).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[2]
RESULTS = HERE / "results"
PROFILE = os.environ.get("BENCH_PROFILE", "proving")
NATIVE_RUNNER = os.environ.get("SIM_PROBE")
RUNNERS = {}
PRIME = (1 << 251) + 17 * (1 << 192) + 1
RE_RESOURCE = re.compile(r"^\s*([a-z_0-9 ]+):\s*([0-9,]+)\s*$")


def word(forward: int, side: int, turn: int, buttons: int) -> int:
    """`ticcmd::encode`: forward+128 | side+128 << 8 | turn/256+128 << 16 | buttons << 24."""
    assert -128 <= forward <= 127 and -128 <= side <= 127 and turn % 256 == 0
    return (forward + 128) | ((side + 128) << 8) | ((turn // 256 + 128) << 16) | (buttons << 24)


def script(segs) -> list[int]:
    out = []
    for tics, f, s, t, b in segs:
        out.extend([word(f, s, t, b)] * tics)
    return out


def idle_log():
    return script([(700, 0, 0, 0, 0)])


def walk_log():
    return script([(110, 25, 0, 0, 0), (240, 0, 0, 0, 0)])


def fight_log():
    segs = [(110, 25, 0, 0, 0), (1, 0, 0, 6656, 0)]
    for _ in range(2):
        for _ in range(13):
            segs += [(20, 0, 0, 0, 1), (1, 0, 0, -512, 1)]
        segs.append((1, 0, 0, 6656, 1))
    segs.append((41, 0, 0, 0, 1))
    return script(segs)


def door_log():
    segs = [(136, 25, 0, 0, 0), (1, 0, 0, 10240, 0), (25, 25, 0, 0, 0), (1, 0, 0, 6144, 0)]
    for _ in range(5):
        segs += [(34, 25, 0, 0, 0), (1, 25, 0, 0, 2)]
    segs.append((12, 0, 0, 0, 0))
    return script(segs)


def death_log():
    return script([(150, 25, 0, 0, 0), (1, 0, 0, 1792, 0), (1049, 0, 0, 0, 0)])


LOGS = {"idle": idle_log, "walk": walk_log, "fight": fight_log, "door": door_log, "death": death_log}


def scarb(args: list[str]) -> subprocess.CompletedProcess:
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    return subprocess.run(
        ["scarb", "--manifest-path", str(WORKSPACE / "Scarb.toml"), "--profile", PROFILE, *args],
        capture_output=True, text=True, env=env,
    )


def execute(name: str, args: list[int]) -> tuple[list[int], dict[str, int]]:
    """Run one executable with a flat felt argument list; return (output felts, resources)."""
    if NATIVE_RUNNER:
        if name not in RUNNERS:
            RUNNERS[name] = subprocess.Popen([NATIVE_RUNNER, str(WORKSPACE / "target" / PROFILE / f"{name}.executable.json")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        runner = RUNNERS[name]
        runner.stdin.write(" ".join(hex(a) for a in args) + "\n")
        runner.stdin.flush()
        line = runner.stdout.readline()
        if not line: raise RuntimeError(f"native simulation stopped: {name}")
        values = line.split()
        return [int(v, 0) for v in values[1:]], {"steps": int(values[0])}
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump([hex(a) for a in args], f)
        path = f.name
    p = scarb(["execute", "-p", "doom_run", "--executable-name", name, "--no-build",
               "--print-program-output", "--print-resource-usage", "--arguments-file", path])
    os.unlink(path)
    if p.returncode != 0:
        raise SystemExit("execute %s failed:\n%s\n%s" % (name, p.stdout[-3000:], p.stderr[-3000:]))
    out: list[int] = []
    res: dict[str, int] = {}
    in_output = False
    for line in p.stdout.splitlines():
        if line.startswith("Program output:"):
            in_output = True
            continue
        if line.startswith("Resources:"):
            in_output = False
            continue
        m = RE_RESOURCE.match(line)
        if m:
            in_output = False
            res[m.group(1).strip()] = int(m.group(2).replace(",", ""))
            continue
        if in_output:
            t = line.strip()
            if t:
                out.append(int(t, 0) % PRIME)
    return out, res


def genesis_state() -> list[int]:
    out, _ = execute("genesis", [0])
    n = out[0]
    return out[1:1 + n]


def step(state: list[int], words: list[int]) -> tuple[int, list[int], int]:
    """(status, new state, steps) of step_tic over `words`."""
    args = [len(state), *state, len(words), *words]
    out, res = execute("step_tic", args)
    status = out[0]
    n = out[1]
    new_state = out[2:2 + n]
    return status, new_state, res["steps"]


def profile(name: str, tics: int, fine: int, chunk: int) -> dict:
    log = LOGS[name]()[:tics]
    state = genesis_state()
    samples: list[dict] = []
    t = 0
    base = None
    k = 0
    while t < len(log):
        size = 1 if t < fine else min(chunk, len(log) - t)
        words = log[t:t + size]
        # The fixed cost of this state: parse, from_felts, grid, serialize,
        # snapshot. It only moves with the list length, so it is re-measured
        # every 25 samples rather than at every one.
        if base is None or size == 1 or k % 25 == 0:
            _, _, base = step(state, [])
        k += 1
        status, new_state, steps = step(state, words)
        actual = new_state[4] - state[4]
        if actual == 0: break
        per_tic = (steps - base) / actual
        size = actual
        samples.append({"tic": t, "tics": size, "steps_per_tic": per_tic, "fixed": base})
        print("%s tic %4d (+%d): %8.0f steps/tic (fixed %d)" % (name, t, size, per_tic, base),
              flush=True)
        state = new_state
        t += size
        if status != 0:
            print("%s: terminal status %d at tic %d" % (name, status, t))
            break
    per_tic = [s["steps_per_tic"] for s in samples for _ in range(s["tics"])]
    fine_only = [s["steps_per_tic"] for s in samples if s["tics"] == 1]
    summary = {
        "scenario": name,
        "profile": PROFILE,
        "runner": "prover/sim cairo-lang 2.19.4" if NATIVE_RUNNER else "scarb 2.16.0",
        "distribution_exact": all(s["tics"] == 1 for s in samples),
        "tics": len(per_tic),
        "mean": statistics.fmean(per_tic),
        "p50": statistics.median(per_tic),
        "p90": quantile(per_tic, 0.90),
        "p99": quantile(per_tic, 0.99) if all(s["tics"] == 1 for s in samples) else None,
        "chunk_p99": quantile(per_tic, 0.99),
        "max": max(per_tic),
        "fine_tics": len(fine_only),
        "fine_p99": quantile(fine_only, 0.99) if fine_only else None,
        "fine_max": max(fine_only) if fine_only else None,
        "fixed_cost": statistics.fmean(s["fixed"] for s in samples),
        "samples": samples,
    }
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / f"profile_{name}.json").write_text(json.dumps(summary, indent=1) + "\n")
    return summary


def quantile(xs: list[float], q: float) -> float:
    ys = sorted(xs)
    k = min(len(ys) - 1, int(round(q * (len(ys) - 1))))
    return ys[k]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", action="append", choices=sorted(LOGS))
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--tics", type=int, default=1200)
    ap.add_argument("--fine", type=int, default=1200)
    ap.add_argument("--chunk", type=int, default=1)
    args = ap.parse_args()
    names = sorted(LOGS) if args.all else (args.scenario or ["idle"])
    rows = []
    for name in names:
        s = profile(name, args.tics, args.fine, args.chunk)
        rows.append(s)
    print("\n| scenario | tics | mean | p50 | p90 | p99 | max | fixed/segment load |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|")
    for s in rows:
        p99 = "n/a (coarse chunks)" if s["p99"] is None else "%.0f" % s["p99"]
        print("| %s | %d | %.0f | %.0f | %.0f | %s | %.0f | %.0f |" % (
            s["scenario"], s["tics"], s["mean"], s["p50"], s["p90"], p99, s["max"],
            s["fixed_cost"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())

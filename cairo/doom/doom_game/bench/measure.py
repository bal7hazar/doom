#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Step-cost test of a whole tic and its subsystems (docs/spikes/S8).

Differential measurement (S1 §3.1): every op of `src/lib.cairo` runs with
`n` and `2n` iterations on a scene of a golden scenario, so the scene's
construction and the (de)serialization cancel, and an op's `net` cost
subtracts the baseline op that builds the same scene. Fails at +10 % over
`budgets.json` (PLAN.md §3.1 rule 4).

Usage:
    python3 measure.py            # measure, print the table, check budgets
    python3 measure.py --json out.json
    python3 measure.py --update   # re-baseline budgets.json
    python3 measure.py -n 4       # iterations (default from budgets.json)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RE_RESOURCE = re.compile(r"^\s*([a-z_0-9 ]+):\s*([0-9,]+)\s*$")
TOLERANCE = 1.10
D2_STEPS_PER_TIC = 12000
PROFILE = os.environ.get("BENCH_PROFILE", "proving")
NATIVE_RUNNER = os.environ.get("SIM_PROBE")
RUNNER = None


def scarb(args: list[str], cwd: Path = HERE) -> subprocess.CompletedProcess:
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    return subprocess.run(["scarb", "--profile", PROFILE, *args], cwd=str(cwd), capture_output=True, text=True, env=env)


def build() -> None:
    p = scarb(["build"])
    if p.returncode != 0:
        raise SystemExit(p.stdout + p.stderr)


def run(op: int, n: int) -> dict[str, int]:
    global RUNNER
    if NATIVE_RUNNER:
        if RUNNER is None:
            RUNNER = subprocess.Popen([NATIVE_RUNNER, str(HERE / "target" / PROFILE / "doom_game_bench.executable.json")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        RUNNER.stdin.write(f"{op:x} {n:x}\n")
        RUNNER.stdin.flush()
        line = RUNNER.stdout.readline()
        if not line: raise RuntimeError("native benchmark stopped")
        return {"steps": int(line.split()[0])}
    p = scarb(
        ["execute", "--no-build", "--output", "none", "--print-resource-usage", "--arguments",
         "%d,%d" % (op, n)]
    )
    if p.returncode != 0:
        raise SystemExit("execute(op=%d, n=%d) failed:\n%s\n%s" % (op, n, p.stdout, p.stderr))
    out: dict[str, int] = {}
    for line in p.stdout.splitlines():
        m = RE_RESOURCE.match(line)
        if m:
            out[m.group(1).strip()] = int(m.group(2).replace(",", ""))
    if "steps" not in out:
        raise SystemExit("no step count in:\n" + p.stdout)
    return out


def measure(op: int, n: int) -> tuple[float, float | None]:
    lo, hi = run(op, n), run(op, 2 * n)
    steps = (hi["steps"] - lo["steps"]) / n
    rc = None if NATIVE_RUNNER else (hi.get("range_check_builtin", 0) - lo.get("range_check_builtin", 0)) / n
    return steps, rc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json")
    ap.add_argument("--update", action="store_true")
    ap.add_argument("-n", type=int)
    args = ap.parse_args()
    budgets = json.loads((HERE / "budgets.json").read_text())
    iters = args.n or budgets.get("iterations", 4)
    build()
    cache: dict[int, tuple[float, float]] = {}

    def cost(op: int) -> tuple[float, float]:
        if op not in cache:
            cache[op] = measure(op, iters)
        return cache[op]

    results = []
    failures = []
    for entry in budgets["operations"]:
        steps, rc = cost(entry["op"])
        base_op = entry.get("base", (entry["op"] // 10) * 10)
        base, base_rc = cost(base_op)
        net = round(steps - base, 1)
        rc = None if rc is None or base_rc is None else round(rc - base_rc, 1)
        results.append(dict(name=entry["name"], op=entry["op"], net=net, range_checks=rc,
                            budget=entry["budget"]))
        flag = ""
        if entry["budget"] and net > entry["budget"] * TOLERANCE:
            flag = "  REGRESSION (%s)" % entry["budget"]
            failures.append(entry["name"])
        rc_text = "n/a" if rc is None else "%.1f" % rc
        print("%-52s net %10.1f steps  rc %8s%s" % (entry["name"], net, rc_text, flag))
    print("\nD2 budget: %d steps/tic mean, 25 000 p99" % D2_STEPS_PER_TIC)
    if args.update:
        for entry, res in zip(budgets["operations"], results):
            entry["budget"] = int(round(res["net"]))
        (HERE / "budgets.json").write_text(json.dumps(budgets, indent=2) + "\n")
        print("budgets.json updated")
        return 0
    if args.json:
        Path(args.json).write_text(json.dumps(dict(operations=results), indent=2) + "\n")
    if failures:
        print("\nFAIL: over budget (+10 %%): %s" % ", ".join(failures))
        return 1
    print("\nOK: every operation is within its recorded limit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

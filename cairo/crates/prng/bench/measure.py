#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Step-budget test driver (PLAN.md §3.1, rule 4, "budget de steps").

Method
------
`scarb execute --print-resource-usage` reports the exact Cairo VM step count
of one run. A single run also contains fixed costs (bootstrap, table
construction, argument/return serialization), so a *differential*
measurement is used, exactly as in spike S1:

    cost_per_iteration(op) = (steps(op, 2N) - steps(op, N)) / N

Every fixed cost cancels. The bare loop (`op = 0`) is measured the same way
and subtracted, giving the *net* cost of the operation under test. The
numbers are exact integers (no timing, no noise): two runs of the same
binary always report the same step count, so this is a deterministic CI
test, not a benchmark.

Usage
-----
    python3 measure.py [--json out.json]

Reads `budget.json` next to this script:

    {"package": "prng_bench",
     "ops": [{"op": 1, "label": "next(table)", "n1": 1000, "n2": 2000,
              "budget": 15}]}

`budget` is the maximum *net* steps allowed; the script exits non-zero when
an operation exceeds it. `op` 0 is always the bare-loop baseline.
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
RESOURCE_RE = re.compile(r"^\s*([a-z_0-9 ]+):\s*([0-9,]+)\s*$")
ENV = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")


def scarb(args: list[str]) -> subprocess.CompletedProcess:
    proc = subprocess.run(
        ["scarb"] + args, cwd=str(HERE), capture_output=True, text=True, env=ENV
    )
    if proc.returncode != 0:
        sys.exit(f"scarb {' '.join(args)} failed:\n{proc.stdout}\n{proc.stderr}")
    return proc


def steps(op: int, n: int) -> int:
    proc = scarb(
        [
            "execute",
            "--no-build",
            "--output",
            "none",
            "--print-resource-usage",
            "--arguments",
            f"{op},{n}",
        ]
    )
    for line in proc.stdout.splitlines():
        match = RESOURCE_RE.match(line)
        if match and match.group(1).strip() == "steps":
            return int(match.group(2).replace(",", ""))
    sys.exit("no step count in `scarb execute` output:\n" + proc.stdout)


def per_iteration(op: int, n1: int, n2: int) -> float:
    return (steps(op, n2) - steps(op, n1)) / (n2 - n1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", help="write the measured costs to this file")
    args = parser.parse_args()

    config = json.loads((HERE / "budget.json").read_text())
    scarb(["build"])

    baseline_cfg = config.get("baseline", {"n1": 1000, "n2": 2000})
    baseline = per_iteration(0, baseline_cfg["n1"], baseline_cfg["n2"])
    print(f"bare loop: {baseline:.2f} steps/iteration (subtracted below)\n")
    print(f"{'operation':<38}{'gross':>9}{'net':>9}{'budget':>9}  verdict")

    results = {"baseline": baseline, "ops": []}
    failed = False
    for entry in config["ops"]:
        gross = per_iteration(entry["op"], entry["n1"], entry["n2"])
        net = gross - baseline
        over = entry.get("budget") is not None and net > entry["budget"]
        failed = failed or over
        results["ops"].append(
            {"label": entry["label"], "gross": gross, "net": net,
             "budget": entry.get("budget"), "over_budget": over}
        )
        budget = "-" if entry.get("budget") is None else str(entry["budget"])
        print(
            f"{entry['label']:<38}{gross:>9.2f}{net:>9.2f}{budget:>9}"
            f"  {'OVER BUDGET' if over else 'ok'}"
        )

    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2) + "\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

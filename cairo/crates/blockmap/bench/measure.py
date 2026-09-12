#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Step-cost measurement and budget check for one crate's `bench` package.

Method (S1 §3.1, "differential rather than absolute"): every operation is run
twice, with `n` and `2n` iterations, and the per-iteration cost is

    cost = (steps(2n) - steps(n)) / n

so that bootstrap, argument deserialization and output serialization cancel
exactly. `op = 0` is the bare loop; an operation's `net` cost subtracts the
cost of its **baseline op** -- the one that builds the same operands and does
nothing else (`base` in budgets.json, default 0, the bare loop). Baselines
matter: with loop-invariant operands the compiler hoists the whole call out
of the loop and the measurement is meaningless, so every bench varies its
operands with the loop counter and pays for that in the baseline too.

The script also reports the **bytecode size** of the benchmark executable
(S1 §5.9: since S0 the bootloader re-hashes the program every segment at
`2340 + 14.7 x words` steps, so program size is a per-tic budget too).

Usage:
    python3 measure.py            # measure, print the table, check budgets
    python3 measure.py --json out.json
    python3 measure.py --update   # rewrite budgets.json with what was measured

Exit code 1 if any operation exceeds its budget by more than 10 % (the
per-crate step-budget test required by PLAN.md §3.1, rule 4).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RE_RESOURCE = re.compile(r"^\s*([a-z_0-9 ]+):\s*([0-9,]+)\s*$")
TOLERANCE = 1.10


def scarb(args: list[str]) -> subprocess.CompletedProcess:
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    return subprocess.run(["scarb", *args], cwd=str(HERE), capture_output=True,
                          text=True, env=env)


def build() -> None:
    p = scarb(["build"])
    if p.returncode != 0:
        raise SystemExit(p.stdout + p.stderr)


def bytecode_words() -> int:
    """Number of felts of compiled bytecode of the benchmark executable."""
    candidates = sorted((HERE / "target" / "dev").glob("*.executable.json"))
    if not candidates:
        return 0
    program = json.loads(candidates[0].read_text())
    return len(program["program"]["bytecode"])


def run(op: int, n: int) -> dict[str, int]:
    p = scarb(["execute", "--no-build", "--output", "none", "--print-resource-usage",
               "--arguments", "%d,%d" % (op, n)])
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


def measure(op: int, n: int = 200) -> tuple[float, float]:
    lo, hi = run(op, n), run(op, 2 * n)
    steps = (hi["steps"] - lo["steps"]) / n
    rc = (hi.get("range_check_builtin", 0) - lo.get("range_check_builtin", 0)) / n
    return steps, rc


def main() -> int:
    budgets = json.loads((HERE / "budgets.json").read_text())
    build()
    words = bytecode_words()
    cache: dict[int, tuple[float, float]] = {}

    def cost(op: int) -> tuple[float, float]:
        if op not in cache:
            cache[op] = measure(op)
        return cache[op]

    loop, _ = cost(0)
    results = []
    failures = []
    for entry in budgets["operations"]:
        steps, rc = cost(entry["op"])
        base, base_rc = cost(entry.get("base", 0))
        net = round(steps - base, 2)
        rc = round(rc - base_rc, 2)
        results.append(dict(name=entry["name"], op=entry["op"], base=entry.get("base", 0),
                            steps=round(steps, 2), net=net, range_checks=rc,
                            budget=entry["budget"]))
        flag = ""
        if entry["budget"] and net > entry["budget"] * TOLERANCE:
            flag = "  OVER BUDGET (%s)" % entry["budget"]
            failures.append(entry["name"])
        print("%-34s net %8.2f steps  rc %6.2f%s" % (entry["name"], net, rc, flag))
    print("\nbare loop: %.2f steps/iteration" % loop)
    print("bytecode:  %d words (bench executable, crate included)" % words)

    word_budget = budgets.get("bytecode_words", 0)
    if word_budget and words > word_budget * TOLERANCE:
        print("  OVER BUDGET (%d words)" % word_budget)
        failures.append("bytecode_words")

    if "--update" in sys.argv:
        for entry, res in zip(budgets["operations"], results):
            entry["budget"] = int(round(res["net"]))
        budgets["bytecode_words"] = words
        (HERE / "budgets.json").write_text(json.dumps(budgets, indent=2) + "\n")
        print("budgets.json updated")
        return 0

    if "--json" in sys.argv:
        out = Path(sys.argv[sys.argv.index("--json") + 1])
        out.write_text(json.dumps(dict(loop_overhead=loop, bytecode_words=words,
                                       operations=results), indent=2) + "\n")

    if failures:
        print("\nFAIL: over budget (+10 %%): %s" % ", ".join(failures))
        return 1
    print("OK: every operation is within its documented budget (+10 %).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

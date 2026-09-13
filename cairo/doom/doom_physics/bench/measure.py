#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Step-cost and bytecode-budget test for `doom_physics`.

Two measurements, both required by PLAN.md §3.1 rule 7:

1. **Steps.** Differential measurement (S1 §3.1): every operation runs with
   `n` and `2n` iterations on the real Freedoom E1M1, so bootstrap and
   (de)serialization cancel, and an operation's `net` cost subtracts its
   baseline op -- the one that builds the same operands (a varying player
   record, linked or not) and does nothing else. Fails at +10 % over
   `budgets.json`.

2. **Bytecode words.** `bench/size/` calls every public entry point once on
   the loaded level; `bench/baseline/` loads and touches the same level and
   table data and calls none of them. The difference is what this crate's
   code costs in the program the bootloader re-hashes every segment
   (`2 340 + 14.7 x words` steps, S1 §5.9). It is measured twice: with the
   default features and without `vanilla_slide` (P_SlideMove's traces out,
   the stairstep alone). docs/DECISIONS.md D23 budgets 12 000 words of code
   for the whole core; docs/spikes/S7.md brought this crate from ~57 000 to
   the figures in `budgets.json` and explains why the rest is the price of
   the algorithm under Cairo 2.16's code generation, so the check here
   guards the *measured* figures against regression (+10 %) and prints the
   S7 target (12 000) for the record. `attribute.py` says where every word
   goes.

Usage:
    python3 measure.py            # measure, print the table, check budgets
    python3 measure.py --json out.json
    python3 measure.py --update   # re-baseline budgets.json
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SIZE = HERE / "size"
BASELINE = HERE / "baseline"
RE_RESOURCE = re.compile(r"^\s*([a-z_0-9 ]+):\s*([0-9,]+)\s*$")
TOLERANCE = 1.10
S7_CODE_WORDS = 12000  # docs/spikes/S7.md: the target set for this crate
BOOTLOADER_PER_WORD = 14.7  # S1 §5.9 / S0 §5.2
BOOTLOADER_FIXED = 2340


def scarb(args: list[str], cwd: Path = HERE) -> subprocess.CompletedProcess:
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    return subprocess.run(
        ["scarb", *args], cwd=str(cwd), capture_output=True, text=True, env=env
    )


def build(cwd: Path, *flags: str) -> None:
    p = scarb(["build", *flags], cwd)
    if p.returncode != 0:
        raise SystemExit(p.stdout + p.stderr)


def bytecode_words(cwd: Path) -> int:
    candidates = sorted((cwd / "target" / "dev").glob("*.executable.json"))
    if not candidates:
        raise SystemExit("no executable built in %s" % cwd)
    program = json.loads(candidates[0].read_text())
    return len(program["program"]["bytecode"])


def run(op: int, n: int) -> dict[str, int]:
    p = scarb(
        [
            "execute",
            "--no-build",
            "--output",
            "none",
            "--print-resource-usage",
            "--arguments",
            "%d,%d" % (op, n),
        ]
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


def measure(op: int, n: int = 40) -> tuple[float, float]:
    lo, hi = run(op, n), run(op, 2 * n)
    steps = (hi["steps"] - lo["steps"]) / n
    rc = (hi.get("range_check_builtin", 0) - lo.get("range_check_builtin", 0)) / n
    return steps, rc


def main() -> int:
    budgets = json.loads((HERE / "budgets.json").read_text())

    build(HERE)
    build(BASELINE)
    base_words = bytecode_words(BASELINE)
    build(SIZE, "--no-default-features")
    lite_words = bytecode_words(SIZE) - base_words
    build(SIZE)
    bench_words = bytecode_words(HERE)
    words = bytecode_words(SIZE)
    code_words = words - base_words

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
        results.append(
            dict(
                name=entry["name"],
                op=entry["op"],
                base=entry.get("base", 0),
                steps=round(steps, 2),
                net=net,
                range_checks=rc,
                budget=entry["budget"],
            )
        )
        flag = ""
        if entry["budget"] and net > entry["budget"] * TOLERANCE:
            flag = "  OVER BUDGET (%s)" % entry["budget"]
            failures.append(entry["name"])
        print("%-44s net %9.2f steps  rc %7.2f%s" % (entry["name"], net, rc, flag))
    print("\nbare loop: %.2f steps/iteration" % loop)
    print(
        "\nbytecode: %d words (bench/size) - %d (bench/baseline, same crate graph"
        "\n          and data, no physics call) = %d words of doom_physics code"
        % (words, base_words, code_words)
    )
    print(
        "          bootloader program-hashing: %d steps/segment for this code"
        % round(BOOTLOADER_FIXED + BOOTLOADER_PER_WORD * code_words)
    )
    print("          without vanilla_slide: %d words" % lite_words)
    print("          (the step benchmark itself compiles to %d words)" % bench_words)
    print("          S7 target for this crate: %d words" % S7_CODE_WORDS)
    baselined = budgets.get("code_words", 0)
    if baselined and code_words > baselined * TOLERANCE:
        print("  REGRESSION (+10 %% over the %d words of budgets.json)" % baselined)
        failures.append("code_words")
    baselined_lite = budgets.get("code_words_lite", 0)
    if baselined_lite and lite_words > baselined_lite * TOLERANCE:
        print("  REGRESSION (+10 %% over the %d lite words of budgets.json)" % baselined_lite)
        failures.append("code_words_lite")

    if "--update" in sys.argv:
        for entry, res in zip(budgets["operations"], results):
            entry["budget"] = int(round(res["net"]))
        budgets["code_words"] = code_words
        budgets["code_words_lite"] = lite_words
        (HERE / "budgets.json").write_text(json.dumps(budgets, indent=2) + "\n")
        print("budgets.json updated")
        return 0

    if "--json" in sys.argv:
        out = Path(sys.argv[sys.argv.index("--json") + 1])
        out.write_text(
            json.dumps(
                dict(
                    loop_overhead=loop,
                    bytecode_words=words,
                    step_bench_words=bench_words,
                    baseline_words=base_words,
                    code_words=code_words,
                    code_words_lite=lite_words,
                    operations=results,
                ),
                indent=2,
            )
            + "\n"
        )

    if failures:
        print("\nFAIL: over budget (+10 %%): %s" % ", ".join(failures))
        return 1
    print("\nOK: every operation and the code budget are within their documented limits.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

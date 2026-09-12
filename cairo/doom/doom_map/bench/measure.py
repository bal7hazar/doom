#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Step-cost and bytecode-budget test for `doom_map`.

Two measurements, both required by PLAN.md §3.1 rule 7 ("every crate declares
two budgets"):

1. **Steps.** Differential measurement (S1 §3.1): every operation runs with
   `n` and `2n` iterations, so bootstrap and (de)serialization cancel, and an
   operation's `net` cost subtracts its baseline op -- the one that builds the
   same operands and does nothing else. Fails at +10 % over `budgets.json`.

2. **Bytecode words.** `bench/size/` loads the level and references every
   generated `const` array and nothing else; `bench/baseline/` has the same
   crate graph and touches none of them. The difference between the two
   `.executable.json` bytecode lengths is what the compiled-in level data
   costs, which by S1 §5.9 is `2 340 + 14.7 x words` steps of bootloader
   program-hashing **per proof segment**. (The step benchmark itself is not
   usable for this: its 23 measurement loops each carry a 24-field `LevelMap`
   and add ~9 500 words of their own.) The budget is
   docs/G0.md D4's revised **20 000 words for data**; the script also prints
   the per-array table from `manifest.json` (written by
   `../scripts/gen_level.py`) and checks that the analytic total and the
   measured delta agree.

Usage:
    python3 measure.py            # measure, print the tables, check budgets
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
DATA_WORD_BUDGET = 20000  # docs/G0.md D4 (revised): data <= 20 k, code <= 12 k
BOOTLOADER_PER_WORD = 14.7  # S1 §5.9 / S0 §5.2
BOOTLOADER_FIXED = 2340
GLUE_PER_ARRAY = 40  # fixed `span()` cost of one `const` array, measured


def scarb(args: list[str], cwd: Path = HERE) -> subprocess.CompletedProcess:
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    return subprocess.run(
        ["scarb", *args], cwd=str(cwd), capture_output=True, text=True, env=env
    )


def build(cwd: Path) -> None:
    p = scarb(["build"], cwd)
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


def measure(op: int, n: int = 200) -> tuple[float, float]:
    lo, hi = run(op, n), run(op, 2 * n)
    steps = (hi["steps"] - lo["steps"]) / n
    rc = (hi.get("range_check_builtin", 0) - lo.get("range_check_builtin", 0)) / n
    return steps, rc


def print_manifest(manifest: dict) -> None:
    print("\nLevel data, one bytecode word per `const` element (S1 §5.9):\n")
    print("%-16s %-18s %-7s %8s" % ("array", "group", "layout", "words"))
    for a in sorted(manifest["arrays"], key=lambda x: -x["words"]):
        print("%-16s %-18s %-7s %8d" % (a["name"], a["group"], a["layout"], a["words"]))
    print("%-16s %-18s %-7s %8d" % ("(scalars)", "scalar", "-", manifest["scalars"]))
    print("%-16s %-18s %-7s %8d" % ("TOTAL", "", "", manifest["total_words"]))


def main() -> int:
    budgets = json.loads((HERE / "budgets.json").read_text())
    manifest = json.loads((HERE / "manifest.json").read_text())

    build(HERE)
    build(SIZE)
    build(BASELINE)
    bench_words = bytecode_words(HERE)
    words = bytecode_words(SIZE)
    base_words = bytecode_words(BASELINE)
    data_words = words - base_words

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
        print("%-38s net %8.2f steps  rc %6.2f%s" % (entry["name"], net, rc, flag))
    print("\nbare loop: %.2f steps/iteration" % loop)

    print_manifest(manifest)
    print(
        "\nbytecode: %d words (bench/size) - %d (bench/baseline, same crate"
        "\n          graph, no generated array) = %d words of level data"
        % (words, base_words, data_words)
    )
    print(
        "          analytic total from manifest.json: %d words (delta - analytic = %+d)"
        % (manifest["total_words"], data_words - manifest["total_words"])
    )
    print(
        "          bootloader program-hashing: %d steps/segment for the data alone"
        % round(BOOTLOADER_FIXED + BOOTLOADER_PER_WORD * data_words)
    )
    print("          (the step benchmark itself compiles to %d words)" % bench_words)

    if data_words > DATA_WORD_BUDGET:
        print("  OVER BUDGET (%d words of data, docs/G0.md D4)" % DATA_WORD_BUDGET)
        failures.append("data_words")
    # The measured delta must not drift from the analytic count: a gap means
    # an array was dead-code-eliminated (the probe no longer touches it) or
    # the emitter stopped costing one word per element. The allowance is
    # 5 % plus `GLUE_PER_ARRAY` words per array, because a `const` array costs
    # 1.00 word per element *plus* a fixed ~35 words of `span()` glue
    # (measured on a synthetic 1 000-element array: 112 words empty,
    # 1 147 with the array).
    arrays = manifest.get("array_count", len(manifest["arrays"]))
    allowance = 0.05 * manifest["total_words"] + GLUE_PER_ARRAY * arrays
    if abs(data_words - manifest["total_words"]) > allowance:
        print("  MISMATCH between the measured delta and manifest.json")
        failures.append("manifest_drift")

    if "--update" in sys.argv:
        for entry, res in zip(budgets["operations"], results):
            entry["budget"] = int(round(res["net"]))
        budgets["data_words"] = data_words
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
                    data_words=data_words,
                    operations=results,
                ),
                indent=2,
            )
            + "\n"
        )

    if failures:
        print("\nFAIL: over budget (+10 %%): %s" % ", ".join(failures))
        return 1
    print("\nOK: every operation and the data budget are within their documented limits.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

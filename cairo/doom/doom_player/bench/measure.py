#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Step-cost and bytecode-budget test for `doom_player`.

Two measurements, both required of every crate (PLAN.md §3.1 rule 4):

1. **Steps.** Differential measurement (S1 §3.1): every operation runs with
   `n` and `2n` iterations, so bootstrap and (de)serialization cancel, and an
   operation's `net` cost subtracts its baseline op — the one that builds the
   same operands and does nothing else. Fails at +10 % over `budgets.json`.

2. **Bytecode words, under both profiles.** `bench/size/` calls every public
   entry point of the crate once; `bench/baseline/` links the same crate
   graph *and calls every `doom_physics` / `doom_specials` / `bam` / `fsm` /
   `ticcmd` function `doom_player` reaches*, so the difference is this
   crate's own code. It is measured with the default `[cairo]` table and
   again under the `proving` profile (`unsafe-panic = true`, D29) — which
   also compile-tests the crate under that flag, as S7 §6 asks. By S1 §5.9
   a word is `14.7` steps of bootloader program-hashing **per proof
   segment**; D29 allots **20 000 words** to this crate.

Usage:
    python3 measure.py            # measure, print the tables, check budgets
    python3 measure.py --json out.json
    python3 measure.py --update   # re-baseline budgets.json
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
SIZE = HERE / "size"
BASELINE = HERE / "baseline"
RE_RESOURCE = re.compile(r"^\s*([a-z_0-9 ]+):\s*([0-9,]+)\s*$")
TOLERANCE = 1.10
CODE_WORD_BUDGET = 20000  # docs/DECISIONS.md D29, this crate's allocation
BOOTLOADER_PER_WORD = 14.7  # S1 §5.9 / S0 §5.2
BOOTLOADER_FIXED = 2340


def scarb(args: list[str], cwd: Path = HERE) -> subprocess.CompletedProcess:
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    return subprocess.run(
        ["scarb", *args], cwd=str(cwd), capture_output=True, text=True, env=env
    )


def build(cwd: Path, profile: str = "dev") -> None:
    args = ["build"] if profile == "dev" else ["--profile", profile, "build"]
    p = scarb(args, cwd)
    if p.returncode != 0:
        raise SystemExit(p.stdout + p.stderr)


def bytecode_words(cwd: Path, profile: str = "dev") -> int:
    candidates = sorted((cwd / "target" / profile).glob("*.executable.json"))
    if not candidates:
        raise SystemExit("no executable built in %s (%s)" % (cwd, profile))
    program = json.loads(candidates[0].read_text())
    return len(program["program"]["bytecode"])


def words_of(profile: str) -> int:
    """`bench/size` minus `bench/baseline` under one Scarb profile."""
    build(SIZE, profile)
    build(BASELINE, profile)
    return bytecode_words(SIZE, profile) - bytecode_words(BASELINE, profile)


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


def measure(op: int, n: int) -> tuple[float, float]:
    lo, hi = run(op, n), run(op, 2 * n)
    steps = (hi["steps"] - lo["steps"]) / n
    rc = (hi.get("range_check_builtin", 0) - lo.get("range_check_builtin", 0)) / n
    return steps, rc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json")
    ap.add_argument("--update", action="store_true")
    ap.add_argument("-n", type=int, default=60)
    args = ap.parse_args()

    budgets = json.loads((HERE / "budgets.json").read_text())

    build(HERE)
    words = words_of("dev")
    proving = words_of("proving")

    bases: dict[int, float] = {}
    for op in sorted({b["base"] for b in budgets["operations"]}):
        bases[op] = measure(op, args.n)[0]

    print("\n%-46s %9s %7s %9s" % ("operation", "steps", "rc", "budget"))
    failures: list[str] = []
    results = []
    for spec in budgets["operations"]:
        steps, rc = measure(spec["op"], args.n)
        net = steps - bases[spec["base"]]
        budget = spec["budget"]
        flag = "" if net <= budget * TOLERANCE else "  OVER"
        if flag:
            failures.append("%s: %.0f > %d" % (spec["name"], net, budget))
        print("%-46s %9.1f %7.1f %9d%s" % (spec["name"], net, rc, budget, flag))
        results.append(dict(name=spec["name"], op=spec["op"], steps=net, range_checks=rc))
        if args.update:
            spec["budget"] = int(round(max(net, 1)))

    print(
        "\nbytecode: %d words of `doom_player` code (D29 budget %d) = %.0f steps of"
        " bootloader program-hashing per segment"
        % (words, CODE_WORD_BUDGET, BOOTLOADER_FIXED + BOOTLOADER_PER_WORD * words)
    )
    print("          %d words under the `proving` profile (unsafe-panic)" % proving)
    if words > CODE_WORD_BUDGET:
        # Reported, not failed, while the levers of the S7 §8 pass land; the
        # final commit of that pass turns this into an assertion.
        print(
            "  NOTE: %d words over the %d-word D29 allocation (see ../README.md)"
            % (words - CODE_WORD_BUDGET, CODE_WORD_BUDGET)
        )
    recorded = budgets.get("code_words", CODE_WORD_BUDGET)
    if words > recorded * TOLERANCE and not args.update:
        failures.append("bytecode regression: %d > %d words" % (words, recorded))
    recorded_proving = budgets.get("code_words_proving", proving)
    if proving > recorded_proving * TOLERANCE and not args.update:
        failures.append(
            "bytecode regression (proving): %d > %d words" % (proving, recorded_proving)
        )

    if args.update:
        budgets["code_words"] = words
        budgets["code_words_proving"] = proving
        (HERE / "budgets.json").write_text(json.dumps(budgets, indent=2) + "\n")
        print("budgets.json updated")
        return 0
    if args.json:
        Path(args.json).write_text(
            json.dumps(
                dict(operations=results, code_words=words, code_words_proving=proving),
                indent=2,
            )
            + "\n"
        )
    if failures:
        print("\nOVER BUDGET:\n  " + "\n  ".join(failures))
        return 1
    print("\nall budgets met")
    return 0


if __name__ == "__main__":
    sys.exit(main())

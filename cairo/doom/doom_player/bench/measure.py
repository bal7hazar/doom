#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Step-cost and bytecode-budget test for `doom_player`.

Two measurements, both required of every crate (PLAN.md §3.1 rule 4):

1. **Steps.** Differential measurement (S1 §3.1): every operation runs with
   `n` and `2n` iterations, so bootstrap and (de)serialization cancel, and an
   operation's `net` cost subtracts its baseline op — the one that builds the
   same operands and does nothing else. Fails at +10 % over `budgets.json`.

2. **Bytecode words, under both profiles.** Report both the historical
   `bench/size` minus `bench/baseline` difference and exact player-source
   attribution from the annotated Sierra/CASM offsets. The difference also
   includes harness call sites and dependency-code differences and is not
   identical to the crate's source contribution. The D29 guard is strictly
   20 000 player-source words in the proving profile, with no tolerance;
   inlined player wrappers count at their consumer call sites. The all-API
   difference keeps its separate regression guard and is printed even when
   it exceeds 20 000. An optional annotated proving-profile consumer Sierra
   checks the actual doom_game/doom_run linkage against the same hard limit.

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
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SIZE = HERE / "size"
BASELINE = HERE / "baseline"
RE_RESOURCE = re.compile(r"^\s*([a-z_0-9 ]+):\s*([0-9,]+)\s*$")
TOLERANCE = 1.10
CODE_WORD_BUDGET = 20000  # docs/DECISIONS.md D29, this crate's allocation


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


def attributed_words(profile: str, sierra: Path | None = None) -> int:
    """Exact player source attribution, including wrappers inlined in callers."""
    with tempfile.TemporaryDirectory(prefix="doom-player-words-") as tmp:
        report = Path(tmp) / "words.json"
        cmd = [sys.executable, str(HERE / "attribute.py"), "--top", "0", "--json", str(report)]
        cmd += ["--sierra", str(sierra)] if sierra else ["--profile", profile]
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode:
            raise SystemExit(p.stdout + p.stderr)
        return json.loads(report.read_text())["crate_words"]


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
    ap.add_argument("--consumer-sierra", type=Path, help="annotated proving-profile consumer Sierra to check against D29 too")
    ap.add_argument("--update", action="store_true")
    ap.add_argument("-n", type=int, default=60)
    args = ap.parse_args()

    budgets = json.loads((HERE / "budgets.json").read_text())

    build(HERE)
    words = words_of("dev")
    proving = words_of("proving")
    player_words = attributed_words("dev")
    player_proving = attributed_words("proving")
    consumer_words = attributed_words("proving", args.consumer_sierra) if args.consumer_sierra else None

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

    print("\nbytecode size - baseline: %d words dev / %d proving" % (words, proving))
    print("player source attribution: %d words dev / %d proving (D29 hard limit %d)"
          % (player_words, player_proving, CODE_WORD_BUDGET))
    if proving > CODE_WORD_BUDGET:
        print("  NOTE: the all-API size-minus-baseline difference exceeds 20 000 by %d words;"
              " it includes harness/dependency differences (see ../README.md)." % (proving - CODE_WORD_BUDGET))
    if player_proving > CODE_WORD_BUDGET:
        failures.append("D29 player source: %d > %d proving words" % (player_proving, CODE_WORD_BUDGET))
    if consumer_words is not None:
        print("consumer player source attribution: %d proving words" % consumer_words)
        if consumer_words > CODE_WORD_BUDGET:
            failures.append("D29 consumer player source: %d > %d proving words" % (consumer_words, CODE_WORD_BUDGET))
    recorded = budgets.get("code_words", CODE_WORD_BUDGET)
    if words > recorded * TOLERANCE and not args.update:
        failures.append("bytecode regression: %d > %d words" % (words, recorded))
    recorded_proving = budgets.get("code_words_proving", proving)
    if proving > recorded_proving * TOLERANCE and not args.update:
        failures.append(
            "bytecode regression (proving): %d > %d words" % (proving, recorded_proving)
        )

    if args.update and not failures:
        budgets["code_words"] = words
        budgets["code_words_proving"] = proving
        budgets["player_words"] = player_words
        budgets["player_words_proving"] = player_proving
        (HERE / "budgets.json").write_text(json.dumps(budgets, indent=2) + "\n")
        print("budgets.json updated")
        return 0
    if args.json:
        Path(args.json).write_text(
            json.dumps(
                dict(operations=results, code_words=words, code_words_proving=proving,
                     player_words=player_words, player_words_proving=player_proving,
                     consumer_player_words_proving=consumer_words),
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

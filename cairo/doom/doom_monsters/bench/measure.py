#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Step-cost and bytecode-budget test for `doom_monsters`.

Two measurements, both required by PLAN.md §3.1 rule 4:

1. **Steps.** Differential measurement (S1 §3.1): every operation runs with
   `n` and `2n` iterations on the real Freedoom E1M1, so bootstrap and
   (de)serialization cancel, and an operation's `net` cost subtracts the
   baseline op that builds the same operands. Each iteration of a ticker op
   is one real tic (`tic = i`) of a scene built once before the loop, so the
   number printed is what a tic of that scene costs in a run. Fails at +10 %
   over `budgets.json`.

2. **Bytecode words.** `bench/size/` calls the crate's entry points once;
   `bench/baseline/` is the same package with the same level data **and the
   same `doom_physics` calls**, and no `doom_monsters` call. The difference
   is therefore this crate's own code — not the 36 000 words of physics
   underneath it. The bootloader re-hashes the whole program every segment
   (`2 340 + 14.7 x words` steps, S1 §5.9).

   Four figures, because two axes matter (docs/spikes/S7.md §6,
   docs/DECISIONS.md D29):

   * `full_api` (default) calls the **whole public surface**, sixteen entry
     points that each take the 72-felt `Ctx` and the actor by `ref`;
     `--no-default-features` calls **the ticker alone**, which is what
     `doom_game` calls and therefore what reaches the proved program;
   * the `dev` profile against the **`proving`** profile, whose
     `unsafe-panic = true` turns a panic into an unprovable-anyway trap
     (R4-A2). Building under it is also the compile test S7 §6 asks for.

   **D29 budgets this crate at 15 000 words**, and the figure it is about is
   the ticker alone under `proving`; the check below fails at +10 % over it,
   and every one of the four figures is guarded against regression.

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
D29_CODE_WORDS = 15000  # docs/DECISIONS.md D29: this crate's share of the 100 k
D2_STEPS_PER_TIC = 12000  # docs/G0.md D2
BOOTLOADER_PER_WORD = 14.7  # S1 §5.9 / S0 §5.2
BOOTLOADER_FIXED = 2340


def scarb(args: list[str], cwd: Path = HERE) -> subprocess.CompletedProcess:
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    return subprocess.run(
        ["scarb", *args], cwd=str(cwd), capture_output=True, text=True, env=env
    )


def build(cwd: Path, profile: str = "dev", *flags: str) -> None:
    p = scarb(["--profile", profile, "build", *flags], cwd)
    if p.returncode != 0:
        raise SystemExit(p.stdout + p.stderr)


def bytecode_words(cwd: Path, profile: str = "dev") -> int:
    candidates = sorted((cwd / "target" / profile).glob("*.executable.json"))
    if not candidates:
        raise SystemExit("no executable built in %s (%s)" % (cwd, profile))
    program = json.loads(candidates[0].read_text())
    return len(program["program"]["bytecode"])


def size_of(profile: str, *flags: str) -> int:
    """Words of `doom_monsters` code under `profile`, with these size flags."""
    build(BASELINE, profile)
    build(SIZE, profile, *flags)
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
    budgets = json.loads((HERE / "budgets.json").read_text())
    iters = budgets.get("iterations", 20)

    build(HERE)
    # The four bytecode figures, then the step bench's own executable.
    game_proving = size_of("proving", "--no-default-features")
    full_proving = size_of("proving")
    game_words = size_of("dev", "--no-default-features")
    build(SIZE)
    build(BASELINE)
    base_words = bytecode_words(BASELINE)
    words = bytecode_words(SIZE)
    code_words = words - base_words
    bench_words = bytecode_words(HERE)

    cache: dict[int, tuple[float, float]] = {}

    def cost(op: int) -> tuple[float, float]:
        if op not in cache:
            cache[op] = measure(op, iters)
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
                task_budget=entry.get("task_budget"),
            )
        )
        flag = ""
        if entry["budget"] and net > entry["budget"] * TOLERANCE:
            flag = "  REGRESSION (%s)" % entry["budget"]
            failures.append(entry["name"])
        task = entry.get("task_budget")
        if task and net > task:
            flag += "  [over the task budget of %d]" % task
        print("%-46s net %9.2f steps  rc %7.2f%s" % (entry["name"], net, rc, flag))
    print("\nbare loop: %.2f steps/iteration" % loop)
    print("D2 budget: %d steps/tic for the whole simulation" % D2_STEPS_PER_TIC)
    print(
        "\nbytecode: bench/size - bench/baseline (same crate graph, same data and"
        "\n          the same doom_physics calls) = words of doom_monsters code:"
    )
    print("%42s  %8s  %8s" % ("", "dev", "proving"))
    print("%42s  %8d  %8d" % ("whole public surface", code_words, full_proving))
    print("%42s  %8d  %8d" % ("the ticker alone (what doom_game links)", game_words, game_proving))
    print(
        "          the boundary (16 entry points taking a 72-felt Ctx and the"
        "\n          actor by ref) is the difference: %d words on dev, %d on proving"
        % (code_words - game_words, full_proving - game_proving)
    )
    print(
        "          bootloader program-hashing of the proved figure: %d steps/segment"
        % round(BOOTLOADER_FIXED + BOOTLOADER_PER_WORD * game_proving)
    )
    print("          (the step benchmark itself compiles to %d words)" % bench_words)
    print("          D29 budget for this crate: %d words" % D29_CODE_WORDS)
    if game_proving > D29_CODE_WORDS * TOLERANCE:
        print(
            "  OVER the D29 budget of %d words by %d (+10 %% tolerance)"
            % (D29_CODE_WORDS, game_proving - D29_CODE_WORDS)
        )
        failures.append("D29 budget")
    for key, value in (
        ("code_words", code_words),
        ("code_words_game", game_words),
        ("code_words_proving", full_proving),
        ("code_words_game_proving", game_proving),
    ):
        baselined = budgets.get(key, 0)
        if baselined and value > baselined * TOLERANCE:
            print("  REGRESSION (+10 %%): %s %d over the %d of budgets.json"
                  % (key, value, baselined))
            failures.append(key)

    if "--update" in sys.argv:
        for entry, res in zip(budgets["operations"], results):
            entry["budget"] = int(round(res["net"]))
        budgets["code_words"] = code_words
        budgets["code_words_game"] = game_words
        budgets["code_words_proving"] = full_proving
        budgets["code_words_game_proving"] = game_proving
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
                    code_words_game=game_words,
                    code_words_proving=full_proving,
                    code_words_game_proving=game_proving,
                    operations=results,
                ),
                indent=2,
            )
            + "\n"
        )

    if failures:
        print("\nFAIL: over budget (+10 %%): %s" % ", ".join(failures))
        return 1
    print("\nOK: every operation and the code budget are within their recorded limits.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

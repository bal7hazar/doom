#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Bytecode-size test of the proved program (docs/DECISIONS.md D29).

Builds `doom_run` under the `proving` profile (`unsafe-panic = true`, the
profile the bootloader hashes) and checks the `run_segment` executable
against the D29 budget: **100 000 words**, hard ceiling 120 000. Prints all
three executables in both profiles so the report has the numbers side by
side. Source annotations are for attribution; this tool tests executable
size and does not claim to compare annotated/unannotated compiler outputs.

    python3 size.py            # build, print, exit 1 over the budget
    python3 size.py --report   # print only, never fail
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[2]  # cairo/
BUDGET = 100_000
CEILING = 120_000


def scarb(args: list[str]) -> None:
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    p = subprocess.run(
        ["scarb", "--manifest-path", str(WORKSPACE / "Scarb.toml"), *args],
        capture_output=True,
        text=True,
        env=env,
    )
    if p.returncode != 0:
        raise SystemExit(p.stdout[-3000:] + p.stderr[-3000:])


def words(profile: str, name: str) -> int:
    path = WORKSPACE / "target" / profile / f"{name}.executable.json"
    return len(json.loads(path.read_text())["program"]["bytecode"])


def main() -> int:
    report_only = "--report" in sys.argv
    scarb(["build", "-p", "doom_run"])
    scarb(["--profile", "proving", "build", "-p", "doom_run"])
    print("%-14s %10s %10s" % ("executable", "dev", "proving"))
    table = {}
    for name in ("run_segment", "step_tic", "genesis"):
        table[name] = (words("dev", name), words("proving", name))
        print("%-14s %10d %10d" % (name, *table[name]))
    proved = table["run_segment"][1]
    print("\nProgram hashing uses Blake (D31); VM steps alone do not establish AIR/registry fit.")
    status = 0
    if proved > BUDGET:
        print("OVER the D29 budget of %d words by %d" % (BUDGET, proved - BUDGET))
        status = 1
    if proved > CEILING:
        print("OVER the D29 hard ceiling of %d words" % CEILING)
        status = 1
    if status == 0:
        print("within the D29 budget (%d)" % BUDGET)
    return 0 if report_only else status


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Line-coverage report for this crate (PLAN.md §3.1 rule 4, C7).

Why a copy of the crate
-----------------------
`cairo-coverage` only consumes traces from `snforge`, and `snforge` cannot
compile this workspace as it stands: `cairo/Scarb.toml` sets
`enable-gas = false` (required by `doom_run`'s executable target), which
makes `universal-sierra-compiler` fail with "unexpected cycle during cost
computation". Coverage also needs three compiler flags the production
profile must not carry (`inlining-strategy = "avoid"` in particular would
change every step measurement).

So this script copies the crate to a temporary directory, patches the
manifest there — `snforge_std` in place of `cairo_test`, gas back on, the
three `[profile.dev.cairo]` flags — and runs `snforge test --coverage` on
the copy. The crate's own files are never touched.

Production lines only
---------------------
`cairo-coverage` reports every executed line, test modules included, so a
raw 100 % would be meaningless. Lines at or below a file's `#[cfg(test)]`
marker are excluded, and what is printed is the coverage of the code that
ships.

`cairo-coverage` 0.5.0 emits no `BRF`/`BRH` records, so **branch** coverage
cannot be reported by the tool. Line coverage is the available proxy; the
tests are written one per branch arm, and `scarb fmt` puts every arm on its
own line, so a missed arm shows up as a missed line.

Usage: `python3 coverage.py` (needs `snforge` and `cairo-coverage` on PATH).
"""

from __future__ import annotations

import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

CRATE = pathlib.Path(__file__).resolve().parent.parent
TOOL_VERSIONS = "scarb 2.16.0\nstarknet-foundry 0.57.0\ncairo-coverage 0.5.0\n"
PROFILE = """
[profile.dev.cairo]
unstable-add-statements-functions-debug-info = true
unstable-add-statements-code-locations-debug-info = true
inlining-strategy = "avoid"
"""


def patch(root: pathlib.Path) -> None:
    (root / ".tool-versions").write_text(TOOL_VERSIONS)
    manifest = root / "Scarb.toml"
    text = manifest.read_text()
    text = text.replace("version.workspace = true", 'version = "0.1.0"')
    text = text.replace("edition.workspace = true", 'edition = "2024_07"')
    text = text.replace("cairo_test.workspace = true", 'snforge_std = "0.57.0"')
    # Path dependencies point at sibling crates, which the copy keeps.
    if "[profile.dev.cairo]" not in text:
        text += PROFILE
    manifest.write_text(text)


def first_test_line(source: pathlib.Path) -> int:
    for number, line in enumerate(source.read_text().splitlines(), start=1):
        if line.startswith("#[cfg(test)]"):
            return number
    return sys.maxsize


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp) / "crates"
        # Copy every sibling crate so that path dependencies resolve.
        shutil.copytree(
            CRATE.parent, root, ignore=shutil.ignore_patterns("target", "bench", "coverage")
        )
        work = root / CRATE.name
        for sibling in root.iterdir():
            if sibling.is_dir() and (sibling / "Scarb.toml").exists():
                patch(sibling)

        proc = subprocess.run(
            ["snforge", "test", "--coverage"], cwd=work, capture_output=True, text=True
        )
        if proc.returncode != 0:
            print(proc.stdout[-4000:], proc.stderr[-2000:], sep="\n")
            return 1
        tests = re.search(r"Tests: (\d+) passed", proc.stdout)

        lcov = (work / "coverage" / "coverage.lcov").read_text()
        source: pathlib.Path | None = None
        cutoff = sys.maxsize
        hit = total = 0
        uncovered: list[str] = []
        for line in lcov.splitlines():
            if line.startswith("SF:"):
                source = pathlib.Path(line[3:])
                cutoff = first_test_line(source)
                continue
            match = re.match(r"^DA:(\d+),(\d+)$", line)
            if match and int(match.group(1)) < cutoff:
                total += 1
                if int(match.group(2)) > 0:
                    hit += 1
                elif source is not None:
                    uncovered.append(f"{source.name}:{match.group(1)}")

    percent = 100.0 * hit / total if total else 0.0
    print(f"{CRATE.name}: {tests.group(1) if tests else '?'} tests, "
          f"production lines {hit}/{total} = {percent:.1f}%")
    if uncovered:
        print("uncovered: " + ", ".join(uncovered))
    return 0 if percent >= 90.0 else 1


if __name__ == "__main__":
    sys.exit(main())

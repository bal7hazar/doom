#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Line-coverage report for `doom_things` (PLAN.md §3.1 rule 4, C7).

Same method as `cairo/crates/*/bench/coverage.py`, with one difference: a
`doom/*` crate's path dependencies reach out of its own directory into
`cairo/crates/*`, so the copy keeps the whole `cairo/{crates,doom}` layout
rather than just the crate's siblings.

Unlike `doom_map`, this crate's tables (2 566 felts) are small enough to
compile under the `inlining-strategy = "avoid"` that `cairo-coverage`
requires, so the real tests run against the real data -- no fixture.

Why a copy of the crate
-----------------------
`cairo-coverage` only consumes traces from `snforge`, and `snforge` cannot
compile this workspace as it stands: `cairo/Scarb.toml` sets
`enable-gas = false` (required by `doom_run`'s executable target), which
makes `universal-sierra-compiler` fail with "unexpected cycle during cost
computation". Coverage also needs three compiler flags the production
profile must not carry.

Production lines only
---------------------
Lines at or below a file's inline `#[cfg(test)]` marker are excluded, and so
are the generated `src/tables.cairo` (data, not code) and `src/tests.cairo`.
`cairo-coverage` 0.5.0 emits no `BRF`/`BRH` records, so **branch** coverage
cannot be reported by the tool; line coverage is the proxy, and since
`scarb fmt` puts every branch arm on its own line, a missed arm shows up as
a missed line.

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
CAIRO = CRATE.parent.parent
TOOL_VERSIONS = "scarb 2.16.0\nstarknet-foundry 0.57.0\ncairo-coverage 0.5.0\n"
PROFILE = """
[profile.dev.cairo]
unstable-add-statements-functions-debug-info = true
unstable-add-statements-code-locations-debug-info = true
inlining-strategy = "avoid"
"""
EXCLUDED = ("tables.cairo", "tests.cairo")


def patch(root: pathlib.Path) -> None:
    (root / ".tool-versions").write_text(TOOL_VERSIONS)
    manifest = root / "Scarb.toml"
    text = manifest.read_text()
    text = text.replace("version.workspace = true", 'version = "0.1.0"')
    text = text.replace("edition.workspace = true", 'edition = "2024_07"')
    text = text.replace("cairo_test.workspace = true", 'snforge_std = "0.57.0"')
    if "[profile.dev.cairo]" not in text:
        text += PROFILE
    manifest.write_text(text)


def first_test_line(source: pathlib.Path) -> int:
    """Line from which a file is test code, or `maxsize` if it never is.

    A bare `#[cfg(test)] mod tests;` **declaration** is not a cutoff: the
    module's body is a separate file, already excluded by name.
    """
    if not source.exists():
        return sys.maxsize
    lines = source.read_text().splitlines()
    for number, line in enumerate(lines, start=1):
        if line.startswith("#[cfg(test)]"):
            following = lines[number] if number < len(lines) else ""
            if following.strip().endswith(";"):
                continue
            return number
    return sys.maxsize


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp) / "cairo"
        root.mkdir()
        ignore = shutil.ignore_patterns("target", "bench", "coverage", "__pycache__")
        shutil.copytree(CAIRO / "crates", root / "crates", ignore=ignore)
        shutil.copytree(CAIRO / "doom", root / "doom", ignore=ignore)
        for group in ("crates", "doom"):
            for package in (root / group).iterdir():
                if package.is_dir() and (package / "Scarb.toml").exists():
                    patch(package)
        work = root / "doom" / CRATE.name

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
        skip = False
        hit = total = 0
        uncovered: list[str] = []
        for line in lcov.splitlines():
            if line.startswith("SF:"):
                source = pathlib.Path(line[3:])
                skip = any(marker in str(source) for marker in EXCLUDED)
                cutoff = first_test_line(source)
                continue
            if skip:
                continue
            match = re.match(r"^DA:(\d+),(\d+)$", line)
            if match and int(match.group(1)) < cutoff:
                total += 1
                if int(match.group(2)) > 0:
                    hit += 1
                elif source is not None:
                    uncovered.append("%s:%s" % (source.name, match.group(1)))

    percent = 100.0 * hit / total if total else 0.0
    print(
        "%s: %s tests, production lines %d/%d = %.1f%%"
        % (CRATE.name, tests.group(1) if tests else "?", hit, total, percent)
    )
    if uncovered:
        print("uncovered: " + ", ".join(uncovered))
    return 0 if percent >= 90.0 else 1


if __name__ == "__main__":
    sys.exit(main())

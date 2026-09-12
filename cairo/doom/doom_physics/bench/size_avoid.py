#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""The crate's bytecode under `inlining-strategy = "avoid"`, for comparison
with `measure.py`'s figure under Scarb's default inliner.

The real E1M1 data does not compile under `avoid` (`Offset overflow`, the
same limitation `bench/coverage.py` documents), so this copies the
`cairo/{crates,doom}` tree to a temporary directory, swaps `doom_map`'s level
for its miniature fixture (imported from `doom_map/bench/coverage.py`) and
builds `bench/size` and `bench/baseline` there under each strategy. The
difference between the two executables is the physics code; the level data
is the same tiny fixture on both sides and cancels.

Usage: `python3 size_avoid.py [default|avoid|<weight>]...` (default: both).
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

CRATE = pathlib.Path(__file__).resolve().parent.parent
CAIRO = CRATE.parent.parent
sys.path.insert(0, str(CAIRO / "doom" / "doom_map" / "bench"))
import coverage as map_coverage  # noqa: E402


def words(pkg: pathlib.Path) -> int:
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    p = subprocess.run(["scarb", "build"], cwd=pkg, capture_output=True, text=True, env=env)
    if p.returncode != 0:
        raise SystemExit(p.stdout[-2000:] + p.stderr[-2000:])
    f = sorted((pkg / "target" / "dev").glob("*.executable.json"))[0]
    return len(json.loads(f.read_text())["program"]["bytecode"])


def main() -> int:
    strategies = sys.argv[1:] or ["default", "avoid"]
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp) / "cairo"
        root.mkdir()
        ignore = shutil.ignore_patterns("target", "coverage", "__pycache__")
        shutil.copytree(CAIRO / "crates", root / "crates", ignore=ignore)
        shutil.copytree(CAIRO / "doom", root / "doom", ignore=ignore)
        (root / "doom" / "doom_map" / "src" / "levels" / "e1m1.cairo").write_text(
            map_coverage.fixture_level()
        )
        for group in ("crates", "doom"):
            for package in (root / group).iterdir():
                manifest = package / "Scarb.toml"
                if package.is_dir() and manifest.exists():
                    text = manifest.read_text()
                    text = text.replace("version.workspace = true", 'version = "0.1.0"')
                    text = text.replace("edition.workspace = true", 'edition = "2024_07"')
                    text = text.replace("cairo_test.workspace = true", 'cairo_test = "2.16.0"')
                    manifest.write_text(text)
        bench = root / "doom" / CRATE.name / "bench"
        for strategy in strategies:
            value = '"%s"' % strategy if not strategy.isdigit() else strategy
            results = {}
            for pkg in ("size", "baseline"):
                manifest = bench / pkg / "Scarb.toml"
                text = manifest.read_text()
                if "[profile.dev.cairo]" in text:
                    text = text[: text.index("[profile.dev.cairo]")].rstrip() + "\n"
                text += "\n[profile.dev.cairo]\ninlining-strategy = %s\n" % value
                manifest.write_text(text)
                results[pkg] = words(bench / pkg)
            print(
                "inlining-strategy = %-9s size %6d - baseline %6d = %6d words of doom_physics code"
                % (strategy, results["size"], results["baseline"], results["size"] - results["baseline"])
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())

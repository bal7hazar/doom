#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Where `doom_player`'s bytecode goes, module by module.

`measure.py` reports one number: `bench/size` minus `bench/baseline`. This
script splits it, by building `bench/size` five times with the calls of one
more module switched on each time (`state`, then `+inter`, then `+weapon`,
then `+think`, then `+tic`). Each step's increment is what that module's
code and its call sites introduce, including lower-crate dependencies
missing from earlier steps. It is a linkage diagnostic, not source ownership;
`attribute.py` provides source ownership.

The markers are the `// SIZE:<module>` comments in `size/src/lib.cairo`; the complete semicolon-terminated statement carrying one is kept only
from the step that switches its module on, including statements wrapped by
`scarb fmt`.

Usage: `python3 size_split.py`
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
STEPS = ["state", "inter", "weapon", "think", "tic"]


def words(cwd: Path) -> int:
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    p = subprocess.run(
        ["scarb", "build"], cwd=str(cwd), capture_output=True, text=True, env=env
    )
    if p.returncode != 0:
        raise SystemExit(p.stdout + p.stderr)
    out = sorted((cwd / "target" / "dev").glob("*.executable.json"))
    return len(json.loads(out[0].read_text())["program"]["bytecode"])


def variant(source: str, enabled: set[str]) -> str:
    kept = []
    pending = []
    for line in source.splitlines(True):
        pending.append(line)
        if not re.search(r";\s*(?://.*)?$", line):
            continue
        m = re.search(r"// SIZE:(\w+)", line)
        if not m or m.group(1) in enabled:
            kept.extend(pending)
        pending = []
    kept.extend(pending)
    return "".join(kept)


def main() -> int:
    base = words(BASELINE)
    target = SIZE / "src" / "lib.cairo"
    source = target.read_text()
    print("baseline: %d words" % base)
    previous = base
    # The manifest's dependencies are relative paths, so the variants are
    # built in place and the file is put back whatever happens.
    try:
        enabled: set[str] = set()
        for step in STEPS:
            enabled.add(step)
            target.write_text(variant(source, enabled))
            total = words(SIZE)
            print("+%-8s %7d words  (+%d)" % (step, total - base, total - previous))
            previous = total
    finally:
        target.write_text(source)
        words(SIZE)
    return 0


if __name__ == "__main__":
    sys.exit(main())

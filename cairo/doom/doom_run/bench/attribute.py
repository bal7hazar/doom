#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Where the words of the proved program go, crate by crate (D29).

Builds `doom_run` under the `proving` profile (which carries
`unstable-add-statements-functions-debug-info = true`), compiles the Sierra
of the `run_segment` executable to CASM with `infra/sierra_words` (the
exact `cairo-execute` pipeline) and attributes every bytecode word to the
**innermost source function** the statement was inlined from, then rolls
the functions up by crate. The method is `doom_physics/bench/attribute.py`
(docs/spikes/S7.md §1); this script only adds the per-crate roll-up and
takes the workspace build instead of a `bench/size` package.

Usage:
    python3 attribute.py [--exe run_segment|step_tic|genesis] [--top N]
"""

from __future__ import annotations

import collections
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[2]
REPO = HERE.parents[3]
TOOL_DIR = REPO / "infra" / "sierra_words"
TOOL = TOOL_DIR / "target" / "release" / "sierra_words"
CRATES = (
    "doom_game", "doom_run", "doom_physics", "doom_monsters", "doom_player", "doom_specials",
    "doom_map", "doom_things", "segment", "state_hash", "ticcmd", "fixed", "bam", "geom2d",
    "bsp", "blockmap", "fsm", "prng", "core",
)


def sh(args, cwd, env=None):
    p = subprocess.run(args, cwd=str(cwd), capture_output=True, text=True, env=env)
    if p.returncode != 0:
        raise SystemExit("%s failed:\n%s\n%s" % (" ".join(args), p.stdout[-2000:], p.stderr[-2000:]))
    return p.stdout


def build(exe: str) -> Path:
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    # All three targets emit Sierra; only generated artifacts carry it.
    sh(["scarb", "--manifest-path", str(WORKSPACE / "Scarb.toml"), "--profile", "proving",
        "build", "-p", "doom_run"], WORKSPACE, env)
    sierra = WORKSPACE / "target" / "proving" / f"{exe}.executable.sierra.json"
    if not sierra.exists():
        raise SystemExit(
            "no %s: set `sierra = true` on the `%s` target of doom_run/Scarb.toml for this run"
            % (sierra, exe)
        )
    return sierra


def offsets(sierra: Path) -> tuple[dict[int, int], int]:
    if not TOOL.exists():
        sh(["cargo", "build", "--release", "--jobs", "2"], TOOL_DIR)
    out = sh([str(TOOL), str(sierra)], HERE)
    words: dict[int, int] = {}
    total = 0
    for line in out.splitlines():
        if line.startswith("TOTAL"):
            total = int(line.split()[1])
            continue
        i, a, b = map(int, line.split())
        words[i] = b - a
    return words, total


def clean(name: str) -> str:
    name = re.sub(r"\{.*\}$", "", name)
    name = re.sub(r"::<.*>", "", name)
    name = re.sub(r"\[\d+-\d+\]", "", name)
    return name


def crate_of(name: str) -> str:
    head = name.split("::", 1)[0]
    return head if head in CRATES else "other"


def table(title, counter, n):
    print("\n== %s (total %d)" % (title, sum(counter.values())))
    for name, c in counter.most_common(n):
        print("%7d  %s" % (c, name))


def main() -> int:
    exe = "run_segment"
    top = 40
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a == "--exe":
            exe = args.pop(0)
        elif a == "--top":
            top = int(args.pop(0))
        else:
            raise SystemExit(__doc__)
    sierra_path = build(exe)
    s = json.loads(sierra_path.read_text())
    words, total = offsets(sierra_path)
    ann = s["debug_info"]["annotations"]["github.com/software-mansion/cairo-profiler"]
    stmt_fns = ann["statements_functions"]
    stmts = s["statements"]
    entries = sorted((f["entry_point"], f) for f in s["funcs"])
    owner: dict[int, str] = {}
    for k, (ep, f) in enumerate(entries):
        end = entries[k + 1][0] if k + 1 < len(entries) else len(stmts)
        name = f["id"].get("debug_name") or str(f["id"]["id"])
        for i in range(ep, end):
            owner[i] = name
    by_crate = collections.Counter()
    by_fn = collections.Counter()
    inner = collections.Counter()
    unattributed = 0
    for i, w in words.items():
        raw = owner.get(i, "?")
        by_fn[clean(raw)] += w
        stack = stmt_fns.get(str(i))
        if not stack:
            unattributed += w
            by_crate[crate_of(clean(raw))] += w
            continue
        name = clean(stack[0])
        inner[name] += w
        by_crate[crate_of(name)] += w
    print("%s (proving): %d code words (unattributed by inlining stack: %d)" % (exe, total, unattributed))
    table("words by crate (innermost source function's crate)", by_crate, 30)
    table("words by innermost source function", inner, top)
    table("words by Sierra function (post-inlining)", by_fn, top)
    return 0


if __name__ == "__main__":
    sys.exit(main())

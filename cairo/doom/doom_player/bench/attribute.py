#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Bytecode attribution of `bench/size` (docs/spikes/S7.md §1, §8 rule 8).

Adapted from `doom_physics/bench/attribute.py`; only the crate prefix of the
parameter/return-width table differs, so a fix in one belongs in both.

Builds `bench/size` (whose manifest enables Scarb's statement -> function
debug info), compiles its Sierra to CASM with `infra/sierra_words` (the
exact `cairo-execute` pipeline, so the offsets are the executable's) and
joins the two: every Sierra statement gets a bytecode word count and the
stack of source functions it was inlined from. From that it prints

* words per Sierra function (post-inlining: loop bodies and specialised
  copies merged under their source function, then raw);
* words per *innermost* source function (which helper a word came from);
* `store_temp` words per stored type (argument plumbing: which structs are
  being pushed around);
* `PanicResult` stores per function, split Ok / Err (the return-width tax
  of every return point and every panic site, S7 §2);
* the libfunc histogram, the parameter and return widths of every
  function, and the constant-argument specialisations still present.

Usage:
    python3 attribute.py [--top N] [--fn NAME ...]
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
SIZE = HERE / "size"
REPO = HERE.parents[3]
TOOL_DIR = REPO / "infra" / "sierra_words"
TOOL = TOOL_DIR / "target" / "release" / "sierra_words"
CRATE = "doom_player::"


def sh(args, cwd, env=None):
    p = subprocess.run(args, cwd=str(cwd), capture_output=True, text=True, env=env)
    if p.returncode != 0:
        raise SystemExit("%s failed:\n%s\n%s" % (" ".join(args), p.stdout[-2000:], p.stderr[-2000:]))
    return p.stdout


def build_size() -> Path:
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    sh(["scarb", "build"], SIZE, env)
    files = sorted((SIZE / "target" / "dev").glob("*.executable.sierra.json"))
    if not files:
        raise SystemExit("no *.executable.sierra.json under bench/size/target/dev (sierra = true?)")
    return files[0]


def offsets(sierra: Path) -> tuple[dict[int, int], int]:
    if not TOOL.exists():
        sh(["cargo", "build", "--release"], TOOL_DIR)
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
    name = re.sub(r"\{.*\}$", "", name)  # specialisation suffix
    name = re.sub(r"::<.*>", "", name)  # generic args
    name = re.sub(r"\[\d+-\d+\]", "", name)  # loop functions
    return name


def table(title, counter, n):
    print("\n== %s (total %d)" % (title, sum(counter.values())))
    for name, c in counter.most_common(n):
        print("%7d  %s" % (c, name))


def main() -> int:
    top = 40
    wanted: list[str] = []
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a == "--top":
            top = int(args.pop(0))
        elif a == "--fn":
            wanted.append(args.pop(0))
        else:
            raise SystemExit(__doc__)

    sierra_path = build_size()
    s = json.loads(sierra_path.read_text())
    words, total = offsets(sierra_path)
    ann = s["debug_info"]["annotations"]["github.com/software-mansion/cairo-profiler"]
    stmt_fns = ann["statements_functions"]
    libfuncs = {d["id"]["id"]: d["long_id"]["generic_id"] for d in s["libfunc_declarations"]}
    libfunc_names = {
        d["id"]["id"]: (d["id"].get("debug_name") or d["long_id"]["generic_id"])
        for d in s["libfunc_declarations"]
    }
    stmts = s["statements"]
    entries = sorted((f["entry_point"], f) for f in s["funcs"])
    owner: dict[int, str] = {}
    for k, (ep, f) in enumerate(entries):
        end = entries[k + 1][0] if k + 1 < len(entries) else len(stmts)
        name = f["id"].get("debug_name", str(f["id"]["id"]))
        for i in range(ep, end):
            owner[i] = name

    by_fn = collections.Counter()
    by_raw = collections.Counter()
    inner = collections.Counter()
    kind = collections.Counter()
    stemp = collections.Counter()
    panic_ok = collections.Counter()
    panic_err = collections.Counter()
    unattributed = 0
    for i, w in words.items():
        st = stmts[i]
        raw = owner.get(i, "?")
        by_raw[raw] += w
        by_fn[clean(raw)] += w
        if "Invocation" in st:
            g = libfuncs[st["Invocation"]["libfunc_id"]["id"]]
            full = libfunc_names[st["Invocation"]["libfunc_id"]["id"]]
        else:
            g, full = "return", "return"
        kind[g] += w
        if g == "store_temp":
            t = re.sub(r"^store_temp<(.*)>$", r"\1", full)
            t = re.sub(r"::<.*", "", t)
            stemp[t] += w
            if t.startswith("core::panics::PanicResult"):
                # Ok or Err: the enum_init just before says which variant.
                variant = "?"
                for j in range(i - 1, max(i - 8, -1), -1):
                    sj = stmts[j]
                    if "Invocation" in sj:
                        nj = libfunc_names[sj["Invocation"]["libfunc_id"]["id"]]
                        if nj.startswith("enum_init<core::panics::PanicResult"):
                            variant = nj.rstrip(">").rsplit(",", 1)[-1].strip()
                            break
                (panic_ok if variant == "0" else panic_err)[clean(raw)] += w
        stack = stmt_fns.get(str(i))
        if not stack:
            unattributed += w
            continue
        inner[clean(stack[0])] += w

    print("code words: %d (unattributed %d)" % (total, unattributed))
    table("words by function (loop bodies and specialised copies merged)", by_fn, top)
    table("words by innermost source function (which helper a word came from)", inner, top)
    table("store_temp words by stored type", stemp, 25)
    both = collections.Counter()
    for k in set(panic_ok) | set(panic_err):
        both[k] = panic_ok[k] + panic_err[k]
    print("\n== PanicResult stores per function (Ok = return points, Err = panic sites)")
    for name, c in both.most_common(top):
        print("%7d  (Ok %5d, Err %5d)  %s" % (c, panic_ok[name], panic_err[name], name))
    table("words by libfunc", kind, 30)

    # Parameter / return widths.
    types = {t["id"]["id"]: t for t in s["type_declarations"]}
    cache: dict[int, int] = {}

    def tsize(tid) -> int:
        if tid in cache:
            return cache[tid]
        t = types[tid]
        g = t["long_id"]["generic_id"]
        a = t["long_id"]["generic_args"]
        if g in ("Array", "Span"):
            n = 2
        elif g == "Struct":
            n = sum(tsize(x["Type"]["id"]) for x in a[1:])
        elif g == "Enum":
            subs = [tsize(x["Type"]["id"]) for x in a[1:]]
            n = 1 + (max(subs) if subs else 0)
        elif g in ("Snapshot", "NonZero", "Uninitialized"):
            n = tsize(a[0]["Type"]["id"])
        elif g in ("EcPoint",):
            n = 2
        elif g in ("EcState", "Felt252DictEntry"):
            n = 3
        elif g == "U128MulGuarantee":
            n = 4
        else:
            n = 1
        cache[tid] = n
        return n

    print("\n== parameter / return widths (felts) of the crate's functions")
    print("%6s %5s %5s  %s" % ("words", "param", "ret", "function"))
    rows = []
    for ep, f in entries:
        name = f["id"].get("debug_name", "")
        if not name.startswith(CRATE):
            continue
        p = sum(tsize(x["ty"]["id"]) for x in f["params"])
        r = sum(tsize(t["id"]) for t in f["signature"]["ret_types"])
        rows.append((by_raw[name], p, r, name))
    rows.sort(reverse=True)
    for w, p, r, name in rows[:top]:
        print("%6d %5d %5d  %s" % (w, p, r, name[:110]))

    spec = [f["id"].get("debug_name", "") for f in s["funcs"] if "{" in f["id"].get("debug_name", "")]
    print("\n== constant-argument specialisations (%d)" % len(spec))
    for n in spec:
        print("  ", n[:150])

    for name in wanted:
        sub = collections.Counter()
        for i, w in words.items():
            if clean(owner.get(i, "")) == name:
                st = stmts[i]
                g = libfunc_names[st["Invocation"]["libfunc_id"]["id"]] if "Invocation" in st else "return"
                sub[re.sub(r"::<.*", "", g)[:90]] += w
        table("libfuncs inside %s" % name, sub, 40)
    return 0


if __name__ == "__main__":
    sys.exit(main())

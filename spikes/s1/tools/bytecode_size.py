#!/usr/bin/env python3
"""Spike S1 - how much compiled bytecode does a const array cost?

The proving bootloader hashes the whole program once per segment at
2340 + 14.7 x words steps, so program size is a per-segment tax and const map
data competes directly with the per-tic budget.  This script builds a few
throwaway packages with a controlled number of const felts (and the same data
as a match/if-tree instead) and reports the compiled bytecode word count.

Usage: bytecode_size.py <scratch_dir>
"""
import json
import os
import subprocess
import sys

ENV = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")

MANIFEST = """[package]
name = "bc"
version = "0.1.0"
edition = "2024_07"

[dependencies]
cairo_execute = "2.16.0"

[[target.executable]]
name = "bc"
function = "bc::main"

[cairo]
enable-gas = false
"""


def const_array_src(n):
    vals = ", ".join(str((i * 2654435761) % 4294967291) for i in range(n))
    arr = "const T: [felt252; %d] = [%s];\n" % (n, vals) if n else ""
    body = ("*T.span().at(i % " + str(n) + ")") if n else "0"
    return arr + """
#[executable]
fn main(i: u32) -> felt252 {
    %s
}
""" % body


def if_tree_src(n):
    """Same n values as a balanced if-tree, to compare bytecode cost."""
    vals = [(i * 2654435761) % 4294967291 for i in range(n)]

    def rec(lo, hi, ind):
        pad = " " * ind
        if hi - lo == 1:
            return "%s%d\n" % (pad, vals[lo])
        mid = (lo + hi) // 2
        return ("%sif k < %d {\n%s%s} else {\n%s%s}\n"
                % (pad, mid, rec(lo, mid, ind + 4), pad, rec(mid, hi, ind + 4), pad))

    return """
fn lookup(k: u32) -> felt252 {
%s}

#[executable]
fn main(i: u32) -> felt252 {
    lookup(i %% %d)
}
""" % (rec(0, n, 4), n)


BODY = """
%sfn work(a: felt252, b: felt252, k: u32) -> felt252 {
    let d: u128 = (a * 7 + b * 11 - b + 0x10000000000000000).try_into().unwrap();
    let e: u32 = k %% 97;
    if d > 0x10000000000000000_u128 {
        a + e.into()
    } else {
        b + e.into()
    }
}
"""


def inline_src(n_calls, inline):
    attr = "#[inline(always)]\n" if inline else "#[inline(never)]\n"
    calls = "".join("    acc = work(acc, acc + %d, i + %d);\n" % (j, j)
                    for j in range(n_calls))
    return BODY % attr + """
#[executable]
fn main(i: u32) -> felt252 {
    let mut acc: felt252 = i.into();
%s    acc
}
""" % calls


def generic_src(types):
    """One generic helper monomorphised over `types` element types."""
    arrs = "".join(
        "const A%d: [%s; 64] = [%s];\n"
        % (n, t, ", ".join(str(j % 60) for j in range(64)))
        for n, t in enumerate(types))
    gen = """
fn pick<T, +Copy<T>, +Drop<T>, +Into<T, felt252>>(s: Span<T>, k: u32) -> felt252 {
    (*s.at(k % 64)).into()
}
"""
    calls = "".join("    acc = acc + pick(A%d.span(), i + %d);\n" % (n, n)
                    for n in range(len(types)))
    return arrs + gen + """
#[executable]
fn main(i: u32) -> felt252 {
    let mut acc: felt252 = 0;
%s    acc
}
""" % calls


def build(scratch, name, src):
    d = os.path.join(scratch, "bc_" + name)
    os.makedirs(os.path.join(d, "src"), exist_ok=True)
    open(os.path.join(d, "Scarb.toml"), "w").write(MANIFEST)
    open(os.path.join(d, "src", "lib.cairo"), "w").write(src)
    p = subprocess.run(["scarb", "build"], cwd=d, capture_output=True, text=True, env=ENV)
    if p.returncode != 0:
        return None
    j = json.load(open(os.path.join(d, "target", "dev", "bc.executable.json")))
    return len(j["program"]["bytecode"])


def main():
    scratch = sys.argv[1]
    rows = []
    for n in (0, 256, 1024, 4096, 16384, 32000):
        w = build(scratch, "arr%d" % n, const_array_src(n))
        rows.append(("const array, %d felts" % n, w))
        print("%-28s %s words" % (rows[-1][0], w), flush=True)
    for n in (256, 1024):
        w = build(scratch, "tree%d" % n, if_tree_src(n))
        rows.append(("if-tree, %d values" % n, w))
        print("%-28s %s words" % (rows[-1][0], w), flush=True)
    base = rows[0][1]
    for label, w in rows[1:]:
        if w is None:
            continue
        n = int(label.split(",")[1].split()[0])
        print("  %-26s %.2f words per value" % (label, (w - base) / n))

    print()
    for inline in (False, True):
        tag = "inline(always)" if inline else "inline(never)"
        ws = []
        for n in (1, 20):
            w = build(scratch, "inl%d_%d" % (int(inline), n), inline_src(n, inline))
            ws.append(w)
            print("%-28s %s words (%d call sites)" % (tag, w, n))
        if all(ws):
            print("  -> %.1f words per extra call site" % ((ws[1] - ws[0]) / 19))

    print()
    for types in (["felt252"], ["felt252", "u32"], ["felt252", "u32", "u64"]):
        w = build(scratch, "gen%d" % len(types), generic_src(types))
        print("generic helper over %d type(s)  %s words" % (len(types), w))


if __name__ == "__main__":
    main()

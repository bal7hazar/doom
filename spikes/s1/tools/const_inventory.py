#!/usr/bin/env python3
"""Spike S1 - inventory of the const arrays compiled into the prototype.

Compiled bytecode is 1.00 word per const felt (measured, see
tools/bytecode_size.py), and the proving bootloader hashes the program once per
segment at 2340 + 14.7 x words steps.  Const map data is therefore a
per-segment tax, amortised over K tics.
"""
import json
import os
import re
import sys

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "proto", "src")
RE = re.compile(r"pub const ([A-Z_0-9]+): \[[a-z0-9]+; (\d+)\]")

# arrays a production core would actually keep
LEAN = {
    "L_AB", "L_BB", "L_CB", "L_DIAG", "L_BBL", "L_BBR", "L_BBB", "L_BBT",
    "L_BLOCKING", "L_TWOSIDED", "L_BLOCKMONST", "L_FRONT", "L_BACK",
    "N_AB", "N_BB", "N_CB", "N_C0", "N_C1",
    "SS_SECTOR", "S_FLOOR", "S_CEIL",
    "BM_START", "BM_COUNT", "BM_LINES", "BM_CELL_SECTOR",
    "FINESINE", "TANTOANGLE", "RNDTABLE",
    "REJECT_C0", "REJECT_C1",
    "MON_X", "MON_Y", "MON_ANGLE", "MON_SECTOR",
}


def main():
    rows = []
    for f in ("mapdata.cairo", "mapdata_packed.cairo", "tables.cairo"):
        for m in RE.finditer(open(os.path.join(SRC, f)).read()):
            rows.append((m.group(1), int(m.group(2)), f))
    total = sum(n for _, n, _ in rows)
    lean = sum(n for k, n, _ in rows if k in LEAN)
    prog = json.load(open(os.path.join(SRC, "..", "target", "dev",
                                       "proto.executable.json")))
    words = len(prog["program"]["bytecode"])
    print("%-20s %8s" % ("array", "felts"))
    for k, n, f in sorted(rows, key=lambda r: -r[1]):
        print("%-20s %8d  %s%s" % (k, n, f, "" if k in LEAN else "   (spike only)"))
    print()
    print("const felts, all            %8d" % total)
    print("const felts, lean subset    %8d" % lean)
    print("compiled bytecode words     %8d" % words)
    print("code (words - const felts)  %8d" % (words - total))
    for label, w in (("as built", words), ("lean subset + code", lean + words - total)):
        h = 2340 + 14.7 * w
        print("%-26s %8d words -> %9.0f steps of program hashing per segment"
              % (label, w, h))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate `src/tests/vectors.cairo` for the `bsp` crate.

Builds a deterministic BSP tree over a square region -- alternating
vertical and horizontal splits at pseudo-random positions, six levels deep,
so 63 nodes and 64 leaves -- and emits it in exactly the planar form the
crate consumes (three biased half-plane coefficient arrays, two child
arrays, eight bbox felts per node).

Then emits two families of expectations, both computed by a Python
transcription of Doom's algorithms working on the same exact integer
predicate the Cairo crate uses:

* `PT_*` -- 1 000 points and the subsector `R_PointInSubsector` reaches,
  including points that land exactly on a partition line;
* `TR_*` -- 200 traces and the ordered list of subsectors
  `P_CrossBSPNode` visits, flattened with a start-offset array.

The tree is geometric, not random: every leaf is a real rectangle, so the
traversal order is the one a renderer or `P_CheckSight` would need.

The same tree (and only the tree) is also written to `bench/src/tree.cairo`,
so that the step-cost benchmark measures a descent over real data.

Usage: python3 scripts/gen_vectors.py --write && scarb fmt -p bsp
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIAS = 1 << 32
COEF_BIAS = 1 << 17
CONST_BIAS = 1 << 50
UNIT = 65536
SUBSECTOR_FLAG = 0x80000000
SIDE_FRONT, SIDE_BACK, SIDE_CROSS = 0, 1, 2
DEPTH = 6


class Rng:
    def __init__(self, seed: int) -> None:
        self.s = seed

    def next(self) -> int:
        self.s = (self.s * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        return self.s >> 11


def half_plane(v1, v2):
    ldx = (v2[0] - v1[0]) >> 16
    ldy = (v2[1] - v1[1]) >> 16
    a, b = ldx, -ldy
    c = ldy * v1[0] - ldx * v1[1]
    return (a + COEF_BIAS, b + COEF_BIAS, c - (a + b) * BIAS + CONST_BIAS)


def lhs(hp, p):
    return hp[0] * (p[1] + BIAS) + hp[1] * (p[0] + BIAS) + hp[2]


def rhs(p):
    return COEF_BIAS * ((p[0] + BIAS) + (p[1] + BIAS)) + CONST_BIAS


def point_side(hp, p) -> int:
    return SIDE_BACK if lhs(hp, p) >= rhs(p) else SIDE_FRONT


def divline_side(hp, p) -> int:
    l, r = lhs(hp, p), rhs(p)
    if l == r:
        return SIDE_CROSS
    return SIDE_BACK if l > r else SIDE_FRONT


class Tree:
    def __init__(self) -> None:
        self.ab: list[int] = []
        self.bb: list[int] = []
        self.cb: list[int] = []
        self.child0: list[int] = []
        self.child1: list[int] = []
        self.bbox: list[int] = []
        self.leaf_boxes: list[tuple[int, int, int, int]] = []
        self.rng = Rng(0xB59B59B5)

    def build(self, region, depth: int) -> int:
        """Return the child id of the subtree covering `region`."""
        x0, y0, x1, y1 = region
        if depth == 0:
            leaf = len(self.leaf_boxes)
            self.leaf_boxes.append(region)
            return SUBSECTOR_FLAG | leaf
        vertical = depth % 2 == 1
        if vertical:
            # split somewhere in the middle half of the region
            xs = x0 + (x1 - x0) // 4 + self.rng.next() % max(1, (x1 - x0) // 2)
            xs = (xs // UNIT) * UNIT  # keep vertices on integer map units
            if xs <= x0 or xs >= x1:
                xs = (x0 + x1) // 2 // UNIT * UNIT
            v1, v2 = (xs, y0), (xs, y1)
            left, right = (x0, y0, xs, y1), (xs, y0, x1, y1)
            regions = (left, right)
        else:
            ys = y0 + (y1 - y0) // 4 + self.rng.next() % max(1, (y1 - y0) // 2)
            ys = (ys // UNIT) * UNIT
            if ys <= y0 or ys >= y1:
                ys = (y0 + y1) // 2 // UNIT * UNIT
            v1, v2 = (x0, ys), (x1, ys)
            regions = ((x0, y0, x1, ys), (x0, ys, x1, y1))
        hp = half_plane(v1, v2)
        # Decide which half is the front side by testing its centre.
        centres = [((r[0] + r[2]) // 2, (r[1] + r[3]) // 2) for r in regions]
        sides = [point_side(hp, c) for c in centres]
        assert sides[0] != sides[1], "a split must separate its two halves"
        front_region = regions[0] if sides[0] == SIDE_FRONT else regions[1]
        back_region = regions[1] if sides[0] == SIDE_FRONT else regions[0]

        index = len(self.ab)
        self.ab.append(hp[0]); self.bb.append(hp[1]); self.cb.append(hp[2])
        self.child0.append(0); self.child1.append(0)
        self.bbox.extend([0] * 8)

        c0 = self.build(front_region, depth - 1)
        c1 = self.build(back_region, depth - 1)
        self.child0[index] = c0
        self.child1[index] = c1
        for k, r in enumerate((front_region, back_region)):
            self.bbox[index * 8 + k * 4 + 0] = r[0] + BIAS  # left
            self.bbox[index * 8 + k * 4 + 1] = r[1] + BIAS  # bottom
            self.bbox[index * 8 + k * 4 + 2] = r[2] + BIAS  # right
            self.bbox[index * 8 + k * 4 + 3] = r[3] + BIAS  # top
        return index

    # -- the reference algorithms ------------------------------------------

    def point_in_subsector(self, root: int, p) -> int:
        cur = root
        while cur < SUBSECTOR_FLAG:
            hp = (self.ab[cur], self.bb[cur], self.cb[cur])
            cur = self.child0[cur] if point_side(hp, p) == SIDE_FRONT else self.child1[cur]
        return cur - SUBSECTOR_FLAG

    def cross(self, num: int, p1, p2, out: list[int], limit: int) -> bool:
        if num >= SUBSECTOR_FLAG:
            out.append(num - SUBSECTOR_FLAG)
            return len(out) < limit
        hp = (self.ab[num], self.bb[num], self.cb[num])
        side = divline_side(hp, p1)
        if side == SIDE_CROSS:
            side = SIDE_FRONT
        near = self.child0[num] if side == SIDE_FRONT else self.child1[num]
        far = self.child1[num] if side == SIDE_FRONT else self.child0[num]
        if not self.cross(near, p1, p2, out, limit):
            return False
        if side == divline_side(hp, p2):
            return True
        return self.cross(far, p1, p2, out, limit)


def emit(name: str, values: list[int], per_line: int = 8, typ: str = "felt252") -> str:
    body = ",\n    ".join(
        ", ".join(str(v) for v in values[i:i + per_line])
        for i in range(0, len(values), per_line)
    )
    return "pub const %s: [%s; %d] = [\n    %s,\n];\n\n" % (name, typ, len(values), body)


HEADER = """// SPDX-License-Identifier: Apache-2.0
// GENERATED by scripts/gen_vectors.py -- do not edit by hand.
//
// A %(nodes)d-node, %(leaves)d-leaf BSP tree over a %(span)d x %(span)d unit
// square, in the planar form the crate consumes, plus:
//
//   * %(pts)d points and the subsector R_PointInSubsector reaches
//     (%(on_line)d of them land exactly on a partition line, which is the
//     tie the crate resolves toward the back child);
//   * %(traces)d traces and the ordered subsectors P_CrossBSPNode visits,
//     flattened (TR_SS) with a start offset per trace (TR_START); the
//     longest visits %(longest)d subsectors.
//
// Every expectation is computed by a Python transcription of Doom's two
// algorithms over the same exact integer predicate the Cairo crate uses.
"""


def main() -> int:
    span = 1024 * UNIT
    tree = Tree()
    root = tree.build((-span, -span, span, span), DEPTH)
    assert root < SUBSECTOR_FLAG
    rng = Rng(0x1234ABCD)

    # -- points -------------------------------------------------------------
    pts_n = 1000
    px, py, pss = [], [], []
    on_line = 0
    # The first cases are corners and points exactly on partition lines.
    specials = [(-span, -span), (span - 1, span - 1), (0, 0), (-span, span - 1)]
    for k in range(pts_n):
        if k < len(specials):
            p = specials[k]
        elif k % 7 == 0:
            # Put the point exactly on some node's partition line: pick a
            # node, read its coefficients back into a coordinate.
            node = rng.next() % len(tree.ab)
            a = tree.ab[node] - COEF_BIAS
            b = tree.bb[node] - COEF_BIAS
            if a == 0:
                # vertical partition: x is fixed, y free
                x = tree.leaf_boxes[0][0]
                # solve b*x + c' = 0 for x from the stored coefficients
                cprime = tree.cb[node] - CONST_BIAS + (a + b) * BIAS
                x = -cprime // b
                y = rng.next() % (2 * span) - span
                p = (x, y)
            else:
                cprime = tree.cb[node] - CONST_BIAS + (a + b) * BIAS
                y = -cprime // a
                x = rng.next() % (2 * span) - span
                p = (x, y)
            hp = (tree.ab[node], tree.bb[node], tree.cb[node])
            if divline_side(hp, p) == SIDE_CROSS:
                on_line += 1
        else:
            p = (rng.next() % (2 * span) - span, rng.next() % (2 * span) - span)
        px.append(p[0] + BIAS)
        py.append(p[1] + BIAS)
        pss.append(tree.point_in_subsector(root, p))

    # -- traces -------------------------------------------------------------
    tr_n = 200
    tx1, ty1, tx2, ty2, start, flat = [], [], [], [], [], []
    longest = 0
    for _ in range(tr_n):
        p1 = (rng.next() % (2 * span) - span, rng.next() % (2 * span) - span)
        p2 = (rng.next() % (2 * span) - span, rng.next() % (2 * span) - span)
        out: list[int] = []
        tree.cross(root, p1, p2, out, 1 << 30)
        longest = max(longest, len(out))
        tx1.append(p1[0] + BIAS); ty1.append(p1[1] + BIAS)
        tx2.append(p2[0] + BIAS); ty2.append(p2[1] + BIAS)
        start.append(len(flat))
        flat.extend(out)
    start.append(len(flat))

    text = HEADER % dict(nodes=len(tree.ab), leaves=len(tree.leaf_boxes),
                         span=2048, pts=pts_n, on_line=on_line, traces=tr_n,
                         longest=longest)
    text += "\n"
    text += "pub const ROOT: u32 = %d;\n\n" % root
    text += emit("N_AB", tree.ab) + emit("N_BB", tree.bb) + emit("N_CB", tree.cb)
    text += emit("N_CHILD0", tree.child0, 8, "u32") + emit("N_CHILD1", tree.child1, 8, "u32")
    text += emit("N_BBOX", tree.bbox)
    text += emit("PT_X", px) + emit("PT_Y", py) + emit("PT_SS", pss, 20, "u32")
    text += emit("TR_X1", tx1) + emit("TR_Y1", ty1)
    text += emit("TR_X2", tx2) + emit("TR_Y2", ty2)
    text += emit("TR_START", start, 20, "u32") + emit("TR_SS", flat, 20, "u32")

    bench = """// SPDX-License-Identifier: Apache-2.0
// GENERATED by ../../scripts/gen_vectors.py -- do not edit by hand.
// The same BSP tree as the crate's test vectors, without the expectations:
// the benchmark measures a descent and a traversal over real data.

"""
    bench += "pub const ROOT: u32 = %d;\n\n" % root
    bench += emit("N_AB", tree.ab) + emit("N_BB", tree.bb) + emit("N_CB", tree.cb)
    bench += emit("N_CHILD0", tree.child0, 8, "u32") + emit("N_CHILD1", tree.child1, 8, "u32")
    bench += emit("N_BBOX", tree.bbox)

    if "--write" in sys.argv:
        bench_path = ROOT / "bench" / "src" / "tree.cairo"
        if bench_path.parent.is_dir():
            bench_path.write_text(bench)
            print("wrote %s" % bench_path, file=sys.stderr)
        out_path = ROOT / "src" / "tests" / "vectors.cairo"
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(text)
        print("wrote %s: %d nodes, %d leaves, %d points (%d on a partition), "
              "%d traces, %d visits, longest %d"
              % (out_path, len(tree.ab), len(tree.leaf_boxes), pts_n, on_line,
                 tr_n, len(flat), longest), file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

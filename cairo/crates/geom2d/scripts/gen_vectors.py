#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate `src/tests/vectors.cairo` for the `geom2d` crate.

Everything here is computed twice: once with exact Python integers (the
reference the Cairo tests are asserted against) and once with floating
point, as an independent check of the integer version. A disagreement
between the two on a case where the exact cross product is not tiny aborts
the generation.

Four families of vectors:

* `PS_*`   -- 1 000 (line, point) pairs: the three biased half-plane
              coefficients, the point, and the side Doom's
              `P_PointOnLineSide` returns.
* `BR_*`   --   600 (box, segment) pairs: whether `bbox_reject` must reject,
              and whether the segment really crosses the open box (the
              property "a rejection never drops a true crossing").
* `BL_*`   --   600 (line, box) pairs: what `P_BoxOnLineSide` returns
              (0 front, 1 back, 2 crossing).
* `IV_*`   --   200 divline pairs: `P_InterceptVector`'s fraction.
* `AD_*`   --   200 delta pairs: `P_AproxDistance`.

Usage: python3 scripts/gen_vectors.py --write && scarb fmt -p geom2d
"""

from __future__ import annotations

import sys
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIAS = 1 << 32           # fixed::BIAS
COEF_BIAS = 1 << 17      # geom2d::COEF_BIAS
CONST_BIAS = 1 << 50     # geom2d::CONST_BIAS
UNIT = 65536
SIDE_FRONT, SIDE_BACK, SIDE_CROSS = 0, 1, 2


# --------------------------------------------------------------------------
# deterministic generator
# --------------------------------------------------------------------------

class Rng:
    def __init__(self, seed: int) -> None:
        self.s = seed

    def next(self) -> int:
        self.s = (self.s * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        return self.s >> 11

    def units(self, span: int) -> int:
        """Integer map units in [-span, span]."""
        return self.next() % (2 * span + 1) - span

    def raw(self, span_units: int) -> int:
        """Raw 16.16 coordinate within +/- span_units map units."""
        return self.next() % (2 * span_units * UNIT + 1) - span_units * UNIT


# --------------------------------------------------------------------------
# reference implementations (exact integers)
# --------------------------------------------------------------------------

def half_plane(v1: tuple[int, int], v2: tuple[int, int]) -> tuple[int, int, int]:
    """Biased coefficients (ab, bb, cb) of the line v1 -> v2.

    v1, v2 are raw 16.16 coordinates of integral map units."""
    ldx = (v2[0] - v1[0]) >> 16
    ldy = (v2[1] - v1[1]) >> 16
    a, b = ldx, -ldy
    c = ldy * v1[0] - ldx * v1[1]
    return (a + COEF_BIAS, b + COEF_BIAS, c - (a + b) * BIAS + CONST_BIAS)


def cross(v1: tuple[int, int], v2: tuple[int, int], p: tuple[int, int]) -> int:
    ldx = (v2[0] - v1[0]) >> 16
    ldy = (v2[1] - v1[1]) >> 16
    return ldx * p[1] - ldy * p[0] + (ldy * v1[0] - ldx * v1[1])


def point_side(v1, v2, p) -> int:
    return SIDE_BACK if cross(v1, v2, p) >= 0 else SIDE_FRONT


def point_side_float(v1, v2, p) -> int:
    ldx = float((v2[0] - v1[0]) >> 16)
    ldy = float((v2[1] - v1[1]) >> 16)
    c = ldx * (p[1] - v1[1]) - ldy * (p[0] - v1[0])
    return SIDE_BACK if c >= 0 else SIDE_FRONT


def diagonal(v1, v2) -> int:
    ldx = (v2[0] - v1[0]) >> 16
    ldy = (v2[1] - v1[1]) >> 16
    return 1 if (ldx < 0) != (ldy < 0) else 0


def box_on_line_side(v1, v2, box) -> int:
    left, bottom, right, top = box
    if diagonal(v1, v2) == 0:
        p1, p2 = (left, top), (right, bottom)
    else:
        p1, p2 = (right, top), (left, bottom)
    s1, s2 = point_side(v1, v2, p1), point_side(v1, v2, p2)
    return s1 if s1 == s2 else SIDE_CROSS


def bbox_reject(a, b) -> bool:
    """a, b are (left, bottom, right, top). Doom's PIT_CheckLine early-out."""
    return (a[2] <= b[0]) or (a[0] >= b[2]) or (a[3] <= b[1]) or (a[1] >= b[3])


def segment_crosses_open_box(p0, p1, box) -> bool:
    """Exact (rational) Liang-Barsky clip against the *open* box."""
    left, bottom, right, top = box
    x0, y0 = Fraction(p0[0]), Fraction(p0[1])
    dx, dy = Fraction(p1[0] - p0[0]), Fraction(p1[1] - p0[1])
    t0, t1 = Fraction(0), Fraction(1)
    for p, q in ((-dx, x0 - left), (dx, right - x0), (-dy, y0 - bottom), (dy, top - y0)):
        if p == 0:
            if q <= 0:
                return False
        else:
            r = Fraction(q, p)
            if p < 0:
                if r > t1:
                    return False
                if r > t0:
                    t0 = r
            else:
                if r < t0:
                    return False
                if r < t1:
                    t1 = r
    return t0 < t1


def fixed_mul(a: int, b: int) -> int:
    return (a * b) >> 16


def fixed_div(a: int, b: int) -> int:
    if (abs(a) >> 14) >= abs(b):
        return -(1 << 31) if (a < 0) != (b < 0) else (1 << 31) - 1
    q = abs(a << 16) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def shr8(a: int) -> int:
    return a >> 8


def intercept_fraction(v2, v1) -> int:
    """P_InterceptVector(v2, v1); divlines are (x, y, dx, dy) raw."""
    num = fixed_mul(shr8(v1[0] - v2[0]), v1[3]) + fixed_mul(shr8(v2[1] - v1[1]), v1[2])
    den = fixed_mul(shr8(v1[3]), v2[2]) - fixed_mul(shr8(v1[2]), v2[3])
    if den == 0:
        return 0
    return fixed_div(num, den)


def approx_distance(dx: int, dy: int) -> int:
    dx, dy = abs(dx), abs(dy)
    return dx + dy - (min(dx, dy) >> 1)


# --------------------------------------------------------------------------
# emission
# --------------------------------------------------------------------------

def emit(name: str, values: list[int], per_line: int = 6) -> str:
    body = ",\n    ".join(
        ", ".join(str(v) for v in values[i:i + per_line])
        for i in range(0, len(values), per_line)
    )
    return "pub const %s: [felt252; %d] = [\n    %s,\n];\n\n" % (name, len(values), body)


HEADER = """// SPDX-License-Identifier: Apache-2.0
// GENERATED by scripts/gen_vectors.py -- do not edit by hand.
//
// Reference vectors for `geom2d`, computed with exact Python integers and
// cross-checked against a floating-point implementation of the same
// predicates (%(ps_float)d/%(ps_n)d point-side cases agreed; the generator
// aborts on any disagreement whose exact cross product exceeds one ulp).
//
// Coordinates are in the `fixed` offset encoding (`enc = raw + 2^32`);
// half-plane coefficients are biased with `COEF_BIAS = 2^17` and
// `CONST_BIAS = 2^50`, exactly as `geom2d::half_plane` produces them.
//
// %(br_cross)d of the %(br_n)d (box, segment) pairs really cross the open
// box, and the generator checks that `bbox_reject` rejects none of them --
// the property the Cairo test re-checks on the crate's own implementation.
// %(bl_cross)d of the %(bl_n)d (line, box) pairs straddle the line.
"""


def main() -> int:
    rng = Rng(0xD00D1234)
    lines = []

    # -- point_side ---------------------------------------------------------
    ps_n = 1000
    ab, bb, cb, px, py, side = [], [], [], [], [], []
    v1s, v2s = [], []
    float_agree = 0
    # The first cases are the degenerate ones: axis-aligned lines and points
    # exactly on the line, which the general formula must still classify the
    # way Doom's `!dx` / `!dy` branches do.
    special = [
        ((0, 0), (64, 0), (32, 0)),      # point on a horizontal line
        ((0, 0), (64, 0), (32, 1)),      # just above
        ((0, 0), (64, 0), (32, -1)),     # just below
        ((0, 0), (0, 64), (0, 32)),      # point on a vertical line
        ((0, 0), (0, 64), (1, 32)),
        ((0, 0), (0, 64), (-1, 32)),
        ((0, 0), (64, 64), (32, 32)),    # on a diagonal
        ((64, 0), (0, 0), (32, 1)),      # reversed horizontal
        ((0, 64), (0, 0), (1, 32)),      # reversed vertical
        ((0, 0), (64, -64), (32, -32)),  # negative slope, on the line
    ]
    for k in range(ps_n):
        if k < len(special):
            a, b, p = special[k]
            v1 = (a[0] * UNIT, a[1] * UNIT)
            v2 = (b[0] * UNIT, b[1] * UNIT)
            pt = (p[0] * UNIT, p[1] * UNIT)
        else:
            v1 = (rng.units(2048) * UNIT, rng.units(2048) * UNIT)
            v2 = (rng.units(2048) * UNIT, rng.units(2048) * UNIT)
            pt = (rng.raw(2048), rng.raw(2048))
        c = cross(v1, v2, pt)
        s = SIDE_BACK if c >= 0 else SIDE_FRONT
        f = point_side_float(v1, v2, pt)
        if f == s:
            float_agree += 1
        elif abs(c) > (1 << 20):
            raise SystemExit("float and integer disagree on a non-degenerate case: "
                             "%s %s %s cross=%d" % (v1, v2, pt, c))
        h = half_plane(v1, v2)
        ab.append(h[0]); bb.append(h[1]); cb.append(h[2])
        px.append(pt[0] + BIAS); py.append(pt[1] + BIAS)
        side.append(s)
        v1s.append(v1); v2s.append(v2)

    # -- bbox_reject --------------------------------------------------------
    br_n = 600
    b_l, b_b, b_r, b_t = [], [], [], []
    s_x0, s_y0, s_x1, s_y1 = [], [], [], []
    br_reject, br_crosses = [], []
    crossing = 0
    for k in range(br_n):
        cx, cy = rng.raw(1024), rng.raw(1024)
        r = (rng.next() % 64 + 1) * UNIT
        box = (cx - r, cy - r, cx + r, cy + r)
        if k % 2 == 0:
            # Half the cases are built to really cross: pick a point inside
            # the box and draw a segment through it. Without this, random
            # segments miss a small box ~99 % of the time and the property
            # "a rejection never drops a true crossing" is never exercised.
            ix = cx + rng.next() % (2 * r) - r
            iy = cy + rng.next() % (2 * r) - r
            hx, hy = rng.raw(128), rng.raw(128)
            p0 = (ix - hx, iy - hy)
            p1 = (ix + hx, iy + hy)
        else:
            p0 = (rng.raw(1024), rng.raw(1024))
            p1 = (p0[0] + rng.raw(128), p0[1] + rng.raw(128))
        seg = (min(p0[0], p1[0]), min(p0[1], p1[1]), max(p0[0], p1[0]), max(p0[1], p1[1]))
        rej = bbox_reject(box, seg)
        cr = segment_crosses_open_box(p0, p1, box)
        if cr:
            crossing += 1
            assert not rej, "bbox_reject dropped a true crossing: %s %s" % (box, (p0, p1))
        b_l.append(box[0] + BIAS); b_b.append(box[1] + BIAS)
        b_r.append(box[2] + BIAS); b_t.append(box[3] + BIAS)
        s_x0.append(p0[0] + BIAS); s_y0.append(p0[1] + BIAS)
        s_x1.append(p1[0] + BIAS); s_y1.append(p1[1] + BIAS)
        br_reject.append(1 if rej else 0)
        br_crosses.append(1 if cr else 0)

    # -- box_on_line_side ---------------------------------------------------
    bl_n = 600
    l_ab, l_bb, l_cb, l_diag = [], [], [], []
    x_l, x_b, x_r, x_t, bl_side = [], [], [], [], []
    straddling = 0
    for _ in range(bl_n):
        v1 = (rng.units(1024) * UNIT, rng.units(1024) * UNIT)
        v2 = (rng.units(1024) * UNIT, rng.units(1024) * UNIT)
        cx, cy = rng.raw(1024), rng.raw(1024)
        r = (rng.next() % 128 + 1) * UNIT
        box = (cx - r, cy - r, cx + r, cy + r)
        s = box_on_line_side(v1, v2, box)
        if s == SIDE_CROSS:
            straddling += 1
        h = half_plane(v1, v2)
        l_ab.append(h[0]); l_bb.append(h[1]); l_cb.append(h[2])
        l_diag.append(diagonal(v1, v2))
        x_l.append(box[0] + BIAS); x_b.append(box[1] + BIAS)
        x_r.append(box[2] + BIAS); x_t.append(box[3] + BIAS)
        bl_side.append(s)

    # -- intercept_fraction -------------------------------------------------
    iv_n = 200
    iv = [[] for _ in range(9)]
    for _ in range(iv_n):
        a = (rng.raw(512), rng.raw(512), rng.raw(256), rng.raw(256))
        b = (rng.raw(512), rng.raw(512), rng.raw(256), rng.raw(256))
        frac = intercept_fraction(a, b)
        for i, v in enumerate(a):
            iv[i].append(v + BIAS)
        for i, v in enumerate(b):
            iv[4 + i].append(v + BIAS)
        iv[8].append(frac + BIAS)

    # -- approx_distance ----------------------------------------------------
    ad_n = 200
    ad_x, ad_y, ad_r = [], [], []
    for k in range(ad_n):
        dx = 0 if k == 0 else rng.raw(2048)
        dy = 0 if k < 2 else rng.raw(2048)
        ad_x.append(dx + BIAS); ad_y.append(dy + BIAS)
        ad_r.append(approx_distance(dx, dy) + BIAS)

    text = HEADER % dict(ps_float=float_agree, ps_n=ps_n, br_cross=crossing, br_n=br_n,
                         bl_cross=straddling, bl_n=bl_n)
    text += "\n"
    text += emit("PS_AB", ab) + emit("PS_BB", bb) + emit("PS_CB", cb)
    text += emit("PS_X_ENC", px) + emit("PS_Y_ENC", py) + emit("PS_SIDE", side, 20)
    text += "/// The two vertices the coefficients above were built from, so that\n"
    text += "/// `half_plane()` can be checked against the generator.\n"
    text += emit("PS_V1X_ENC", [v[0] + BIAS for v in v1s])
    text += emit("PS_V1Y_ENC", [v[1] + BIAS for v in v1s])
    text += emit("PS_V2X_ENC", [v[0] + BIAS for v in v2s])
    text += emit("PS_V2Y_ENC", [v[1] + BIAS for v in v2s])
    text += emit("BR_BOX_L", b_l) + emit("BR_BOX_B", b_b)
    text += emit("BR_BOX_R", b_r) + emit("BR_BOX_T", b_t)
    text += emit("BR_SEG_X0", s_x0) + emit("BR_SEG_Y0", s_y0)
    text += emit("BR_SEG_X1", s_x1) + emit("BR_SEG_Y1", s_y1)
    text += emit("BR_REJECT", br_reject, 20) + emit("BR_CROSSES", br_crosses, 20)
    text += emit("BL_AB", l_ab) + emit("BL_BB", l_bb) + emit("BL_CB", l_cb)
    text += emit("BL_DIAG", l_diag, 20)
    text += emit("BL_BOX_L", x_l) + emit("BL_BOX_B", x_b)
    text += emit("BL_BOX_R", x_r) + emit("BL_BOX_T", x_t)
    text += emit("BL_SIDE", bl_side, 20)
    names = ["IV_AX", "IV_AY", "IV_ADX", "IV_ADY", "IV_BX", "IV_BY", "IV_BDX", "IV_BDY", "IV_FRAC"]
    for name, col in zip(names, iv):
        text += emit(name, col)
    text += emit("AD_DX", ad_x) + emit("AD_DY", ad_y) + emit("AD_DIST", ad_r)

    if "--write" in sys.argv:
        out = ROOT / "src" / "tests" / "vectors.cairo"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
        print("wrote %s" % out, file=sys.stderr)
        print("point_side: %d cases (%d float agreements), bbox: %d (%d crossing), "
              "box_on_line: %d (%d straddling)"
              % (ps_n, float_agree, br_n, crossing, bl_n, straddling), file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

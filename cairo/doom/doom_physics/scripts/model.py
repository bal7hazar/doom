#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Reference models for `doom_physics`, over `tools/wad`'s JSON of a map.

Three independent models, each a transcription of the linuxdoom-1.10 rule it
checks and **not** of the Cairo code:

* **movement** (`p_map.c` `P_CheckPosition`/`P_TryMove`, `p_mobj.c`
  friction): exact integer arithmetic on raw 16.16 values, the same exact
  half-plane predicate `geom2d` stores, so the expectations are bit-exact;
* **sight** (`p_sight.c`): an exact-rational transcription over every
  linedef the trace crosses, cross-checked against a *float* transcription of
  Doom's own BSP walk over the SEGS (`P_CrossBSPNode`/`P_CrossSubsector`).
  Only pairs on which the two agree, with a slope margin, are emitted -- so
  the vectors also demonstrate that walking the blockmap ray (what the Cairo
  crate does, since SEGS are not compiled in) answers like the BSP walk;
* **hitscan** (`p_map.c` `PTR_ShootTraverse`): a float ray cast over every
  linedef, keeping the nearest blocking crossing; ambiguous shots (two
  candidates within a thousandth of the range, or a hit within a unit of a
  vertex) are dropped.

`--write` emits `src/tests/vectors.cairo`; the Cairo tests replay every
vector. Coordinates are emitted in `fixed`'s offset encoding
(`enc = raw + 2^32`) so that every felt stays non-negative and below 2^72.

Usage:
    python3 model.py --json /tmp/wadout/e1m1.json [--write] [--seed 1]
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
from fractions import Fraction
from pathlib import Path

HERE = Path(__file__).resolve().parent
CRATE = HERE.parent

FRACUNIT = 65536
BIAS = 1 << 32
MAPBLOCK = 128
MAXSTEP = 24 * FRACUNIT
FRICTION = 0xE800
STOPSPEED = 0x1000
MAXRADIUS = 32 * FRACUNIT
ML_BLOCKING = 1
ML_BLOCKMONSTERS = 2
ML_TWOSIDED = 4
NO_LINE = 0xFFFF
FINEANGLES = 8192
ANGLETOFINESHIFT = 19


def enc(raw: int) -> int:
    return raw + BIAS


def fixed_mul(a: int, b: int) -> int:
    """Doom's `FixedMul`: the 32.32 product arithmetically shifted down."""
    return (a * b) >> 16


# --------------------------------------------------------------------------
# Level
# --------------------------------------------------------------------------


class Line:
    __slots__ = ("id", "v1", "v2", "flags", "special", "front", "back", "box")

    def __init__(self, i: int, v1, v2, flags, special, front, back) -> None:
        self.id = i
        self.v1 = v1  # raw
        self.v2 = v2
        self.flags = flags
        self.special = special
        self.front = front  # sector index or None
        self.back = back
        self.box = (
            min(v1[0], v2[0]),
            min(v1[1], v2[1]),
            max(v1[0], v2[0]),
            max(v1[1], v2[1]),
        )  # left, bottom, right, top

    @property
    def ldx(self) -> int:
        return (self.v2[0] - self.v1[0]) // FRACUNIT

    @property
    def ldy(self) -> int:
        return (self.v2[1] - self.v1[1]) // FRACUNIT

    @property
    def diagonal(self) -> int:
        return 1 if (self.ldx < 0) != (self.ldy < 0) else 0

    @property
    def two_sided(self) -> bool:
        return bool(self.flags & ML_TWOSIDED)


class Level:
    def __init__(self, doc: dict) -> None:
        verts = [(v["x"] * FRACUNIT, v["y"] * FRACUNIT) for v in doc["vertexes"]]
        sides = doc["sidedefs"]
        self.lines: list[Line] = []
        for i, ld in enumerate(doc["linedefs"]):
            f = ld["frontSidedef"]
            b = ld["backSidedef"]
            front = sides[f]["sector"] if 0 <= f < len(sides) else None
            back = sides[b]["sector"] if 0 <= b < len(sides) else None
            self.lines.append(
                Line(
                    i,
                    verts[ld["startVertex"]],
                    verts[ld["endVertex"]],
                    ld["flags"] & 0xFFFF,
                    ld["specialType"],
                    front,
                    back,
                )
            )
        self.verts = verts
        self.sectors = [
            (s["floorHeight"] * FRACUNIT, s["ceilingHeight"] * FRACUNIT) for s in doc["sectors"]
        ]
        self.nodes = doc["nodes"]
        self.subsectors = doc["subsectors"]
        self.segs = doc["segs"]
        self.ss_sector = doc["derived"]["subsectorSectors"]
        bm = doc["blockmap"]
        self.origin = (bm["originX"] * FRACUNIT, bm["originY"] * FRACUNIT)
        self.columns = bm["columns"]
        self.rows = bm["rows"]
        # Sorted and deduplicated per cell, exactly as `gen_level.py` emits
        # BM_ITEMS, so that "first blocking line" agrees with the Cairo loop.
        self.cells = [sorted(set(c)) for c in bm["cells"]]
        self.reject_raw = bytes.fromhex(doc["reject"]["dataHex"])
        self.num_sectors = doc["reject"]["numSectors"]

    # -- BSP ---------------------------------------------------------------

    def node_side(self, nd: dict, x: int, y: int) -> int:
        """`R_PointOnSide` over the exact predicate (0 front, 1 back)."""
        left = nd["dy"] * (x - nd["x"] * FRACUNIT)
        right = (y - nd["y"] * FRACUNIT) * nd["dx"]
        return 0 if right < left else 1

    def subsector_at(self, x: int, y: int) -> int:
        cur = len(self.nodes) - 1
        while not (cur & 0x8000):
            nd = self.nodes[cur]
            side = self.node_side(nd, x, y)
            cur = nd["rightChild"] if side == 0 else nd["leftChild"]
        return cur & 0x7FFF

    def sector_at(self, x: int, y: int) -> int:
        return self.ss_sector[self.subsector_at(x, y)]

    def reject(self, s1: int, s2: int) -> bool:
        pnum = s1 * self.num_sectors + s2
        return bool(self.reject_raw[pnum >> 3] & (1 << (pnum & 7)))

    # -- blockmap ----------------------------------------------------------

    def axis_cell(self, origin: int, v: int, count: int) -> tuple[int, int]:
        """`blockmap::axis_cell`: (clamped cell, 0 inside / 1 below / 2 above)."""
        if v < origin:
            return 0, 1
        c = (v - origin) // (MAPBLOCK * FRACUNIT)
        if c >= count:
            return count - 1, 2
        return c, 0

    def cell_of(self, x: int, y: int):
        cx, ox = self.axis_cell(self.origin[0], x, self.columns)
        cy, oy = self.axis_cell(self.origin[1], y, self.rows)
        if ox or oy:
            return None
        return cx, cy

    def cells_of_box(self, box):
        x0, ox0 = self.axis_cell(self.origin[0], box[0], self.columns)
        x1, ox1 = self.axis_cell(self.origin[0], box[2], self.columns)
        if ox1 == 1 or ox0 == 2:
            return None
        y0, oy0 = self.axis_cell(self.origin[1], box[1], self.rows)
        y1, oy1 = self.axis_cell(self.origin[1], box[3], self.rows)
        if oy1 == 1 or oy0 == 2:
            return None
        return x0, y0, x1, y1

    def cell_lines(self, cx: int, cy: int) -> list[int]:
        return self.cells[cy * self.columns + cx]


# --------------------------------------------------------------------------
# Predicates (exact integers on raw coordinates)
# --------------------------------------------------------------------------


def point_on_line_side(x: int, y: int, ln: Line) -> int:
    """`P_PointOnLineSide`, exact: 0 front, 1 back (on the line is back)."""
    cross = ln.ldx * (y - ln.v1[1]) - ln.ldy * (x - ln.v1[0])
    return 1 if cross >= 0 else 0


def divline_side(x: int, y: int, px: int, py: int, dx: int, dy: int) -> int:
    """`P_DivlineSide` on a raw divline (dx, dy raw): 0, 1, or 2 on the line."""
    cross = dx * (y - py) - dy * (x - px)
    if cross == 0:
        return 2
    return 1 if cross > 0 else 0


def bbox_reject(a, b) -> bool:
    """Doom's `PIT_CheckLine` box test: touching boxes are rejected."""
    return b[0] >= a[2] or a[0] >= b[2] or b[1] >= a[3] or a[1] >= b[3]


def box_on_line_side(box, ln: Line) -> int:
    """`P_BoxOnLineSide`: 0, 1, or 2 when the box straddles the line."""
    left, bottom, right, top = box
    if ln.diagonal == 0:
        p1, p2 = (left, top), (right, bottom)
    else:
        p1, p2 = (right, top), (left, bottom)
    s1 = point_on_line_side(p1[0], p1[1], ln)
    s2 = point_on_line_side(p2[0], p2[1], ln)
    return s1 if s1 == s2 else 2


def intercept_fraction(tx, ty, tdx, tdy, lx, ly, ldx, ldy) -> Fraction:
    """`P_InterceptVector`, exact: the fraction along the trace at which it
    crosses the (infinite) line."""
    den = ldy * tdx - ldx * tdy
    if den == 0:
        return Fraction(0)
    num = (lx - tx) * ldy + (ty - ly) * ldx
    return Fraction(num, den)


# --------------------------------------------------------------------------
# Movement model (P_CheckPosition / P_TryMove)
# --------------------------------------------------------------------------


class Mobj:
    def __init__(self, x, y, z, radius, height, player: bool) -> None:
        self.x, self.y, self.z = x, y, z
        self.radius, self.height = radius, height
        self.player = player


def check_position(lv: Level, mo: Mobj, x: int, y: int):
    """Returns (ok, floorz, ceilingz, dropoffz, blocker, straddled)."""
    box = (x - mo.radius, y - mo.radius, x + mo.radius, y + mo.radius)
    sec = lv.sectors[lv.sector_at(x, y)]
    floorz = dropoffz = sec[0]
    ceilingz = sec[1]
    straddled: list[int] = []
    rng = lv.cells_of_box(box)
    if rng is None:
        return True, floorz, ceilingz, dropoffz, NO_LINE, straddled
    x0, y0, x1, y1 = rng
    # Row-major over the range, as `blockmap::range_cell` enumerates it.
    for cy in range(y0, y1 + 1):
        for cx in range(x0, x1 + 1):
            for li in lv.cell_lines(cx, cy):
                ln = lv.lines[li]
                if bbox_reject(box, ln.box):
                    continue
                if box_on_line_side(box, ln) != 2:
                    continue
                if ln.back is None:
                    return False, floorz, ceilingz, dropoffz, li, straddled
                if ln.flags & ML_BLOCKING:
                    return False, floorz, ceilingz, dropoffz, li, straddled
                if not mo.player and ln.flags & ML_BLOCKMONSTERS:
                    return False, floorz, ceilingz, dropoffz, li, straddled
                f = lv.sectors[ln.front]
                b = lv.sectors[ln.back]
                opentop = min(f[1], b[1])
                openbottom = max(f[0], b[0])
                lowfloor = min(f[0], b[0])
                if opentop < ceilingz:
                    ceilingz = opentop
                if openbottom > floorz:
                    floorz = openbottom
                if lowfloor < dropoffz:
                    dropoffz = lowfloor
                if ln.special:
                    straddled.append(li)
    return True, floorz, ceilingz, dropoffz, NO_LINE, straddled


def try_move(lv: Level, mo: Mobj, x: int, y: int):
    """Returns (ok, floorz, ceilingz, dropoffz, blocker, crossed_specials)."""
    ok, floorz, ceilingz, dropoffz, blocker, straddled = check_position(lv, mo, x, y)
    if not ok:
        return False, floorz, ceilingz, dropoffz, blocker, []
    if ceilingz - floorz < mo.height:
        return False, floorz, ceilingz, dropoffz, NO_LINE, []
    if ceilingz - mo.z < mo.height:
        return False, floorz, ceilingz, dropoffz, NO_LINE, []
    if floorz - mo.z > MAXSTEP:
        return False, floorz, ceilingz, dropoffz, NO_LINE, []
    if not mo.player and floorz - dropoffz > MAXSTEP:
        return False, floorz, ceilingz, dropoffz, NO_LINE, []
    crossed = []
    for li in straddled:
        ln = lv.lines[li]
        if point_on_line_side(x, y, ln) != point_on_line_side(mo.x, mo.y, ln):
            crossed.append(li)
    return True, floorz, ceilingz, dropoffz, NO_LINE, crossed


def friction_run(momx: int, momy: int, tics: int) -> list[tuple[int, int]]:
    """`P_XYMovement`'s friction, on a thing standing on its floor with no
    player input, for `tics` tics (the STOPSPEED rule included)."""
    out = []
    for _ in range(tics):
        if -STOPSPEED < momx < STOPSPEED and -STOPSPEED < momy < STOPSPEED:
            momx = momy = 0
        else:
            momx = fixed_mul(momx, FRICTION)
            momy = fixed_mul(momy, FRICTION)
        out.append((momx, momy))
    return out


# --------------------------------------------------------------------------
# Sight models
# --------------------------------------------------------------------------


def check_sight_exact(lv: Level, t1, t2) -> tuple[bool, Fraction | None]:
    """`P_CheckSight` in exact rationals over every crossed linedef.

    Returns (visible, margin) where `margin` is `topslope - bottomslope` at the
    end of a visible trace (None when blocked by a wall or a closed opening),
    in raw units of dz per full trace length.
    """
    x1, y1, z1, h1 = t1
    x2, y2, z2, h2 = t2
    sightz = z1 + h1 - (h1 >> 2)
    top = Fraction(z2 + h2 - sightz)
    bottom = Fraction(z2 - sightz)
    tdx, tdy = x2 - x1, y2 - y1
    for ln in lv.lines:
        ldx_raw = ln.v2[0] - ln.v1[0]
        ldy_raw = ln.v2[1] - ln.v1[1]
        a = divline_side(x1, y1, ln.v1[0], ln.v1[1], ldx_raw, ldy_raw)
        b = divline_side(x2, y2, ln.v1[0], ln.v1[1], ldx_raw, ldy_raw)
        if a == b:
            continue
        c = divline_side(ln.v1[0], ln.v1[1], x1, y1, tdx, tdy)
        d = divline_side(ln.v2[0], ln.v2[1], x1, y1, tdx, tdy)
        if c == d:
            continue
        if not ln.two_sided:
            return False, None
        f = lv.sectors[ln.front]
        bk = lv.sectors[ln.back]
        if f[0] == bk[0] and f[1] == bk[1]:
            continue
        opentop = min(f[1], bk[1])
        openbottom = max(f[0], bk[0])
        if openbottom >= opentop:
            return False, None
        frac = intercept_fraction(x1, y1, tdx, tdy, ln.v1[0], ln.v1[1], ldx_raw, ldy_raw)
        if frac == 0:
            continue
        if f[0] != bk[0]:
            slope = Fraction(openbottom - sightz) / frac
            if slope > bottom:
                bottom = slope
        if f[1] != bk[1]:
            slope = Fraction(opentop - sightz) / frac
            if slope < top:
                top = slope
        if top <= bottom:
            return False, top - bottom
    return True, top - bottom


class FloatSight:
    """Doom's `P_CheckSight` BSP walk over the SEGS, in floating point."""

    def __init__(self, lv: Level, t1, t2) -> None:
        self.lv = lv
        x1, y1, z1, h1 = t1
        x2, y2, z2, h2 = t2
        self.x1, self.y1 = x1 / FRACUNIT, y1 / FRACUNIT
        self.x2, self.y2 = x2 / FRACUNIT, y2 / FRACUNIT
        self.dx, self.dy = self.x2 - self.x1, self.y2 - self.y1
        sightz = (z1 + h1 - (h1 >> 2)) / FRACUNIT
        self.sightz = sightz
        self.top = (z2 + h2) / FRACUNIT - sightz
        self.bottom = z2 / FRACUNIT - sightz
        self.seen: set[int] = set()

    @staticmethod
    def side(x, y, px, py, dx, dy) -> int:
        cross = dx * (y - py) - dy * (x - px)
        if abs(cross) < 1e-9:
            return 2
        return 1 if cross > 0 else 0

    def cross_subsector(self, num: int) -> bool:
        sub = self.lv.subsectors[num]
        for k in range(sub["numSegs"]):
            sg = self.lv.segs[sub["firstSeg"] + k]
            li = sg["linedef"]
            if li in self.seen:
                continue
            self.seen.add(li)
            ln = self.lv.lines[li]
            v1 = (ln.v1[0] / FRACUNIT, ln.v1[1] / FRACUNIT)
            v2 = (ln.v2[0] / FRACUNIT, ln.v2[1] / FRACUNIT)
            s1 = self.side(v1[0], v1[1], self.x1, self.y1, self.dx, self.dy)
            s2 = self.side(v2[0], v2[1], self.x1, self.y1, self.dx, self.dy)
            if s1 == s2:
                continue
            ldx, ldy = v2[0] - v1[0], v2[1] - v1[1]
            s1 = self.side(self.x1, self.y1, v1[0], v1[1], ldx, ldy)
            s2 = self.side(self.x2, self.y2, v1[0], v1[1], ldx, ldy)
            if s1 == s2:
                continue
            if not ln.two_sided:
                return False
            f = self.lv.sectors[ln.front]
            b = self.lv.sectors[ln.back]
            if f[0] == b[0] and f[1] == b[1]:
                continue
            opentop = min(f[1], b[1]) / FRACUNIT
            openbottom = max(f[0], b[0]) / FRACUNIT
            if openbottom >= opentop:
                return False
            den = ldy * self.dx - ldx * self.dy
            if den == 0:
                continue
            frac = ((v1[0] - self.x1) * ldy + (self.y1 - v1[1]) * ldx) / den
            if frac == 0:
                continue
            if f[0] != b[0]:
                slope = (openbottom - self.sightz) / frac
                if slope > self.bottom:
                    self.bottom = slope
            if f[1] != b[1]:
                slope = (opentop - self.sightz) / frac
                if slope < self.top:
                    self.top = slope
            if self.top <= self.bottom:
                return False
        return True

    def cross_node(self, num: int) -> bool:
        if num & 0x8000:
            return self.cross_subsector(num & 0x7FFF)
        nd = self.lv.nodes[num]
        px, py, ndx, ndy = nd["x"], nd["y"], nd["dx"], nd["dy"]
        side = self.side(self.x1, self.y1, px, py, ndx, ndy)
        if side == 2:
            side = 0
        near = nd["rightChild"] if side == 0 else nd["leftChild"]
        far = nd["leftChild"] if side == 0 else nd["rightChild"]
        if not self.cross_node(near):
            return False
        if side == self.side(self.x2, self.y2, px, py, ndx, ndy):
            return True
        return self.cross_node(far)

    def run(self) -> bool:
        return self.cross_node(len(self.lv.nodes) - 1)


# --------------------------------------------------------------------------
# Hitscan model (float ray cast, PTR_ShootTraverse rules)
# --------------------------------------------------------------------------


def fine_cos_sin(angle: int) -> tuple[float, float]:
    """`bam`'s tables sample `sin((i + 0.5) * 2pi / 8192)` at fine index `i`."""
    idx = (angle >> ANGLETOFINESHIFT) & (FINEANGLES - 1)
    a = (idx + 0.5) * 2 * math.pi / FINEANGLES
    return math.cos(a), math.sin(a)


def ray_cast(lv: Level, x: int, y: int, z: int, height: int, angle: int, aimslope: int, range_units: int):
    """The nearest crossing that stops a shot. Returns
    (line id, hit x, hit y, hit z (floats, map units), ambiguous)."""
    shootz = (z + (height >> 1) + 8 * FRACUNIT) / FRACUNIT
    aim = aimslope / FRACUNIT
    fx, fy = x / FRACUNIT, y / FRACUNIT
    c, s = fine_cos_sin(angle)
    dx, dy = range_units * c, range_units * s
    hits: list[tuple[float, int]] = []
    for ln in lv.lines:
        v1 = (ln.v1[0] / FRACUNIT, ln.v1[1] / FRACUNIT)
        v2 = (ln.v2[0] / FRACUNIT, ln.v2[1] / FRACUNIT)
        ldx, ldy = v2[0] - v1[0], v2[1] - v1[1]
        den = ldy * dx - ldx * dy
        if den == 0:
            continue
        frac = ((v1[0] - fx) * ldy + (fy - v1[1]) * ldx) / den
        if frac < 0 or frac >= 1:
            continue
        # Position along the line, in [0, 1].
        if abs(ldx) >= abs(ldy):
            u = (fx + dx * frac - v1[0]) / ldx
        else:
            u = (fy + dy * frac - v1[1]) / ldy
        if u < 0 or u > 1:
            continue
        near_vertex = u < 0.02 or u > 0.98 or frac < 1e-6
        blocks = False
        if not ln.two_sided:
            blocks = True
        else:
            f = lv.sectors[ln.front]
            b = lv.sectors[ln.back]
            opentop = min(f[1], b[1]) / FRACUNIT
            openbottom = max(f[0], b[0]) / FRACUNIT
            dist = max(range_units * frac, 1e-9)
            if f[0] != b[0] and (openbottom - shootz) / dist > aim:
                blocks = True
            elif f[1] != b[1] and (opentop - shootz) / dist < aim:
                blocks = True
        if blocks:
            hits.append((frac, ln.id, near_vertex))
    if not hits:
        return None
    hits.sort()
    frac, li, near_vertex = hits[0]
    ambiguous = near_vertex or (len(hits) > 1 and hits[1][0] - frac < 1e-3)
    pulled = frac - 4.0 / range_units
    hx = fx + dx * pulled
    hy = fy + dy * pulled
    hz = shootz + aim * pulled * range_units
    return li, hx, hy, hz, ambiguous


# --------------------------------------------------------------------------
# Sampling
# --------------------------------------------------------------------------


def centroid(lv: Level, ss: int) -> tuple[int, int] | None:
    sub = lv.subsectors[ss]
    xs, ys = [], []
    for k in range(sub["numSegs"]):
        sg = lv.segs[sub["firstSeg"] + k]
        for vi in (sg["startVertex"], sg["endVertex"]):
            xs.append(lv.verts[vi][0])
            ys.append(lv.verts[vi][1])
    if not xs:
        return None
    return sum(xs) // len(xs), sum(ys) // len(ys)


def inside_point(lv: Level, rng: random.Random) -> tuple[int, int, int]:
    """A raw point inside the map: a subsector centroid (which a vanilla
    builder keeps inside its convex leaf) that really descends to that
    subsector, with the sector's floor."""
    while True:
        ss = rng.randrange(len(lv.subsectors))
        c = centroid(lv, ss)
        if c is None:
            continue
        x, y = c
        if lv.subsector_at(x, y) != ss:
            continue
        sec = lv.sectors[lv.ss_sector[ss]]
        if sec[1] - sec[0] < 56 * FRACUNIT:
            continue
        return x, y, sec[0]


def gen_moves(lv: Level, rng: random.Random, n: int) -> list[int]:
    out: list[int] = []
    ok_count = 0
    while len(out) < n * 15:
        x, y, floor = inside_point(lv, rng)
        player = rng.random() < 0.5
        radius = 16 * FRACUNIT if player else 20 * FRACUNIT
        height = 56 * FRACUNIT
        # Momenta with fractional parts, up to 30 units so that a good share
        # of moves reaches a wall.
        momx = rng.randrange(-30 * FRACUNIT, 30 * FRACUNIT)
        momy = rng.randrange(-30 * FRACUNIT, 30 * FRACUNIT)
        mo = Mobj(x, y, floor, radius, height, player)
        ok, floorz, ceilingz, dropoffz, blocker, crossed = try_move(lv, mo, x + momx, y + momy)
        ok_count += int(ok)
        out.extend(
            [
                enc(x),
                enc(y),
                enc(floor),
                radius // FRACUNIT,
                height // FRACUNIT,
                0 if player else 1,
                enc(momx),
                enc(momy),
                1 if ok else 0,
                enc(floorz),
                enc(ceilingz),
                enc(dropoffz),
                blocker,
                len(crossed),
                crossed[0] if crossed else NO_LINE,
            ]
        )
    print("moves: %d cases, %d accepted, %d blocked" % (n, ok_count, n - ok_count))
    return out


def gen_frictions(rng: random.Random, n: int, tics: int) -> list[int]:
    # Up to 12 units per tic: 12 tics of decay travel at most ~90 units,
    # which keeps the Cairo test's thing inside E1M1's start room.
    out: list[int] = []
    for _ in range(n):
        momx = rng.randrange(-12 * FRACUNIT, 12 * FRACUNIT)
        momy = rng.randrange(-12 * FRACUNIT, 12 * FRACUNIT)
        run = friction_run(momx, momy, tics)
        out.extend([enc(momx), enc(momy), enc(run[-1][0]), enc(run[-1][1])])
    return out


def gen_sights(lv: Level, rng: random.Random, n: int) -> list[int]:
    out: list[int] = []
    tried = dropped_disagree = dropped_margin = 0
    stats = [0, 0, 0]  # rejected, blocked, visible
    while len(out) < n * 10:
        tried += 1
        x1, y1, f1 = inside_point(lv, rng)
        x2, y2, f2 = inside_point(lv, rng)
        if (x1, y1) == (x2, y2):
            continue
        # Bias toward pairs that survive REJECT: most random pairs do not.
        s1 = lv.sector_at(x1, y1)
        s2 = lv.sector_at(x2, y2)
        rejected = lv.reject(s1, s2)
        if rejected and rng.random() < 0.75:
            continue
        t1 = (x1, y1, f1, 56 * FRACUNIT)
        t2 = (x2, y2, f2, 56 * FRACUNIT)
        if rejected:
            visible = False
        else:
            exact, margin = check_sight_exact(lv, t1, t2)
            flt = FloatSight(lv, t1, t2).run()
            if exact != flt:
                dropped_disagree += 1
                continue
            if margin is not None and abs(margin) < FRACUNIT // 8:
                dropped_margin += 1
                continue
            visible = exact
        stats[0 if rejected else (2 if visible else 1)] += 1
        out.extend(
            [enc(x1), enc(y1), enc(f1), enc(x2), enc(y2), enc(f2), s1, s2, int(rejected), int(visible)]
        )
    print(
        "sights: %d cases (%d rejected, %d blocked, %d visible) from %d tries; "
        "%d dropped (models disagree), %d dropped (margin)"
        % (n, stats[0], stats[1], stats[2], tried, dropped_disagree, dropped_margin)
    )
    return out


def gen_shots(lv: Level, rng: random.Random, n: int) -> list[int]:
    out: list[int] = []
    dropped = 0
    while len(out) < n * 9:
        x, y, floor = inside_point(lv, rng)
        angle = rng.randrange(0, 1 << 32)
        aimslope = rng.randrange(-FRACUNIT // 2, FRACUNIT // 2) if rng.random() < 0.5 else 0
        rng_units = 2048 if rng.random() < 0.5 else 1024
        res = ray_cast(lv, x, y, floor, 56 * FRACUNIT, angle, aimslope, rng_units)
        if res is None:
            dropped += 1
            continue
        li, hx, hy, hz, ambiguous = res
        if ambiguous:
            dropped += 1
            continue
        out.extend(
            [
                enc(x),
                enc(y),
                enc(floor),
                angle,
                enc(aimslope),
                rng_units,
                li,
                enc(round(hx * FRACUNIT)),
                enc(round(hy * FRACUNIT)),
            ]
        )
        # z is checked loosely by the test from the slope; not emitted.
    print("shots: %d cases, %d dropped (no hit in range or ambiguous)" % (n, dropped))
    return out


# --------------------------------------------------------------------------
# Scripted walk (P_Thrust + P_XYMovement + P_ZMovement, no wall contact)
# --------------------------------------------------------------------------

ANG90 = 0x40000000
ANG180 = 0x80000000
ANG270 = 0xC0000000
# (tics, angle, forwardmove): 350 tics from the Player 1 start.
WALK_SCRIPT = [
    (40, 0, 25),
    (30, 0, 0),
    (10, ANG90, 25),
    (25, ANG90, 0),
    (10, ANG270, 25),
    (25, ANG270, 0),
    (40, ANG180, 25),
    (30, ANG180, 0),
    (20, 0, 25),
    (120, 0, 0),
]
WALK_CHECKPOINT = 50


def finesine_table() -> list[int]:
    """`bam`'s quarter-wave magnitudes, read out of its generated source so
    that the thrust is bit-exact with the Cairo tables."""
    text = (CRATE.parent.parent / "crates" / "bam" / "src" / "tables.cairo").read_text()
    start = text.index("pub const FINESINE_Q")
    body = text[text.index("[", text.index("=", start)) + 1 : text.index("];", start)]
    return [int(v) for v in body.replace("\n", " ").split(",") if v.strip()]


def finesine(table: list[int], idx: int) -> int:
    negative = idx >= 4096
    half = idx - 4096 if negative else idx
    q = 4095 - half if half >= 2048 else half
    return -table[q] if negative else table[q]


def gen_walk(lv: Level, start: tuple[int, int, int]) -> tuple[list[int], int]:
    """Replay `WALK_SCRIPT` on the movement model: (checkpoints + final
    state, number of blocked moves). The Cairo test replays the same script
    with `xy_movement`; the two agree bit-exactly as long as no move is
    blocked (the model has no slide), which the count asserts."""
    table = finesine_table()
    x, y, z = start
    mo = Mobj(x, y, z, 16 * FRACUNIT, 56 * FRACUNIT, True)
    momx = momy = 0
    floorz = lv.sectors[lv.sector_at(x, y)][0]
    out: list[int] = []
    blocked = 0
    tic = 0
    for tics, angle, forward in WALK_SCRIPT:
        for _ in range(tics):
            if forward:
                idx = angle >> ANGLETOFINESHIFT
                move = forward * 2048
                momx += fixed_mul(move, finesine(table, (idx + 2048) % 8192))
                momy += fixed_mul(move, finesine(table, idx))
            if momx or momy:
                ok, fz, cz, dz, _, _ = try_move(lv, mo, mo.x + momx, mo.y + momy)
                if ok:
                    mo.x += momx
                    mo.y += momy
                    floorz = fz
                else:
                    blocked += 1
                    momx = momy = 0
                if mo.z <= floorz:
                    if -STOPSPEED < momx < STOPSPEED and -STOPSPEED < momy < STOPSPEED and not forward:
                        momx = momy = 0
                    else:
                        momx = fixed_mul(momx, FRICTION)
                        momy = fixed_mul(momy, FRICTION)
            # P_ZMovement on a walker: clamp to the floor.
            if mo.z <= floorz:
                mo.z = floorz
            tic += 1
            if tic % WALK_CHECKPOINT == 0:
                out.extend([enc(mo.x), enc(mo.y), enc(momx), enc(momy)])
    return out, blocked


# --------------------------------------------------------------------------
# Emission
# --------------------------------------------------------------------------

HEADER = """// SPDX-License-Identifier: GPL-2.0-only
//
//! GENERATED -- do not edit. Regenerate with
//! `python3 cairo/doom/doom_physics/scripts/model.py --json <e1m1.json> --write`.
//!
//! Independent expectations for `src/tests/e1m1.cairo`, computed by the
//! Python reference models of `scripts/model.py` from the WAD JSON -- never
//! from the Cairo code. Coordinates and momenta are `fixed` offset-encoded
//! (`enc = raw + 2^32`); ids are plain integers; `NO_LINE` is 65535.
"""


def emit_array(name: str, ty: str, values: list[int], doc: str) -> str:
    body = ", ".join(str(v) for v in values)
    return "/// %s\npub const %s: [%s; %d] = [%s];\n\n" % (doc, name, ty, len(values), body)


def lv_things(path: str) -> list[dict]:
    return json.loads(Path(path).read_text())["things"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", required=True)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--moves", type=int, default=300)
    ap.add_argument("--sights", type=int, default=500)
    ap.add_argument("--shots", type=int, default=200)
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    sys.setrecursionlimit(10000)
    lv = Level(json.loads(Path(args.json).read_text()))
    rng = random.Random(args.seed)
    moves = gen_moves(lv, rng, args.moves)
    frictions = gen_frictions(rng, 40, 12)
    sights = gen_sights(lv, rng, args.sights)
    shots = gen_shots(lv, rng, args.shots)
    start_thing = next(t for t in lv_things(args.json) if t["type"] == 1)
    sx, sy = start_thing["x"] * FRACUNIT, start_thing["y"] * FRACUNIT
    walk, blocked = gen_walk(lv, (sx, sy, lv.sectors[lv.sector_at(sx, sy)][0]))
    print(
        "walk: %d tics, %d checkpoints, %d blocked moves, ends at (%.1f, %.1f)"
        % (
            sum(t for t, _, _ in WALK_SCRIPT),
            len(walk) // 4,
            blocked,
            (walk[-4] - BIAS) / FRACUNIT,
            (walk[-3] - BIAS) / FRACUNIT,
        )
    )
    if blocked:
        raise SystemExit("the walk script touches a wall; the model cannot slide -- change it")

    text = HEADER + "\n"
    text += "/// Sentinel for \"no line\".\npub const NO_LINE: u32 = %d;\n\n" % NO_LINE
    text += emit_array(
        "MOVES",
        "felt252",
        moves,
        "15 felts per case: x, y, z, radius (units), height (units), monster (0/1), "
        "momx, momy, ok, floorz, ceilingz, dropoffz, blocking line, crossed specials, first crossed special.",
    )
    text += emit_array(
        "FRICTIONS",
        "felt252",
        frictions,
        "4 felts per case: momx, momy at tic 0 and after 12 tics of friction on the floor.",
    )
    text += emit_array(
        "SIGHTS",
        "felt252",
        sights,
        "10 felts per case: x1, y1, z1, x2, y2, z2, sector 1, sector 2, rejected, visible "
        "(both things 56 units tall, standing on their floor).",
    )
    text += emit_array(
        "SHOTS",
        "felt252",
        shots,
        "9 felts per case: x, y, z, angle (BAM), aim slope, range (units), line hit, puff x, puff y.",
    )
    text += emit_array(
        "WALK",
        "felt252",
        walk,
        "4 felts per checkpoint (every 50 tics of the 350-tic script): x, y, momx, momy.",
    )
    if args.write:
        (CRATE / "src" / "tests").mkdir(parents=True, exist_ok=True)
        (CRATE / "src" / "tests" / "vectors.cairo").write_text(text)
        print("wrote src/tests/vectors.cairo (%d felts)" % (len(moves) + len(frictions) + len(sights) + len(shots)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

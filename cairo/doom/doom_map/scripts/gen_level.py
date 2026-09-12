#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Turn `tools/wad`'s JSON extraction of a Doom map into `src/levels/<map>.cairo`.

This is `doom_map`'s own generator: it consumes **only** Output A of
`tools/wad` (the plain-map-units JSON for the client) and re-derives every
runtime representation itself, in the exact shapes the generic crates of
`cairo/crates/*` consume:

* linedef and BSP-node half-plane predicates with `geom2d`'s biases
  (`COEF_BIAS = 2^17`, `CONST_BIAS = 2^50`) -- see `half_plane()` below, a
  transcription of `geom2d::half_plane` pinned against the Cairo function on
  1 000 linedefs by `src/tests/vectors.cairo`;
* node children with `bsp::SUBSECTOR_FLAG = 0x8000_0000` (the WAD stores
  Doom's 16-bit `0x8000`);
* sector heights and every coordinate in `fixed`'s offset encoding
  (`enc = units * 65536 + 2^32`);
* the blockmap as `blockmap::PackedLists` (`start[cells + 1]`, `items[]`),
  not Doom's offset/terminator format;
* REJECT bit-packed 64 bits per felt, one row of sectors at a time;
* the R2-A9 location accelerator, `CELL_NODE` (docs/DECISIONS.md D22: the
  candidate lists of the first version are gone).

Layout policy (S1 sec. 5.9 / docs/G0.md D4): **hot data planar, cold data
packed**, arbitrated by the measured rule

    pack iff  14.7 * (felts saved) / K  >  (extra steps per access) * (accesses per tic)

at K = 100. The per-group decision is recorded in `../README.md`; this file
implements it. Every packed felt stays **below 2^72** (S0's `range_check_9_9`
cliff, PLAN.md A7), which is why REJECT is packed 64 bits per felt and not
the 124 S1 sec. 7 suggested.

Usage:

    export ASDF_NODEJS_VERSION=22.22.2
    cd tools/wad && npm install
    npm run extract -- --wad <freedoom1.wad> --map E1M1 --out /tmp/wadout/
    python3 cairo/doom/doom_map/scripts/gen_level.py \\
        --json /tmp/wadout/e1m1.json --write

`--write` rewrites `src/levels/<map>.cairo`, `src/tests/vectors.cairo` and
`bench/manifest.json`, then runs `scarb fmt`. Without it the script only
prints the bytecode-word table.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CRATE = HERE.parent

# --------------------------------------------------------------------------
# Encoding constants -- these MUST match the Cairo side exactly.
# --------------------------------------------------------------------------

FRACUNIT = 65536
BIAS = 1 << 32  # fixed::BIAS
COEF_BIAS = 1 << 17  # geom2d::COEF_BIAS
CONST_BIAS = 1 << 50  # geom2d::CONST_BIAS
SUBSECTOR_FLAG = 0x80000000  # bsp::SUBSECTOR_FLAG
WAD_SUBSECTOR_FLAG = 0x8000  # what the WAD stores

BOX_SHIFT = 1 << 34  # two `enc` values (each < 2^33) in one felt
COORD_BIAS = 1 << 15  # int16 map units -> [0, 2^16)
NO_SECTOR = 2047  # 11-bit sentinel in L_PACKED
REJECT_BITS = 64  # bits of REJECT per felt (< 2^72, A7)

MAX_CONST_LEN = 32767  # CASM type sizes are i16 (S1 sec. 4)

# L_PACKED bit layout (LSB first).
LP_FLAGS = 0  # 16 bits, the raw WAD linedef flags word
LP_SPECIAL = 16  # 8 bits
LP_TAG = 24  # 16 bits
LP_DIAG = 40  # 1 bit, geom2d::diagonal
LP_FRONT = 41  # 11 bits, NO_SECTOR = none
LP_BACK = 52  # 11 bits, NO_SECTOR = none  -> 63 bits total

# S_META bit layout.
SM_LIGHT = 0  # 8 bits
SM_SPECIAL = 8  # 8 bits
SM_TAG = 16  # 16 bits -> 32 bits total

# THINGS bit layout.
TH_X = 0  # 16 bits, x + 2^15
TH_Y = 16  # 16 bits
TH_TYPE = 32  # 13 bits (doomednum <= 4095 on every id map)
TH_ANGLE = 45  # 3 bits, angle / 45
TH_FLAGS = 48  # 16 bits -> 64 bits total

# Doom skill bits on a THINGS `flags` word (p_setup.c, P_SpawnMapThing).
MTF_EASY = 1
MTF_NORMAL = 2  # skill 2, "Hurt me plenty" (docs/G0.md D3)
MTF_HARD = 4
MTF_AMBUSH = 8
MTF_NOTSINGLE = 16


def enc(units: int) -> int:
    """`fixed::Fixed.enc` of an integer map-unit coordinate."""
    return units * FRACUNIT + BIAS


# --------------------------------------------------------------------------
# geom2d transcriptions (pinned against the Cairo functions by the tests)
# --------------------------------------------------------------------------


def half_plane(v1: tuple[int, int], v2: tuple[int, int]) -> tuple[int, int, int]:
    """`geom2d::half_plane`, integer map units in, biased felts out.

    `cross = A*y_raw + B*x_raw + C >= 0` is `geom2d::SIDE_BACK`, with
    `A = ldx`, `B = -ldy`, `C = ldy*v1x_raw - ldx*v1y_raw`.
    """
    ldx = v2[0] - v1[0]
    ldy = v2[1] - v1[1]
    a = ldx
    b = -ldy
    c = ldy * (v1[0] * FRACUNIT) - ldx * (v1[1] * FRACUNIT)
    return (a + COEF_BIAS, b + COEF_BIAS, c - (a + b) * BIAS + CONST_BIAS)


def diagonal(v1: tuple[int, int], v2: tuple[int, int]) -> int:
    """`geom2d::diagonal`: 1 when the slope is negative (`ldx * ldy < 0`)."""
    ldx = v2[0] - v1[0]
    ldy = v2[1] - v1[1]
    return 1 if (ldx < 0) != (ldy < 0) else 0


# --------------------------------------------------------------------------
# BSP helpers (Doom's `R_PointOnSide`, over the same exact integer predicate)
# --------------------------------------------------------------------------


def node_side(nd: dict, x: int, y: int) -> int:
    """0 front, 1 back; a point exactly on the partition is back."""
    left = nd["dy"] * (x - nd["x"])
    right = (y - nd["y"]) * nd["dx"]
    return 0 if right < left else 1


def wad_child(nd: dict, side: int) -> int:
    """Doom's `children[0]` is the RIGHT child, which `R_PointOnSide` numbers
    0 -- `geom2d::SIDE_FRONT`."""
    return nd["rightChild"] if side == 0 else nd["leftChild"]


def to_cairo_child(raw: int) -> int:
    if raw & WAD_SUBSECTOR_FLAG:
        return SUBSECTOR_FLAG + (raw & (WAD_SUBSECTOR_FLAG - 1))
    return raw


def locate_subsector(doc: dict, x: int, y: int) -> int:
    """Doom's `R_PointInSubsector`."""
    nodes = doc["nodes"]
    cur = len(nodes) - 1
    while not (cur & WAD_SUBSECTOR_FLAG):
        nd = nodes[cur]
        cur = wad_child(nd, node_side(nd, x, y))
    return cur & (WAD_SUBSECTOR_FLAG - 1)


def descent_depth(nodes: list[dict], start: int, x: int, y: int) -> int:
    cur, d = start, 0
    while not (cur & WAD_SUBSECTOR_FLAG):
        nd = nodes[cur]
        cur = wad_child(nd, node_side(nd, x, y))
        d += 1
    return d


def box_sides(nd: dict, x0: int, y0: int, x1: int, y1: int) -> set[int]:
    """The sides of `nd` the four corners of the box fall on.

    A partition is a linear function, so its extremes over an axis-aligned box
    are attained at the corners: one element means the whole box is on that
    side, two that it straddles the partition.
    """
    return {
        node_side(nd, x0, y0),
        node_side(nd, x1, y0),
        node_side(nd, x0, y1),
        node_side(nd, x1, y1),
    }


def cell_start_nodes(doc: dict, bm: dict) -> tuple[list[int], float, float]:
    """For every blockmap cell, the deepest child id whose region contains it.

    Descending from the returned id answers exactly what a descent from the
    root answers, for every point of that cell. Also returns the mean descent
    depth from the root and from the returned id, for the README.
    """
    nodes = doc["nodes"]
    root = len(nodes) - 1
    unit = bm["unit"]
    out: list[int] = []
    before = after = 0.0
    for cy in range(bm["rows"]):
        y0 = bm["originY"] + cy * unit
        for cx in range(bm["columns"]):
            x0 = bm["originX"] + cx * unit
            cur = root
            while not (cur & WAD_SUBSECTOR_FLAG):
                sides = box_sides(nodes[cur], x0, y0, x0 + unit, y0 + unit)
                if len(sides) != 1:
                    break
                cur = wad_child(nodes[cur], sides.pop())
            out.append(to_cairo_child(cur))
            mx, my = x0 + unit // 2, y0 + unit // 2
            before += descent_depth(nodes, root, mx, my)
            after += descent_depth(nodes, cur, mx, my)
    n = float(len(out))
    return out, before / n, after / n


# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------


class Arrays:
    """Named `const` arrays, in emission order, with their element type."""

    def __init__(self) -> None:
        self.items: list[tuple[str, str, list[int], str]] = []

    def add(self, name: str, ty: str, values: list[int], group: str) -> None:
        if len(values) > MAX_CONST_LEN:
            raise SystemExit(
                "%s has %d elements; Cairo 2.16 crashes above %d (S1 sec. 4). "
                "Split it by rows in the generator." % (name, len(values), MAX_CONST_LEN)
            )
        self.items.append((name, ty, values, group))

    def by_name(self) -> dict[str, list[int]]:
        return {n: v for n, _, v, _ in self.items}

    def words(self) -> int:
        return sum(len(v) for _, _, v, _ in self.items)


def build(doc: dict, skill_bit: int) -> tuple[Arrays, dict]:
    verts = [(v["x"], v["y"]) for v in doc["vertexes"]]
    lines = doc["linedefs"]
    sides = doc["sidedefs"]
    sectors = doc["sectors"]
    nodes = doc["nodes"]
    bm = doc["blockmap"]
    ssec_sector = doc["derived"]["subsectorSectors"]

    arr = Arrays()

    # -- linedefs ---------------------------------------------------------
    l_ab: list[int] = []
    l_bb: list[int] = []
    l_cb: list[int] = []
    l_lr: list[int] = []
    l_bt: list[int] = []
    l_pk: list[int] = []
    for ld in lines:
        v1 = verts[ld["startVertex"]]
        v2 = verts[ld["endVertex"]]
        ab, bb, cb = half_plane(v1, v2)
        l_ab.append(ab)
        l_bb.append(bb)
        l_cb.append(cb)
        left, right = min(v1[0], v2[0]), max(v1[0], v2[0])
        bottom, top = min(v1[1], v2[1]), max(v1[1], v2[1])
        l_lr.append(enc(left) * BOX_SHIFT + enc(right))
        l_bt.append(enc(bottom) * BOX_SHIFT + enc(top))

        front = ld["frontSidedef"]
        back = ld["backSidedef"]
        fsec = sides[front]["sector"] if 0 <= front < len(sides) else NO_SECTOR
        bsec = sides[back]["sector"] if 0 <= back < len(sides) else NO_SECTOR
        flags = ld["flags"] & 0xFFFF
        special = ld["specialType"]
        tag = ld["sectorTag"]
        if special > 0xFF:
            raise SystemExit("linedef special %d does not fit in 8 bits" % special)
        if tag > 0xFFFF:
            raise SystemExit("linedef tag %d does not fit in 16 bits" % tag)
        if fsec > NO_SECTOR or bsec > NO_SECTOR:
            raise SystemExit("sector index does not fit in 11 bits")
        l_pk.append(
            (flags << LP_FLAGS)
            | (special << LP_SPECIAL)
            | (tag << LP_TAG)
            | (diagonal(v1, v2) << LP_DIAG)
            | (fsec << LP_FRONT)
            | (bsec << LP_BACK)
        )
    arr.add("L_AB", "felt252", l_ab, "linedefPredicates")
    arr.add("L_BB", "felt252", l_bb, "linedefPredicates")
    arr.add("L_CB", "felt252", l_cb, "linedefPredicates")
    arr.add("L_BOX_LR", "felt252", l_lr, "linedefBox")
    arr.add("L_BOX_BT", "felt252", l_bt, "linedefBox")
    arr.add("L_PACKED", "felt252", l_pk, "linedefMeta")

    # -- BSP nodes --------------------------------------------------------
    n_ab: list[int] = []
    n_bb: list[int] = []
    n_cb: list[int] = []
    n_c0: list[int] = []
    n_c1: list[int] = []
    for nd in nodes:
        v1 = (nd["x"], nd["y"])
        v2 = (nd["x"] + nd["dx"], nd["y"] + nd["dy"])
        ab, bb, cb = half_plane(v1, v2)
        n_ab.append(ab)
        n_bb.append(bb)
        n_cb.append(cb)
        n_c0.append(to_cairo_child(nd["rightChild"]))
        n_c1.append(to_cairo_child(nd["leftChild"]))
    arr.add("N_AB", "felt252", n_ab, "nodePredicates")
    arr.add("N_BB", "felt252", n_bb, "nodePredicates")
    arr.add("N_CB", "felt252", n_cb, "nodePredicates")
    arr.add("N_CHILD0", "u32", n_c0, "nodeChildren")
    arr.add("N_CHILD1", "u32", n_c1, "nodeChildren")

    # -- subsectors and sectors -------------------------------------------
    arr.add("SS_SECTOR", "u32", list(ssec_sector), "subsectorSector")
    arr.add("S_FLOOR", "felt252", [enc(s["floorHeight"]) for s in sectors], "sectorHeights")
    arr.add("S_CEIL", "felt252", [enc(s["ceilingHeight"]) for s in sectors], "sectorHeights")
    s_meta = []
    for s in sectors:
        if s["tag"] > 0xFFFF or s["specialType"] > 0xFF or s["lightLevel"] > 0xFF:
            raise SystemExit("sector metadata does not fit its field")
        s_meta.append(
            (s["lightLevel"] << SM_LIGHT)
            | (s["specialType"] << SM_SPECIAL)
            | (s["tag"] << SM_TAG)
        )
    arr.add("S_META", "felt252", s_meta, "sectorMeta")

    # -- blockmap as blockmap::PackedLists --------------------------------
    cells = bm["cells"]
    bm_start = [0]
    bm_items: list[int] = []
    for cell in cells:
        # Sorted and deduplicated per cell: free here, a no-op on E1M1
        # (S1 sec. 4), and it makes the emitted data canonical.
        bm_items.extend(sorted(set(cell)))
        bm_start.append(len(bm_items))
    arr.add("BM_START", "u32", bm_start, "blockmap")
    arr.add("BM_ITEMS", "u32", bm_items, "blockmap")

    # -- R2-A9 (D22): where a descent may start, for each cell --------------
    cell_node, depth_before, depth_after = cell_start_nodes(doc, bm)
    arr.add("CELL_NODE", "u32", cell_node, "accelerator")

    # -- REJECT, bit-packed 64 bits per felt ------------------------------
    nsec = doc["reject"]["numSectors"]
    raw = bytes.fromhex(doc["reject"]["dataHex"])
    stride = (nsec + REJECT_BITS - 1) // REJECT_BITS
    rows: list[int] = []
    blocked = 0
    for s1 in range(nsec):
        word = [0] * stride
        for s2 in range(nsec):
            pnum = s1 * nsec + s2
            if raw[pnum >> 3] & (1 << (pnum & 7)):
                word[s2 // REJECT_BITS] |= 1 << (s2 % REJECT_BITS)
                blocked += 1
        rows.extend(word)
    arr.add("REJECT_ROWS", "felt252", rows, "reject")
    arr.add("POW2", "felt252", [1 << k for k in range(REJECT_BITS)], "reject")

    # -- things -----------------------------------------------------------
    kept = []
    for t in doc["things"]:
        if t["type"] <= 4 or t["type"] == 11:
            kept.append(t)  # player / deathmatch starts bypass the skill test
        elif (t["flags"] & skill_bit) and not (t["flags"] & MTF_NOTSINGLE):
            kept.append(t)
    th: list[int] = []
    for t in kept:
        if t["angle"] % 45 != 0:
            raise SystemExit("thing angle %d is not a multiple of 45" % t["angle"])
        if not (0 <= t["type"] < 8192):
            raise SystemExit("doomednum %d does not fit in 13 bits" % t["type"])
        th.append(
            ((t["x"] + COORD_BIAS) << TH_X)
            | ((t["y"] + COORD_BIAS) << TH_Y)
            | (t["type"] << TH_TYPE)
            | (((t["angle"] // 45) % 8) << TH_ANGLE)
            | ((t["flags"] & 0xFFFF) << TH_FLAGS)
        )
    arr.add("THINGS", "felt252", th, "things")

    start = next((t for t in doc["things"] if t["type"] == 1), None)
    if start is None:
        raise SystemExit("no Player 1 start on this map")

    meta = dict(
        map=doc["map"],
        num_linedefs=len(lines),
        num_nodes=len(nodes),
        root_node=len(nodes) - 1,
        num_subsectors=len(ssec_sector),
        num_sectors=len(sectors),
        num_things=len(kept),
        num_cells=len(cells),
        columns=bm["columns"],
        rows=bm["rows"],
        origin_x=bm["originX"],
        origin_y=bm["originY"],
        reject_stride=stride,
        reject_blocked=blocked,
        skill_bit=skill_bit,
        start=start,
        bbox=doc["boundingBox"],
        blockmap_entries=len(bm_items),
        depth_before=depth_before,
        depth_after=depth_after,
    )
    return arr, meta


# --------------------------------------------------------------------------
# Emission
# --------------------------------------------------------------------------


def emit_array(name: str, ty: str, values: list[int]) -> str:
    body = ", ".join(str(v) for v in values)
    return "pub const %s: [%s; %d] = [%s];\n\n" % (name, ty, len(values), body)


HEADER = """// SPDX-License-Identifier: GPL-2.0-only
//
//! GENERATED -- do not edit. Regenerate with
//! `python3 cairo/doom/doom_map/scripts/gen_level.py --json <e1m1.json> --write`
//! from the JSON `tools/wad` extracts out of `freedoom1.wad` (Freedoom
//! 0.13.0, BSD 3-clause; the WAD itself is never committed).
//!
//! Map **{map}**, things filtered to skill bit {skill_bit} ("Hurt me
//! plenty", docs/G0.md D3; player and deathmatch starts bypass the skill
//! test exactly as `P_SpawnMapThing` does).
//!
//! Every representation here is the one a generic crate consumes directly:
//! `geom2d` half-plane coefficients (biases 2^17 / 2^50), `bsp` child ids
//! (leaf flag 0x8000_0000), `fixed` offset-encoded coordinates
//! (`enc = units * 65536 + 2^32`) and `blockmap::PackedLists`. The packed
//! records' bit layouts are documented -- and decoded -- in `../../lib.cairo`.
//!
//! Segs, textures, flats, sidedef geometry, the VERTEXES lump and the BSP
//! node bounding boxes are **not** here: nothing in the simulation reads
//! them (the renderer gets them from `client/public/levels/{lower}.json`).
"""


def emit_level(arr: Arrays, meta: dict) -> str:
    out = [
        HEADER.format(
            map=meta["map"], skill_bit=meta["skill_bit"], lower=meta["map"].lower()
        )
    ]
    out.append("\n")
    out.append("/// Level identifier, the short-string form of the map lump name.\n")
    out.append("pub const LEVEL_ID: felt252 = '%s';\n\n" % meta["map"])
    scalars = [
        ("NUM_LINEDEFS", "u32", meta["num_linedefs"], "Linedefs on the map."),
        ("NUM_NODES", "u32", meta["num_nodes"], "BSP nodes."),
        ("ROOT_NODE", "u32", meta["root_node"], "`bsp::point_in_subsector`'s root."),
        ("NUM_SUBSECTORS", "u32", meta["num_subsectors"], "BSP leaves."),
        ("NUM_SECTORS", "u32", meta["num_sectors"], "Sectors."),
        ("NUM_THINGS", "u32", meta["num_things"], "Things kept at this skill."),
        ("BM_COLUMNS", "u32", meta["columns"], "Blockmap columns."),
        ("BM_ROWS", "u32", meta["rows"], "Blockmap rows."),
        ("BM_ORIGIN_X", "felt252", enc(meta["origin_x"]), "Blockmap origin x (`enc`)."),
        ("BM_ORIGIN_Y", "felt252", enc(meta["origin_y"]), "Blockmap origin y (`enc`)."),
        ("REJECT_STRIDE", "u32", meta["reject_stride"], "Felts per REJECT row."),
        ("START_X", "felt252", enc(meta["start"]["x"]), "Player 1 start x (`enc`)."),
        ("START_Y", "felt252", enc(meta["start"]["y"]), "Player 1 start y (`enc`)."),
        (
            "START_ANGLE",
            "u32",
            (meta["start"]["angle"] // 45 % 8) * (1 << 29),
            "Player 1 start angle (BAM).",
        ),
        ("BOUNDS_LEFT", "felt252", enc(meta["bbox"]["minX"]), "Map bounding box (`enc`)."),
        ("BOUNDS_BOTTOM", "felt252", enc(meta["bbox"]["minY"]), "Map bounding box (`enc`)."),
        ("BOUNDS_RIGHT", "felt252", enc(meta["bbox"]["maxX"]), "Map bounding box (`enc`)."),
        ("BOUNDS_TOP", "felt252", enc(meta["bbox"]["maxY"]), "Map bounding box (`enc`)."),
    ]
    for name, ty, value, doc in scalars:
        out.append("/// %s\n" % doc)
        out.append("pub const %s: %s = %d;\n\n" % (name, ty, value))
    for name, ty, values, _ in arr.items:
        out.append(emit_array(name, ty, values))
    return "".join(out)


VECTORS_HEADER = """// SPDX-License-Identifier: GPL-2.0-only
//
//! GENERATED -- do not edit (see `scripts/gen_level.py`).
//!
//! Independent expectations for `src/tests.cairo`, computed in Python from
//! the WAD JSON and **not** from the emitted Cairo arrays:
//!
//! * `LINE_VERTICES` -- the (v1x, v1y, v2x, v2y) map-unit vertices of the
//!   first `PINNED_LINES` linedefs, so the test can rebuild each predicate
//!   with `geom2d::half_plane` and compare it to the generated coefficients
//!   (the "pin the Python builder against `geom2d::half_plane`" test), and
//!   check the recovered endpoints and boxes against the same source;
//! * `SAMPLE_POINTS` -- sampled points with the subsector a transcription of
//!   `R_PointInSubsector` reaches, for the `CELL_NODE` (D22) exactness test.
"""


def sample_points(doc: dict, lattice: int = 200, centroids: int = 200) -> list[int]:
    """Sampled points with the subsector a descent from the root reaches.

    Three felts per point: `x, y, subsector`. Two deterministic families: a
    lattice over the whole bounding box -- which reaches the void, where a
    descent still names a leaf and `CELL_NODE` still owes it that leaf --
    and the centroids of the first `centroids` subsectors.
    """
    bb = doc["boundingBox"]
    out: list[int] = []

    def add(x: int, y: int) -> None:
        out.extend([x, y, locate_subsector(doc, x, y)])

    cols, rows = 20, 10
    for j in range(rows):
        for i in range(cols):
            if len(out) >= lattice * 3:
                break
            add(
                bb["minX"] + (bb["maxX"] - bb["minX"]) * (2 * i + 1) // (2 * cols),
                bb["minY"] + (bb["maxY"] - bb["minY"]) * (2 * j + 1) // (2 * rows),
            )

    for ss in range(min(centroids, len(doc["subsectors"]))):
        sub = doc["subsectors"][ss]
        xs: list[int] = []
        ys: list[int] = []
        for k in range(sub["numSegs"]):
            sg = doc["segs"][sub["firstSeg"] + k]
            for vi in (sg["startVertex"], sg["endVertex"]):
                xs.append(doc["vertexes"][vi]["x"])
                ys.append(doc["vertexes"][vi]["y"])
        if xs:
            add(sum(xs) // len(xs), sum(ys) // len(ys))
    return out


def emit_vectors(doc: dict, points: list[int], pinned: int) -> str:
    verts = [(v["x"], v["y"]) for v in doc["vertexes"]]
    lines = doc["linedefs"]
    n = min(pinned, len(lines))
    lv: list[int] = []
    for ld in lines[:n]:
        v1 = verts[ld["startVertex"]]
        v2 = verts[ld["endVertex"]]
        lv.extend([v1[0], v1[1], v2[0], v2[1]])

    out = [VECTORS_HEADER, "\n"]
    out.append("/// Number of linedefs covered by `LINE_VERTICES`.\n")
    out.append("pub const PINNED_LINES: u32 = %d;\n\n" % n)
    out.append("/// (v1x, v1y, v2x, v2y) in map units, four felts per linedef.\n")
    out.append(emit_array("LINE_VERTICES", "felt252", lv))
    out.append("/// (x, y, subsector) in map units, three felts per sampled point.\n")
    out.append(emit_array("SAMPLE_POINTS", "felt252", points))
    return "".join(out)


PACKED = (
    "L_BOX_LR",
    "L_BOX_BT",
    "L_PACKED",
    "S_META",
    "THINGS",
    "REJECT_ROWS",
)

SCALAR_WORDS = 19  # LEVEL_ID plus the 18 scalars of `emit_level`


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", required=True, help="tools/wad Output A (<map>.json)")
    ap.add_argument("--map", default=None, help="map name (default: from the JSON)")
    ap.add_argument(
        "--skill-bit",
        type=int,
        default=MTF_NORMAL,
        help="THINGS skill bit to keep (default 2, 'Hurt me plenty')",
    )
    ap.add_argument("--pin-lines", type=int, default=1000, help="linedefs pinned by the test")
    ap.add_argument("--max-words", type=int, default=20000, help="bytecode-word budget (D4)")
    ap.add_argument("--write", action="store_true", help="write the generated files")
    args = ap.parse_args()

    sys.setrecursionlimit(10000)
    doc = json.loads(Path(args.json).read_text())
    name = (args.map or doc["map"]).lower()
    arr, meta = build(doc, args.skill_bit)
    points = sample_points(doc)

    total = arr.words() + SCALAR_WORDS
    print("%-16s %-18s %-7s %8s" % ("array", "group", "layout", "words"))
    for aname, _, values, group in sorted(arr.items, key=lambda x: -len(x[2])):
        print(
            "%-16s %-18s %-7s %8d"
            % (aname, group, "packed" if aname in PACKED else "planar", len(values))
        )
    print("%-16s %-18s %-7s %8d" % ("(scalars)", "scalar", "-", SCALAR_WORDS))
    print("%-16s %-18s %-7s %8d" % ("TOTAL", "", "", total))
    print()
    print(
        "R2-A9 (D22): %d sampled points; mean BSP descent depth %.2f from the root, "
        "%.2f from CELL_NODE" % (len(points) // 3, meta["depth_before"], meta["depth_after"])
    )
    print(
        "REJECT: %d of %d sector pairs blocked (%.1f %%)"
        % (
            meta["reject_blocked"],
            meta["num_sectors"] ** 2,
            100.0 * meta["reject_blocked"] / meta["num_sectors"] ** 2,
        )
    )
    if total > args.max_words:
        print(
            "\nERROR: %d words exceeds the %d-word budget (docs/G0.md D4)"
            % (total, args.max_words),
            file=sys.stderr,
        )
        return 1

    if not args.write:
        return 0

    (CRATE / "src" / "levels").mkdir(parents=True, exist_ok=True)
    (CRATE / "src" / "tests").mkdir(parents=True, exist_ok=True)
    (CRATE / "bench").mkdir(parents=True, exist_ok=True)
    (CRATE / "src" / "levels" / ("%s.cairo" % name)).write_text(emit_level(arr, meta))
    (CRATE / "src" / "tests" / "vectors.cairo").write_text(
        emit_vectors(doc, points, args.pin_lines)
    )
    manifest = dict(
        map=meta["map"],
        scalars=SCALAR_WORDS,
        total_words=total,
        arrays=[
            dict(name=n, group=g, layout="packed" if n in PACKED else "planar", words=len(v))
            for n, _, v, g in arr.items
        ],
        counts={
            k: meta[k]
            for k in (
                "num_linedefs",
                "num_nodes",
                "num_subsectors",
                "num_sectors",
                "num_things",
                "num_cells",
                "blockmap_entries",
                "reject_blocked",
            )
        },
        descent_depth=dict(
            from_root=meta["depth_before"], from_cell_node=meta["depth_after"]
        ),
    )
    (CRATE / "bench" / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("\nwrote src/levels/%s.cairo, src/tests/vectors.cairo, bench/manifest.json" % name)

    fmt = subprocess.run(
        ["scarb", "fmt", "-p", "doom_map"],
        cwd=str(CRATE.parent.parent),
        capture_output=True,
        text=True,
    )
    if fmt.returncode != 0:
        print(fmt.stdout + fmt.stderr, file=sys.stderr)
        return 1
    print("scarb fmt: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())

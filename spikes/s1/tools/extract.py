#!/usr/bin/env python3
"""Spike S1 - throwaway Freedoom E1M1 extractor -> Cairo constants.

Parses freedoom1.wad, pulls the E1M1 map lumps and emits Cairo source files for
the S1 prototype in two competing data representations:

  A. "packed"   : one felt252 per record, fields bit-packed with non-negative
                  offsets, unpacked at runtime by division.
  B. "planar"   : one const array per field (struct-of-arrays), no packing,
                  one span index per field read.

It also emits the derived data the felt-first design needs:
  * per-linedef half-plane coefficients (A, B, C) split into non-negative parts,
    so that point_on_side is 4 muls + 4 adds + 1 compare and never divides;
  * the same for BSP nodes;
  * subsector -> sector map (avoids seg/sidedef indirection at runtime);
  * blockmap with per-cell sorted+deduplicated line lists;
  * REJECT as a flat felt-per-pair array AND as one bitmask felt per sector;
  * finesine / tantoangle / rndtable tables.

Nothing here is meant to survive the spike: the real extractor is tools/wad/.

Usage:  python3 extract.py <path/to/freedoom1.wad> <out_dir_proto_src> <out_results>
"""

import json
import math
import os
import struct
import sys

# ---------------------------------------------------------------- WAD parsing

LINEDEF_SZ = 14
SIDEDEF_SZ = 30
SECTOR_SZ = 26
THING_SZ = 10
VERTEX_SZ = 4
SEG_SZ = 12
SSECTOR_SZ = 4
NODE_SZ = 28


def read_wad(path):
    with open(path, "rb") as fh:
        data = fh.read()
    magic, numlumps, infotableofs = struct.unpack_from("<4sii", data, 0)
    assert magic in (b"IWAD", b"PWAD"), magic
    lumps = []
    for i in range(numlumps):
        off, size, name = struct.unpack_from("<ii8s", data, infotableofs + 16 * i)
        lumps.append((name.rstrip(b"\0").decode("ascii"), off, size))
    return data, lumps


def map_lumps(lumps, mapname):
    idx = next(i for i, l in enumerate(lumps) if l[0] == mapname)
    out = {}
    for name, off, size in lumps[idx + 1: idx + 12]:
        if name in ("THINGS", "LINEDEFS", "SIDEDEFS", "VERTEXES", "SEGS",
                    "SSECTORS", "NODES", "SECTORS", "REJECT", "BLOCKMAP"):
            out[name] = (off, size)
        else:
            break
    return out


def parse(data, lumps, mapname):
    L = map_lumps(lumps, mapname)

    def blob(n):
        off, size = L[n]
        return data[off:off + size]

    verts = [struct.unpack_from("<hh", blob("VERTEXES"), i * VERTEX_SZ)
             for i in range(len(blob("VERTEXES")) // VERTEX_SZ)]
    lines = []
    b = blob("LINEDEFS")
    for i in range(len(b) // LINEDEF_SZ):
        v1, v2, flags, special, tag, s0, s1 = struct.unpack_from("<HHhhhhh", b, i * LINEDEF_SZ)
        lines.append(dict(v1=v1, v2=v2, flags=flags, special=special, tag=tag,
                          side0=s0, side1=s1))
    sides = []
    b = blob("SIDEDEFS")
    for i in range(len(b) // SIDEDEF_SZ):
        xo, yo, top, mid, bot, sec = struct.unpack_from("<hh8s8s8sh", b, i * SIDEDEF_SZ)
        sides.append(dict(sector=sec))
    sectors = []
    b = blob("SECTORS")
    for i in range(len(b) // SECTOR_SZ):
        fh_, ch, fp, cp, light, spec, tag = struct.unpack_from("<hh8s8shhh", b, i * SECTOR_SZ)
        sectors.append(dict(floor=fh_, ceil=ch, light=light, special=spec, tag=tag))
    things = []
    b = blob("THINGS")
    for i in range(len(b) // THING_SZ):
        x, y, ang, typ, fl = struct.unpack_from("<hhhhh", b, i * THING_SZ)
        things.append(dict(x=x, y=y, angle=ang, type=typ, flags=fl))
    segs = []
    b = blob("SEGS")
    for i in range(len(b) // SEG_SZ):
        v1, v2, ang, ld, side, off = struct.unpack_from("<HHhHhh", b, i * SEG_SZ)
        segs.append(dict(v1=v1, v2=v2, line=ld, side=side))
    ssectors = []
    b = blob("SSECTORS")
    for i in range(len(b) // SSECTOR_SZ):
        n, first = struct.unpack_from("<HH", b, i * SSECTOR_SZ)
        ssectors.append(dict(count=n, first=first))
    nodes = []
    b = blob("NODES")
    for i in range(len(b) // NODE_SZ):
        f = struct.unpack_from("<12hHH", b, i * NODE_SZ)
        nodes.append(dict(x=f[0], y=f[1], dx=f[2], dy=f[3],
                          bbox=[list(f[4:8]), list(f[8:12])],
                          child=[f[12], f[13]]))
    reject = blob("REJECT")
    bm = blob("BLOCKMAP")
    return dict(verts=verts, lines=lines, sides=sides, sectors=sectors,
                things=things, segs=segs, ssectors=ssectors, nodes=nodes,
                reject=reject, blockmap=bm)


def parse_blockmap(bm):
    origx, origy, ncols, nrows = struct.unpack_from("<hhHH", bm, 0)
    n = ncols * nrows
    offs = struct.unpack_from("<%dH" % n, bm, 8)
    cells = []
    for o in offs:
        base = o * 2
        out = []
        # first entry is a 0 placeholder, list terminated by 0xFFFF
        j = base
        first = True
        while True:
            (v,) = struct.unpack_from("<H", bm, j)
            j += 2
            if v == 0xFFFF:
                break
            if first and v == 0:
                first = False
                continue
            first = False
            out.append(v)
        cells.append(out)
    return dict(origx=origx, origy=origy, ncols=ncols, nrows=nrows, cells=cells)


# --------------------------------------------------------- derived quantities

FRACBITS = 16
FRACUNIT = 1 << FRACBITS
OFF = 1 << 32           # coordinate bias: X = x_fixed + OFF, always > 0
NF = 1 << 40            # generic "no value" / bias for signed scalars


def split(v):
    """signed int -> (positive part, negative part), both >= 0."""
    return (v, 0) if v >= 0 else (0, -v)


# --- "3-array" half-plane form (R2-A4) -------------------------------------
# cross = A*Y + B*X + C2, with A, B in map units (|A|,|B| < 2^13) and
# |C2| < 2^46.  Writing A = Ab - K, B = Bb - K, C2 = Cb - BIGC:
#     cross = (Ab*Y + Bb*X + Cb) - (K*(X+Y) + BIGC)
# The right-hand term does not depend on the line, so it is hoisted out of the
# per-line loop and each line needs only THREE non-negative const arrays
# instead of six, and two multiplications instead of four.
HK = 1 << 13
BIGC = 1 << 48


def three_array(A, B, C2):
    ab = A + HK
    bb = B + HK
    cb = C2 + BIGC
    assert ab >= 0 and bb >= 0 and cb >= 0, (A, B, C2)
    assert ab < (1 << 15) and bb < (1 << 15) and cb < (1 << 50)
    return ab, bb, cb


def line_coeffs(v1, v2):
    """cross(x_f,y_f) = A*y_f + B*x_f + C, with A,B in map units.

    Doom: left = ldy>>FRACBITS * (x-v1x); right = (y-v1y) * (ldx>>FRACBITS)
          side = 0 iff right < left  <=>  cross < 0.
    With biased coords X = x_f + OFF, Y = y_f + OFF:
          cross = A*Y + B*X + C2,  C2 = C - (A+B)*OFF
    """
    (x1, y1), (x2, y2) = v1, v2
    ldx = x2 - x1
    ldy = y2 - y1
    A = ldx
    B = -ldy
    C = ldy * (x1 * FRACUNIT) - ldx * (y1 * FRACUNIT)
    C2 = C - (A + B) * OFF
    ap, an = split(A)
    bp, bn = split(B)
    cp, cn = split(C2)
    ab, bb, cb = three_array(A, B, C2)
    # Doom's P_BoxOnLineSide diagonal: negative-slope lines use (right,top) /
    # (left,bottom), everything else uses (left,top) / (right,bottom).
    diag = 1 if (ldx * ldy) < 0 else 0
    return ap, an, bp, bn, cp, cn, ab, bb, cb, diag


def node_coeffs(nx, ny, ndx, ndy):
    """Same half-plane form for a BSP node (partition line in map units)."""
    A = ndx
    B = -ndy
    C = ndy * (nx * FRACUNIT) - ndx * (ny * FRACUNIT)
    C2 = C - (A + B) * OFF
    ap, an = split(A)
    bp, bn = split(B)
    cp, cn = split(C2)
    ab, bb, cb = three_array(A, B, C2)
    return ap, an, bp, bn, cp, cn, ab, bb, cb


# ------------------------------------------------------------- Cairo emission

def carr(name, values, ty="felt252"):
    n = len(values)
    body = ", ".join(str(v) for v in values)
    return "pub const %s: [%s; %d] = [%s];\n" % (name, ty, n, body)


def emit(md, bmp, out_src, out_res, mapname):
    verts = md["verts"]
    lines = md["lines"]
    sides = md["sides"]
    sectors = md["sectors"]
    nodes = md["nodes"]
    ssectors = md["ssectors"]
    segs = md["segs"]
    nsec = len(sectors)

    # --- subsector -> sector (kills the seg/sidedef indirection at runtime)
    def ss_of(px, py):
        n = len(nodes) - 1
        while n < 0x8000:
            nd = nodes[n]
            dx = px - nd["x"]
            dy = py - nd["y"]
            left = nd["dy"] * dx
            right = dy * nd["dx"]
            n = nd["child"][0] if right < left else nd["child"][1]
        return n & 0x7FFF

    ss_sector = []
    for ss in ssectors:
        sg = segs[ss["first"]]
        ld = lines[sg["line"]]
        sd = ld["side1"] if sg["side"] else ld["side0"]
        ss_sector.append(sides[sd]["sector"] if sd >= 0 else 0)

    # --- linedef derived data
    l_ap, l_an, l_bp, l_bn, l_cp, l_cn = [], [], [], [], [], []
    l_ab, l_bb, l_cb, l_diag = [], [], [], []
    l_bbl, l_bbr, l_bbb, l_bbt = [], [], [], []     # biased fixed bbox
    l_flags, l_front, l_back = [], [], []
    l_blocking, l_blockmonst, l_twosided = [], [], []
    l_v1x, l_v1y, l_v2x, l_v2y = [], [], [], []     # biased fixed
    for ld in lines:
        v1 = verts[ld["v1"]]
        v2 = verts[ld["v2"]]
        ap, an, bp, bn, cp, cn, ab, bb, cb, diag = line_coeffs(v1, v2)
        l_ap.append(ap); l_an.append(an); l_bp.append(bp)
        l_bn.append(bn); l_cp.append(cp); l_cn.append(cn)
        l_ab.append(ab); l_bb.append(bb); l_cb.append(cb); l_diag.append(diag)
        l_bbl.append(min(v1[0], v2[0]) * FRACUNIT + OFF)
        l_bbr.append(max(v1[0], v2[0]) * FRACUNIT + OFF)
        l_bbb.append(min(v1[1], v2[1]) * FRACUNIT + OFF)
        l_bbt.append(max(v1[1], v2[1]) * FRACUNIT + OFF)
        l_flags.append(ld["flags"] & 0xFFFF)
        l_blocking.append(ld["flags"] & 1)
        l_blockmonst.append((ld["flags"] >> 1) & 1)
        l_twosided.append(1 if ld["side1"] >= 0 else 0)
        f = sides[ld["side0"]]["sector"] if ld["side0"] >= 0 else 0xFFFF
        b = sides[ld["side1"]]["sector"] if ld["side1"] >= 0 else 0xFFFF
        l_front.append(f); l_back.append(b)
        l_v1x.append(v1[0] * FRACUNIT + OFF); l_v1y.append(v1[1] * FRACUNIT + OFF)
        l_v2x.append(v2[0] * FRACUNIT + OFF); l_v2y.append(v2[1] * FRACUNIT + OFF)

    # --- nodes
    n_ap, n_an, n_bp, n_bn, n_cp, n_cn, n_c0, n_c1 = [], [], [], [], [], [], [], []
    n_ab, n_bb, n_cb = [], [], []
    for nd in nodes:
        ap, an, bp, bn, cp, cn, ab, bb, cb = node_coeffs(nd["x"], nd["y"], nd["dx"], nd["dy"])
        n_ap.append(ap); n_an.append(an); n_bp.append(bp)
        n_bn.append(bn); n_cp.append(cp); n_cn.append(cn)
        n_ab.append(ab); n_bb.append(bb); n_cb.append(cb)
        n_c0.append(nd["child"][0]); n_c1.append(nd["child"][1])

    # --- sectors (biased fixed heights)
    s_floor = [s["floor"] * FRACUNIT + OFF for s in sectors]
    s_ceil = [s["ceil"] * FRACUNIT + OFF for s in sectors]

    # --- blockmap, sorted + deduplicated per cell
    flat, starts, counts = [], [], []
    for cell in bmp["cells"]:
        u = sorted(set(cell))
        starts.append(len(flat))
        counts.append(len(u))
        flat.extend(u)
    # unsorted variant (raw WAD order, duplicates kept) for the A/B measurement
    flat_raw, starts_raw, counts_raw = [], [], []
    for cell in bmp["cells"]:
        starts_raw.append(len(flat_raw))
        counts_raw.append(len(cell))
        flat_raw.extend(cell)

    # --- REJECT: flat felt-per-pair AND bitmask-per-sector
    rej = md["reject"]
    flat_rej = []
    row_rej = []
    for i in range(nsec):
        row = 0
        for j in range(nsec):
            bit = i * nsec + j
            byte = bit >> 3
            v = 0
            if byte < len(rej):
                v = (rej[byte] >> (bit & 7)) & 1
            flat_rej.append(v)
            row |= v << j
        row_rej.append(row)

    # --- packed representation A: one felt per linedef
    # layout (LSB first): v1(16) v2(16) flags(16) front(16) back(16) = 80 bits
    packed_lines = []
    for i, ld in enumerate(lines):
        p = (ld["v1"] & 0xFFFF)
        p |= (ld["v2"] & 0xFFFF) << 16
        p |= (l_flags[i] & 0xFFFF) << 32
        p |= (l_front[i] & 0xFFFF) << 48
        p |= (l_back[i] & 0xFFFF) << 64
        packed_lines.append(p)
    packed_verts = []
    for (x, y) in verts:
        packed_verts.append(((x + 32768) & 0xFFFF) | (((y + 32768) & 0xFFFF) << 16))

    # --- things of interest
    player = next(t for t in md["things"] if t["type"] == 1)
    MONSTER_TYPES = {3004: "trooper", 9: "sergeant", 3001: "imp", 3002: "demon",
                     58: "spectre", 3006: "skull", 3005: "caco", 68: "arach",
                     71: "pain", 3003: "baron", 69: "knight", 64: "archvile",
                     66: "revenant", 67: "mancubus", 65: "chaingunner", 84: "sswv",
                     72: "keen", 16: "cyber", 7: "spider", 88: "brainboss"}
    monsters = [t for t in md["things"] if t["type"] in MONSTER_TYPES]

    # ---------------------------------------------------------------- write
    hdr = ("// GENERATED by spikes/s1/tools/extract.py - DO NOT EDIT.\n"
           "// Freedoom 0.13.0 %s. Throwaway spike data.\n\n" % mapname)

    consts = hdr
    consts += "pub const FRACBITS: felt252 = 16;\n"
    consts += "pub const FRACUNIT: felt252 = %d;\n" % FRACUNIT
    consts += "pub const OFF: felt252 = %d;\n" % OFF
    consts += "pub const NUM_VERTS: u32 = %d;\n" % len(verts)
    consts += "pub const NUM_LINES: u32 = %d;\n" % len(lines)
    consts += "pub const NUM_SECTORS: u32 = %d;\n" % nsec
    consts += "pub const NUM_NODES: u32 = %d;\n" % len(nodes)
    consts += "pub const NUM_SSECTORS: u32 = %d;\n" % len(ssectors)
    consts += "pub const ROOT_NODE: u32 = %d;\n" % (len(nodes) - 1)
    consts += "pub const BM_ORIGX: felt252 = %d;\n" % (bmp["origx"] * FRACUNIT + OFF)
    consts += "pub const BM_ORIGY: felt252 = %d;\n" % (bmp["origy"] * FRACUNIT + OFF)
    consts += "pub const BM_COLS: u32 = %d;\n" % bmp["ncols"]
    consts += "pub const BM_ROWS: u32 = %d;\n" % bmp["nrows"]
    consts += "pub const PLAYER_X: felt252 = %d;\n" % (player["x"] * FRACUNIT + OFF)
    consts += "pub const PLAYER_Y: felt252 = %d;\n" % (player["y"] * FRACUNIT + OFF)
    consts += "pub const PLAYER_ANGLE: u32 = %d;\n" % ((player["angle"] % 360) * (1 << 32) // 360)
    consts += "pub const HK: felt252 = %d;\n" % HK
    consts += "pub const BIGC: felt252 = %d;\n" % BIGC

    # --- five monsters nearest the player start, with their sector
    MT = {3004: "trooper", 9: "sergeant", 3001: "imp", 3002: "demon", 58: "spectre"}
    monsters_all = [t for t in md["things"] if t["type"] in MT]

    def d2(t):
        return (t["x"] - player["x"]) ** 2 + (t["y"] - player["y"]) ** 2

    chosen = sorted(monsters_all, key=d2)[:5]
    consts += carr("MON_X", [t["x"] * FRACUNIT + OFF for t in chosen])
    consts += carr("MON_Y", [t["y"] * FRACUNIT + OFF for t in chosen])
    consts += carr("MON_ANGLE", [(t["angle"] % 360) * (1 << 32) // 360 for t in chosen],
                   ty="u32")
    consts += carr("MON_SECTOR", [ss_sector[ss_of(t["x"], t["y"])] for t in chosen],
                   ty="u32")
    consts += "pub const PLAYER_SECTOR: u32 = %d;\n" % ss_sector[ss_of(player["x"], player["y"])]
    consts += "pub const PLAYER_SSECTOR: u32 = %d;\n" % ss_of(player["x"], player["y"])
    consts += "\n"

    # planar (representation B)
    consts += carr("L_AP", l_ap)
    consts += carr("L_AN", l_an)
    consts += carr("L_BP", l_bp)
    consts += carr("L_BN", l_bn)
    consts += carr("L_CP", l_cp)
    consts += carr("L_CN", l_cn)
    consts += carr("L_AB", l_ab)
    consts += carr("L_BB", l_bb)
    consts += carr("L_CB", l_cb)
    consts += carr("L_DIAG", l_diag)
    consts += carr("L_BBL", l_bbl)
    consts += carr("L_BBR", l_bbr)
    consts += carr("L_BBB", l_bbb)
    consts += carr("L_BBT", l_bbt)
    consts += carr("L_FLAGS", l_flags)
    consts += carr("L_BLOCKING", l_blocking)
    consts += carr("L_BLOCKMONST", l_blockmonst)
    consts += carr("L_TWOSIDED", l_twosided)
    consts += carr("L_FRONT", l_front)
    consts += carr("L_BACK", l_back)
    consts += carr("L_V1X", l_v1x)
    consts += carr("L_V1Y", l_v1y)
    consts += carr("L_V2X", l_v2x)
    consts += carr("L_V2Y", l_v2y)
    consts += carr("N_AP", n_ap)
    consts += carr("N_AN", n_an)
    consts += carr("N_BP", n_bp)
    consts += carr("N_BN", n_bn)
    consts += carr("N_CP", n_cp)
    consts += carr("N_CN", n_cn)
    consts += carr("N_AB", n_ab)
    consts += carr("N_BB", n_bb)
    consts += carr("N_CB", n_cb)
    consts += carr("N_C0", n_c0)
    consts += carr("N_C1", n_c1)
    consts += carr("SS_SECTOR", ss_sector)
    consts += carr("S_FLOOR", s_floor)
    consts += carr("S_CEIL", s_ceil)
    consts += carr("BM_START", starts)
    consts += carr("BM_COUNT", counts)
    consts += carr("BM_LINES", flat)
    consts += carr("BM_START_RAW", starts_raw)
    consts += carr("BM_COUNT_RAW", counts_raw)
    consts += carr("BM_LINES_RAW", flat_raw)
    consts += carr("REJECT_ROW", row_rej)

    # A blockmap cell crossed by no linedef lies entirely inside one sector
    # (sectors are bounded by linedefs), so its sector can be resolved by a
    # single array read instead of a BSP descent.  BM_CELL_SECTOR[cell] is that
    # sector, or 0xFFFF when the cell has lines in it and the BSP is needed.
    cell_sector = []
    n_uniform = 0
    for cy in range(bmp["nrows"]):
        for cx in range(bmp["ncols"]):
            cell = cy * bmp["ncols"] + cx
            if bmp["cells"][cell]:
                cell_sector.append(0xFFFF)
            else:
                px = bmp["origx"] + cx * 128 + 64
                py = bmp["origy"] + cy * 128 + 64
                cell_sector.append(ss_sector[ss_of(px, py)])
                n_uniform += 1
    consts += carr("BM_CELL_SECTOR", cell_sector)
    consts += "pub const BM_UNIFORM_CELLS: u32 = %d;\n" % n_uniform
    # REJECT as a flat felt-per-pair array.  A const fixed-size array cannot
    # exceed 32767 elements (the CASM type size is an i16), so the table is
    # chunked by whole sector rows.
    ROWS_PER_CHUNK = max(1, 32000 // max(1, nsec))
    n_chunks = (nsec + ROWS_PER_CHUNK - 1) // ROWS_PER_CHUNK
    consts += "pub const REJECT_ROWS_PER_CHUNK: u32 = %d;\n" % ROWS_PER_CHUNK
    consts += "pub const REJECT_CHUNKS: u32 = %d;\n" % n_chunks
    for k in range(n_chunks):
        lo = k * ROWS_PER_CHUNK * nsec
        hi = min(len(flat_rej), (k + 1) * ROWS_PER_CHUNK * nsec)
        consts += carr("REJECT_C%d" % k, flat_rej[lo:hi])

    with open(os.path.join(out_src, "mapdata.cairo"), "w") as fh:
        fh.write(consts)

    packed = hdr
    packed += carr("P_LINES", packed_lines)
    packed += carr("P_VERTS", packed_verts)
    with open(os.path.join(out_src, "mapdata_packed.cairo"), "w") as fh:
        fh.write(packed)

    # ---- tables
    FINEANGLES = 8192
    finesine = []
    for i in range(FINEANGLES + FINEANGLES // 4):
        v = int(round(math.sin(2.0 * math.pi * i / FINEANGLES) * FRACUNIT))
        finesine.append(v + FRACUNIT)          # bias -> non-negative
    tantoangle = []
    for i in range(2049):
        a = math.atan(i / 2048.0) * (1 << 32) / (2 * math.pi)
        tantoangle.append(int(a) & 0xFFFFFFFF)
    # deterministic 256-entry RNG table (NOT Doom's rndtable - see S1.md,
    # licensing; step cost is identical since it is a plain 256-felt lookup).
    rnd = []
    st = 0x2545F491
    for _ in range(256):
        st = (st * 1103515245 + 12345) & 0x7FFFFFFF
        rnd.append((st >> 16) & 0xFF)

    tables = hdr
    tables += "pub const FINEANGLES: u32 = %d;\n" % FINEANGLES
    tables += "pub const FINEMASK: u32 = %d;\n" % (FINEANGLES - 1)
    tables += "pub const ANGLETOFINESHIFT: u32 = 19;\n"
    tables += "pub const SINE_BIAS: felt252 = %d;\n" % FRACUNIT
    tables += carr("FINESINE", finesine)
    tables += carr("TANTOANGLE", tantoangle)
    tables += carr("RNDTABLE", rnd)
    with open(os.path.join(out_src, "tables.cairo"), "w") as fh:
        fh.write(tables)

    # ---- report
    from collections import Counter
    specials = Counter(l["special"] for l in lines if l["special"])
    thing_types = Counter(t["type"] for t in md["things"])
    twosided = sum(1 for l in lines if l["side1"] >= 0)
    rej_true = sum(flat_rej)
    cellsz = [len(c) for c in bmp["cells"]]
    nonempty = [c for c in cellsz if c]
    report = dict(
        map=mapname,
        counts=dict(vertexes=len(verts), linedefs=len(lines), sidedefs=len(sides),
                    sectors=nsec, things=len(md["things"]), segs=len(segs),
                    ssectors=len(ssectors), nodes=len(nodes),
                    reject_bytes=len(rej), blockmap_shorts=len(md["blockmap"]) // 2),
        linedefs=dict(twosided=twosided, onesided=len(lines) - twosided,
                      impassable=sum(1 for l in lines if l["flags"] & 1),
                      blockmonsters=sum(1 for l in lines if l["flags"] & 2),
                      specials=dict(sorted(specials.items()))),
        blockmap=dict(cols=bmp["ncols"], rows=bmp["nrows"],
                      cells=len(bmp["cells"]), nonempty=len(nonempty),
                      max_lines_per_cell=max(cellsz), avg_lines_per_cell=sum(cellsz) / len(cellsz),
                      avg_lines_per_nonempty=sum(nonempty) / max(1, len(nonempty)),
                      total_entries=sum(cellsz),
                      total_entries_dedup=len(flat)),
        reject=dict(pairs=nsec * nsec, blocked=rej_true,
                    blocked_pct=100.0 * rej_true / (nsec * nsec)),
        things=dict(total=len(md["things"]),
                    by_type=dict(sorted(thing_types.items())),
                    monsters=len(monsters),
                    monsters_by_name={MONSTER_TYPES[t["type"]]: sum(
                        1 for u in monsters if u["type"] == t["type"]) for t in monsters},
                    player_start=player),
        cairo_const_felts=dict(
            planar=sum(len(x) for x in (l_ap, l_an, l_bp, l_bn, l_cp, l_cn, l_bbl,
                                        l_bbr, l_bbb, l_bbt, l_flags, l_front,
                                        l_back, l_v1x, l_v1y, l_v2x, l_v2y,
                                        n_ap, n_an, n_bp, n_bn, n_cp, n_cn,
                                        n_c0, n_c1, ss_sector, s_floor, s_ceil,
                                        starts, counts, flat, row_rej)),
            packed_lines=len(packed_lines),
            reject_flat=len(flat_rej),
            finesine=len(finesine), tantoangle=len(tantoangle)),
    )
    with open(os.path.join(out_res, "e1m1_report.json"), "w") as fh:
        json.dump(report, fh, indent=2)

    # nearest monsters to the player start, for the prototype's 5 monsters
    def d2(t):
        return (t["x"] - player["x"]) ** 2 + (t["y"] - player["y"]) ** 2
    near = sorted(monsters, key=d2)[:12]
    with open(os.path.join(out_res, "e1m1_monsters.json"), "w") as fh:
        json.dump([dict(t, name=MONSTER_TYPES[t["type"]], dist=int(math.sqrt(d2(t))))
                   for t in near], fh, indent=2)

    print(json.dumps(report["counts"], indent=2))
    print("blockmap:", json.dumps(report["blockmap"]))
    print("reject:", json.dumps(report["reject"]))
    print("monsters:", report["things"]["monsters"], report["things"]["monsters_by_name"])
    print("planar const felts:", report["cairo_const_felts"]["planar"])
    return report, near, player


def main():
    wad, out_src, out_res = sys.argv[1], sys.argv[2], sys.argv[3]
    mapname = sys.argv[4] if len(sys.argv) > 4 else "E1M1"
    data, lumps = read_wad(wad)
    md = parse(data, lumps, mapname)
    bmp = parse_blockmap(md["blockmap"])
    emit(md, bmp, out_src, out_res, mapname)


if __name__ == "__main__":
    main()

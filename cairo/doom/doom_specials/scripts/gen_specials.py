#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Generate `doom_specials`' per-level tables from `doom_map`'s compiled level.

`doom_specials` needs three things `doom_map` deliberately does not ship,
because nothing else in the simulation reads them:

* **Sector adjacency.** Every `P_Find*Surrounding` of `p_spec.c` walks
  `sec->lines` and calls `getNextSector` on each, which is exactly "the
  sectors on the other side of this sector's two-sided lines". Doom stores
  `sec->lines`; we store the deduplicated *neighbour* list instead, which is
  equivalent for `P_FindLowestFloorSurrounding`,
  `P_FindHighestFloorSurrounding`, `P_FindLowestCeilingSurrounding` and
  `P_FindMinSurroundingLight` (all four are a min/max over `other->...`, so
  a repeated `other` cannot change the answer) and roughly half the size.
  A two-sided line whose two sides face the *same* sector makes that sector
  its own neighbour, as `getNextSector` does; E1M1 has 7 such lines.

* **Tag -> sectors.** `P_FindSectorFromLineTag` rescans all 182 sectors for
  every match; a precomputed list in ascending sector id answers the same
  iteration in one span slice.

* **Slot maps.** The dynamic sector state (see `../README.md`) is stored as
  one small array per *kind* of change, indexed by a slot rather than by
  sector id, so that a door writing its sector's latched ceiling copies 15
  felts and not 182. Which sectors can ever change is a static property of
  the map: the back sector of every manual-door line, the tagged sectors of
  every remote door / plat / floor line, the light-special sectors, and the
  secret sectors. This script derives those four sets and fails loudly on a
  linedef or sector special it does not know, so that a future map cannot
  silently lose a sector.

Everything is read back out of `cairo/doom/doom_map/src/levels/e1m1.cairo`
-- the *same* constants the Cairo code will index -- so no WAD, no network
and no `tools/wad` run are needed, and the tables cannot drift from the map
they describe.

Usage:

    python3 scripts/gen_specials.py             # print the word table only
    python3 scripts/gen_specials.py --write     # rewrite src/level/e1m1.cairo
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CRATE = HERE.parent
CAIRO = CRATE.parent.parent
DEFAULT_LEVEL = CAIRO / "doom" / "doom_map" / "src" / "levels" / "e1m1.cairo"

# --------------------------------------------------------------------------
# `doom_map`'s packing, transcribed (cairo/doom/doom_map/src/lib.cairo).
# --------------------------------------------------------------------------
BIAS = 2 ** 32
NO_SECTOR = 2047
ML_TWOSIDED = 4
W8, W11, W16 = 1 << 8, 1 << 11, 1 << 16

#: Neighbour ids per `ADJ_PACKED` felt: 8 x 8 bits = 64 bits, below 2^72 (A7).
ADJ_PER_FELT = 8
#: Sector ids per `TAG_PACKED` felt, same arithmetic.
TAG_PER_FELT = 8
#: Slot sentinel: this sector has no slot of that kind.
NO_SLOT = 255

#: Linedef specials this crate implements, and how each reaches its sectors.
#: `manual` = `EV_VerticalDoor`, which takes the line's **back** sector and
#: ignores the tag; `tagged` = `EV_Do*`, which iterates the line's tag.
LINE_SPECIALS = {
    1: ("manual", "ceiling"),  # DR Door open-wait-close
    2: ("tagged", "ceiling"),  # W1 Door open and stay
    11: ("none", None),  # S1 Exit level
    23: ("tagged", "floor"),  # S1 Floor lower to lowest surrounding
    26: ("manual", "ceiling"),  # DR Door, blue key
    62: ("tagged", "floor"),  # SR Lift down-wait-up-stay
    88: ("tagged", "floor"),  # WR Lift down-wait-up-stay
    117: ("manual", "ceiling"),  # DR Door blazing open-wait-close
}
#: Sector specials this crate implements.
SECTOR_SPECIALS = {
    1: "light",  # random flash        (P_SpawnLightFlash)
    7: "damage",  # 5 % per 32 tics    (P_PlayerInSpecialSector)
    9: "secret",  # counts once        (P_PlayerInSpecialSector)
    12: "light",  # synchronised slow strobe (P_SpawnStrobeFlash)
}


def read_array(text: str, name: str) -> list[int]:
    match = re.search(
        r"pub const %s: \[[a-z0-9]+; (\d+)\] = \[(.*?)\];" % name, text, re.S
    )
    if match is None:
        raise SystemExit("array %s not found in the level module" % name)
    count = int(match.group(1))
    values = [int(v) for v in match.group(2).replace("\n", " ").split(",") if v.strip()]
    if len(values) != count:
        raise SystemExit("array %s: %d values for a declared %d" % (name, len(values), count))
    return values


def load_level(path: Path) -> dict:
    text = path.read_text()
    floors = read_array(text, "S_FLOOR")
    ceilings = read_array(text, "S_CEIL")
    meta = read_array(text, "S_META")
    packed = read_array(text, "L_PACKED")
    sectors = [
        dict(
            id=i,
            floor=floors[i],
            ceiling=ceilings[i],
            light=meta[i] % W8,
            special=(meta[i] >> 8) % W8,
            tag=(meta[i] >> 16) % W16,
        )
        for i in range(len(meta))
    ]
    lines = [
        dict(
            id=i,
            flags=v % W16,
            special=(v >> 16) % W8,
            tag=(v >> 24) % W16,
            front=(v >> 41) % W11,
            back=(v >> 52) % W11,
        )
        for i, v in enumerate(packed)
    ]
    level_id = re.search(r"pub const LEVEL_ID: felt252 = '([^']+)';", text).group(1)
    return dict(id=level_id, sectors=sectors, lines=lines)


# --------------------------------------------------------------------------
# Derivations
# --------------------------------------------------------------------------


def adjacency(level: dict) -> list[list[int]]:
    """`getNextSector` over every line of every sector, deduplicated."""
    neighbours: list[set[int]] = [set() for _ in level["sectors"]]
    for line in level["lines"]:
        if not line["flags"] & ML_TWOSIDED:
            continue
        front, back = line["front"], line["back"]
        if front == NO_SECTOR or back == NO_SECTOR:
            continue
        if front == back:
            # `getNextSector` returns the sector itself here; keep it.
            neighbours[front].add(front)
            continue
        neighbours[front].add(back)
        neighbours[back].add(front)
    return [sorted(n) for n in neighbours]


def tag_table(level: dict) -> tuple[list[int], list[int], list[int]]:
    """tag -> sectors, in the ascending id order `P_FindSectorFromLineTag` visits."""
    buckets: dict[int, list[int]] = {}
    for sector in level["sectors"]:
        buckets.setdefault(sector["tag"], []).append(sector["id"])
    keys = sorted(buckets)
    start, items = [0], []
    for key in keys:
        items.extend(buckets[key])
        start.append(len(items))
    return keys, start, items


def slots(level: dict) -> dict[str, list[int]]:
    """The sectors each kind of dynamic state needs a slot for."""
    ceiling, floor, light, special = set(), set(), set(), set()
    tags: dict[int, list[int]] = {}
    for sector in level["sectors"]:
        tags.setdefault(sector["tag"], []).append(sector["id"])
    for line in level["lines"]:
        kind = line["special"]
        if kind == 0:
            continue
        if kind not in LINE_SPECIALS:
            raise SystemExit(
                "linedef %d carries special %d, which doom_specials does not "
                "implement -- extend LINE_SPECIALS and the Cairo dispatch "
                "together, or this sector would silently never move"
                % (line["id"], kind)
            )
        how, plane = LINE_SPECIALS[kind]
        if how == "manual":
            targets = [line["back"]] if line["back"] != NO_SECTOR else []
        elif how == "tagged":
            targets = tags.get(line["tag"], [])
        else:
            targets = []
        for sector in targets:
            (ceiling if plane == "ceiling" else floor).add(sector)
    for sector in level["sectors"]:
        kind = sector["special"]
        if kind == 0:
            continue
        if kind not in SECTOR_SPECIALS:
            raise SystemExit(
                "sector %d carries special %d, which doom_specials does not "
                "implement -- extend SECTOR_SPECIALS and the Cairo dispatch"
                % (sector["id"], kind)
            )
        role = SECTOR_SPECIALS[kind]
        if role == "light":
            light.add(sector["id"])
            special.add(sector["id"])  # `P_Spawn*Flash` clears `sector->special`
        elif role == "secret":
            special.add(sector["id"])  # cleared once the secret is counted
    return dict(
        ceiling=sorted(ceiling),
        floor=sorted(floor),
        light=sorted(light),
        special=sorted(special),
    )


def slot_map(members: list[int], count: int) -> list[int]:
    table = [NO_SLOT] * count
    for slot, sector in enumerate(members):
        table[sector] = slot
    return table


def pack(values: list[int], per_felt: int, width: int) -> list[int]:
    out = []
    for base in range(0, len(values), per_felt):
        felt = 0
        for offset, value in enumerate(values[base : base + per_felt]):
            if value >= (1 << width):
                raise SystemExit("value %d does not fit in %d bits" % (value, width))
            felt |= value << (width * offset)
        out.append(felt)
    return out


# --------------------------------------------------------------------------
# Emission
# --------------------------------------------------------------------------

HEADER = """// SPDX-License-Identifier: GPL-2.0-only
//
//! GENERATED -- do not edit (see `scripts/gen_specials.py`).
//!
//! The per-level tables `doom_specials` needs and `doom_map` does not ship,
//! derived from `doom_map`'s own compiled constants: sector adjacency
//! (`getNextSector` over `sec->lines`, deduplicated), the tag -> sectors
//! iteration of `P_FindSectorFromLineTag`, and the slot maps of the dynamic
//! sector state.
//!
//! Every felt below stays under 2^72 (PLAN.md A7): the packed arrays hold
//! eight 8-bit ids, 64 bits in all.
"""


def emit_array(name: str, kind: str, values: list[int]) -> str:
    body = ", ".join(str(v) for v in values)
    return "\npub const %s: [%s; %d] = [%s];\n" % (name, kind, len(values), body)


def build(level: dict) -> tuple[str, list[dict]]:
    count = len(level["sectors"])
    neighbours = adjacency(level)
    adj_items = [n for group in neighbours for n in group]
    adj_start, total = [0], 0
    for group in neighbours:
        total += len(group)
        adj_start.append(total)
    adj_packed = pack(adj_items, ADJ_PER_FELT, 8)

    tag_keys, tag_start, tag_items = tag_table(level)
    tag_packed = pack(tag_items, TAG_PER_FELT, 8)

    sets = slots(level)
    shift8 = [1 << (8 * i) for i in range(ADJ_PER_FELT)]

    arrays = [
        ("ADJ_START", "u32", adj_start, "adjacency", "planar"),
        ("ADJ_PACKED", "felt252", adj_packed, "adjacency", "packed"),
        ("TAG_KEYS", "u32", tag_keys, "tags", "planar"),
        ("TAG_START", "u32", tag_start, "tags", "planar"),
        ("TAG_PACKED", "felt252", tag_packed, "tags", "packed"),
        ("CEIL_SLOT", "u32", slot_map(sets["ceiling"], count), "slots", "planar"),
        ("FLOOR_SLOT", "u32", slot_map(sets["floor"], count), "slots", "planar"),
        ("LIGHT_SLOT", "u32", slot_map(sets["light"], count), "slots", "planar"),
        ("SPECIAL_SLOT", "u32", slot_map(sets["special"], count), "slots", "planar"),
        ("CEIL_SECTORS", "u32", sets["ceiling"], "slots", "planar"),
        ("FLOOR_SECTORS", "u32", sets["floor"], "slots", "planar"),
        ("LIGHT_SECTORS", "u32", sets["light"], "slots", "planar"),
        ("SPECIAL_SECTORS", "u32", sets["special"], "slots", "planar"),
        ("SHIFT8", "felt252", shift8, "scalar", "planar"),
    ]

    text = HEADER
    text += "\n/// Number of sectors on this level.\npub const NUM_SECTORS: u32 = %d;\n" % count
    text += "\n/// Neighbour ids per `ADJ_PACKED` felt (8 x 8 bits).\npub const ADJ_PER_FELT: u32 = %d;\n" % ADJ_PER_FELT
    text += "\n/// Sector ids per `TAG_PACKED` felt.\npub const TAG_PER_FELT: u32 = %d;\n" % TAG_PER_FELT
    text += "\n/// `*_SLOT` sentinel: this sector has no slot of that kind.\npub const NO_SLOT: u32 = %d;\n" % NO_SLOT
    docs = {
        "ADJ_START": "`[start[s], start[s + 1])` of sector `s`'s neighbours in `ADJ_PACKED`.",
        "ADJ_PACKED": "`getNextSector` neighbours, deduplicated, eight 8-bit ids per felt.",
        "TAG_KEYS": "Distinct sector tags, ascending; the search key of `P_FindSectorFromLineTag`.",
        "TAG_START": "`[start[k], start[k + 1])` of tag `TAG_KEYS[k]`'s sectors in `TAG_PACKED`.",
        "TAG_PACKED": "Sectors per tag, ascending id, eight 8-bit ids per felt.",
        "CEIL_SLOT": "Sector -> slot in the dynamic ceiling array, or `NO_SLOT`.",
        "FLOOR_SLOT": "Sector -> slot in the dynamic floor array, or `NO_SLOT`.",
        "LIGHT_SLOT": "Sector -> light thinker index, or `NO_SLOT`.",
        "SPECIAL_SLOT": "Sector -> slot in the dynamic `sector->special` array, or `NO_SLOT`.",
        "CEIL_SECTORS": "Slot -> sector, the inverse of `CEIL_SLOT`.",
        "FLOOR_SECTORS": "Slot -> sector, the inverse of `FLOOR_SLOT`.",
        "LIGHT_SECTORS": "Slot -> sector, the inverse of `LIGHT_SLOT` (ascending id, which is the order `P_SpawnSpecials` visits and therefore the order the RNG is drawn in).",
        "SPECIAL_SECTORS": "Slot -> sector, the inverse of `SPECIAL_SLOT`.",
        "SHIFT8": "`2^(8 k)`, the shift of the k-th id inside a packed felt.",
    }
    manifest = []
    for name, kind, values, group, layout in arrays:
        text += "\n/// %s\n" % docs[name]
        text += emit_array(name, kind, values).lstrip("\n")
        manifest.append(dict(name=name, group=group, layout=layout, words=len(values)))
    return text, manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--level", type=Path, default=DEFAULT_LEVEL)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    level = load_level(args.level)
    text, manifest = build(level)
    total = sum(entry["words"] for entry in manifest)

    print("%-18s %-12s %-8s %8s" % ("array", "group", "layout", "words"))
    for entry in sorted(manifest, key=lambda e: -e["words"]):
        print("%-18s %-12s %-8s %8d" % (entry["name"], entry["group"], entry["layout"], entry["words"]))
    print("%-18s %-12s %-8s %8d" % ("TOTAL", "", "", total))

    if args.write:
        out = CRATE / "src" / "level" / ("%s.cairo" % level["id"].lower())
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
        manifest_path = CRATE / "bench" / "manifest.json"
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(
            json.dumps(
                dict(
                    level=level["id"],
                    array_count=len(manifest),
                    total_words=total,
                    arrays=manifest,
                ),
                indent=2,
            )
            + "\n"
        )
        print("\nwrote %s and %s" % (out, manifest_path))
        subprocess.run(["scarb", "fmt"], cwd=str(CRATE), check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())

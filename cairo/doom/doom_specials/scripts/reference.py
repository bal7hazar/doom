#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""An independent Python model of linuxdoom-1.10's sector specials.

This is the *reference* half of `doom_specials`' test suite (PLAN.md §3.1
rule 4): a transcription of `p_spec.c`, `p_doors.c`, `p_plats.c`,
`p_floor.c`, `p_lights.c` and `p_switch.c` that shares no code with the
Cairo implementation and runs on the same E1M1 data, read straight out of
`doom_map`'s generated constants. What it computes becomes
`src/tests/vectors.cairo`, and `src/tests.cairo` checks the Cairo thinkers
against it.

Two things are modelled the *vanilla* way on purpose, so that the Cairo
side's shortcuts are checked rather than mirrored:

* the light thinkers count **down** here (`if (--flash->count) return;`)
  while Cairo stores the absolute tic of the next flip. `--check-light`
  proves the two agree tic by tic over the whole run;
* the sector state is a plain full array indexed by sector id, not Cairo's
  slot arrays, so a sector the generator forgot to give a slot would show up
  as a mismatch.

Usage:

    python3 scripts/reference.py              # run the model, print a summary
    python3 scripts/reference.py --write      # rewrite src/tests/vectors.cairo
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CRATE = HERE.parent
CAIRO = CRATE.parent.parent
LEVEL = CAIRO / "doom" / "doom_map" / "src" / "levels" / "e1m1.cairo"
TABLES = CAIRO / "doom" / "doom_things" / "src" / "tables.cairo"

FRACUNIT = 65536
BIAS = 2 ** 32
MAXINT = 0x7FFFFFFF
NO_SECTOR = 2047
ML_TWOSIDED = 4
ML_SECRET = 32
W8, W11, W16 = 1 << 8, 1 << 11, 1 << 16

VDOORSPEED = 2 * FRACUNIT
VDOORWAIT = 150
BLAZESPEED = 4 * VDOORSPEED
PLATSPEED = 4 * FRACUNIT
PLATWAIT = 35 * 3
FLOORSPEED = FRACUNIT
DOOR_HEADROOM = 4 * FRACUNIT
STROBEBRIGHT = 5
SLOWDARK = 35
FLASH_MAXTIME = 64
FLASH_MINTIME = 7

OK, CRUSHED, PASTDEST = 0, 1, 2


# --------------------------------------------------------------------------
# The level, out of `doom_map`'s own constants
# --------------------------------------------------------------------------


def read_array(text: str, name: str) -> list[int]:
    match = re.search(r"pub const %s: \[[a-z0-9]+; (\d+)\] = \[(.*?)\];" % name, text, re.S)
    if match is None:
        raise SystemExit("array %s not found" % name)
    return [int(v) for v in match.group(2).replace("\n", " ").split(",") if v.strip()]


def load_level() -> dict:
    text = LEVEL.read_text()
    floors = read_array(text, "S_FLOOR")
    ceilings = read_array(text, "S_CEIL")
    meta = read_array(text, "S_META")
    packed = read_array(text, "L_PACKED")
    sectors = [
        dict(
            id=i,
            floor=floors[i] - BIAS,
            ceiling=ceilings[i] - BIAS,
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
    adjacency: list[set[int]] = [set() for _ in sectors]
    for line in lines:
        if not line["flags"] & ML_TWOSIDED:
            continue
        front, back = line["front"], line["back"]
        if front == NO_SECTOR or back == NO_SECTOR:
            continue
        if front == back:
            adjacency[front].add(front)
            continue
        adjacency[front].add(back)
        adjacency[back].add(front)
    return dict(sectors=sectors, lines=lines, adjacency=[sorted(a) for a in adjacency])


def load_rndtable() -> list[int]:
    return read_array(TABLES.read_text(), "RNDTABLE")


# --------------------------------------------------------------------------
# The model
# --------------------------------------------------------------------------


class Specials:
    """`P_SpawnSpecials` + the thinkers, on a full per-sector array."""

    def __init__(self, level: dict, table: list[int], rng_index: int = 1) -> None:
        self.level = level
        self.table = table
        self.rng = rng_index
        self.adj = level["adjacency"]
        self.floor = [s["floor"] for s in level["sectors"]]
        self.ceiling = [s["ceiling"] for s in level["sectors"]]
        self.light = [s["light"] for s in level["sectors"]]
        self.special = [s["special"] for s in level["sectors"]]
        self.tag = [s["tag"] for s in level["sectors"]]
        self.movers: list[dict] = []
        self.lights: list[dict] = []
        self.used: set[int] = set()
        self.secrets = 0
        self.exit = False
        self.events: list[tuple[str, int]] = []
        self.spawn()

    # --- P_Random --------------------------------------------------------
    def p_random(self) -> int:
        value = self.table[self.rng]
        self.rng = (self.rng + 1) % 256
        return value

    # --- P_Find*Surrounding ---------------------------------------------
    def lowest_floor_surrounding(self, sec: int) -> int:
        return min([self.floor[sec]] + [self.floor[n] for n in self.adj[sec]])

    def highest_floor_surrounding(self, sec: int) -> int:
        return max([-500 * FRACUNIT] + [self.floor[n] for n in self.adj[sec]])

    def lowest_ceiling_surrounding(self, sec: int) -> int:
        return min([MAXINT] + [self.ceiling[n] for n in self.adj[sec]])

    def min_surrounding_light(self, sec: int, top: int) -> int:
        return min([top] + [self.light[n] for n in self.adj[sec]])

    # --- P_SpawnSpecials -------------------------------------------------
    def spawn(self) -> None:
        for sector in self.level["sectors"]:
            kind, sec = sector["special"], sector["id"]
            if kind == 1:  # P_SpawnLightFlash
                top = self.light[sec]
                self.lights.append(
                    dict(
                        kind="flash",
                        sector=sec,
                        maxlight=top,
                        minlight=self.min_surrounding_light(sec, top),
                        maxtime=FLASH_MAXTIME,
                        mintime=FLASH_MINTIME,
                        count=(self.p_random() & FLASH_MAXTIME) + 1,
                    )
                )
                self.special[sec] = 0
            elif kind == 12:  # P_SpawnStrobeFlash(sec, SLOWDARK, inSync = 1)
                top = self.light[sec]
                low = self.min_surrounding_light(sec, top)
                self.lights.append(
                    dict(
                        kind="strobe",
                        sector=sec,
                        maxlight=top,
                        minlight=0 if low == top else low,
                        brighttime=STROBEBRIGHT,
                        darktime=SLOWDARK,
                        count=1,
                    )
                )
                self.special[sec] = 0

    # --- T_MovePlane -----------------------------------------------------
    @staticmethod
    def move_plane(current: int, speed: int, dest: int, up: bool) -> tuple[int, int]:
        candidate = current + speed if up else current - speed
        past = candidate > dest if up else candidate < dest
        return (dest if past else candidate), (PASTDEST if past else OK)

    def plane(self, mover: dict) -> list[int]:
        return self.ceiling if mover["kind"].startswith("door") else self.floor

    # --- the thinkers ----------------------------------------------------
    def tick_door(self, mv: dict) -> bool:
        sec = mv["sector"]
        blazing = mv["kind"] == "doorBlazeRaise"
        if mv["phase"] == "wait":
            mv["count"] -= 1
            if mv["count"] == 0:
                mv["phase"] = "down"
                self.events.append(("bdcls" if blazing else "dorcls", sec))
            return True
        if mv["phase"] == "down":
            height, res = self.move_plane(
                self.ceiling[sec], mv["speed"], self.floor[sec], False
            )
            self.ceiling[sec] = height
            if res == PASTDEST:
                if blazing:
                    self.events.append(("bdcls", sec))
                return False
            return True
        height, res = self.move_plane(self.ceiling[sec], mv["speed"], mv["top"], True)
        self.ceiling[sec] = height
        if res != PASTDEST:
            return True
        if mv["kind"] == "doorOpen":
            return False
        mv["phase"] = "wait"
        mv["count"] = mv["wait"]
        return True

    def tick_plat(self, mv: dict) -> bool:
        sec = mv["sector"]
        if mv["phase"] == "up":
            height, res = self.move_plane(self.floor[sec], mv["speed"], mv["top"], True)
            self.floor[sec] = height
            if res == PASTDEST:
                self.events.append(("pstop", sec))
                return False
            return True
        if mv["phase"] == "down":
            height, res = self.move_plane(self.floor[sec], mv["speed"], mv["bottom"], False)
            self.floor[sec] = height
            if res == PASTDEST:
                mv["count"] = mv["wait"]
                mv["phase"] = "wait"
                self.events.append(("pstop", sec))
            return True
        mv["count"] -= 1
        if mv["count"] == 0:
            mv["phase"] = "up" if self.floor[sec] == mv["bottom"] else "down"
            self.events.append(("pstart", sec))
        return True

    def tick_floor(self, mv: dict, tic: int) -> bool:
        sec = mv["sector"]
        height, res = self.move_plane(self.floor[sec], mv["speed"], mv["bottom"], False)
        self.floor[sec] = height
        if not tic & 7:
            self.events.append(("stnmov", sec))
        return res != PASTDEST

    def tick_light(self, flash: dict) -> None:
        flash["count"] -= 1
        if flash["count"]:
            return
        sec = flash["sector"]
        if flash["kind"] == "strobe":
            if self.light[sec] == flash["minlight"]:
                self.light[sec] = flash["maxlight"]
                flash["count"] = flash["brighttime"]
            else:
                self.light[sec] = flash["minlight"]
                flash["count"] = flash["darktime"]
            return
        if self.light[sec] == flash["maxlight"]:
            self.light[sec] = flash["minlight"]
            flash["count"] = (self.p_random() & flash["mintime"]) + 1
        else:
            self.light[sec] = flash["maxlight"]
            flash["count"] = (self.p_random() & flash["maxtime"]) + 1

    def tick(self, tic: int) -> None:
        """`P_RunThinkers` for one tic: lights first (they are spawned first
        and Doom's thinker list is in creation order), then the planes."""
        for flash in self.lights:
            self.tick_light(flash)
        kept = []
        for mv in self.movers:
            if mv["kind"].startswith("door"):
                alive = self.tick_door(mv)
            elif mv["kind"] == "plat":
                alive = self.tick_plat(mv)
            else:
                alive = self.tick_floor(mv, tic)
            if alive:
                kept.append(mv)
        self.movers = kept

    # --- EV_Do* ----------------------------------------------------------
    def has_mover(self, sec: int) -> bool:
        return any(mv["sector"] == sec for mv in self.movers)

    def tagged(self, tag: int) -> list[int]:
        return [i for i in range(len(self.tag)) if self.tag[i] == tag]

    def ev_do_door(self, tag: int, kind: str) -> bool:
        started = False
        for sec in self.tagged(tag):
            if self.has_mover(sec):
                continue
            started = True
            top = self.lowest_ceiling_surrounding(sec) - DOOR_HEADROOM
            if top != self.ceiling[sec]:
                self.events.append(("doropn", sec))
            self.movers.append(
                dict(
                    kind=kind,
                    phase="up",
                    sector=sec,
                    top=top,
                    bottom=self.floor[sec],
                    speed=VDOORSPEED,
                    wait=VDOORWAIT,
                    count=0,
                )
            )
        return started

    def ev_do_plat(self, tag: int) -> bool:
        started = False
        for sec in self.tagged(tag):
            if self.has_mover(sec):
                continue
            started = True
            low = min(self.lowest_floor_surrounding(sec), self.floor[sec])
            self.events.append(("pstart", sec))
            self.movers.append(
                dict(
                    kind="plat",
                    phase="down",
                    sector=sec,
                    top=self.floor[sec],
                    bottom=low,
                    speed=PLATSPEED,
                    wait=PLATWAIT,
                    count=0,
                )
            )
        return started

    def ev_do_floor(self, tag: int) -> bool:
        started = False
        for sec in self.tagged(tag):
            if self.has_mover(sec):
                continue
            started = True
            self.movers.append(
                dict(
                    kind="floor",
                    phase="down",
                    sector=sec,
                    top=self.floor[sec],
                    bottom=self.lowest_floor_surrounding(sec),
                    speed=FLOORSPEED,
                    wait=0,
                    count=0,
                )
            )
        return started

    def ev_vertical_door(self, line: dict, is_player: bool, blue_key: bool) -> None:
        special = line["special"]
        if special == 26:
            if not is_player:
                return
            if not blue_key:
                self.events.append(("oof", line["id"]))
                return
        sec = line["back"]
        if sec == NO_SECTOR:
            return
        blazing = special == 117
        for mv in self.movers:
            if mv["sector"] != sec:
                continue
            if mv["phase"] == "down":
                mv["phase"] = "up"
                self.events.append(("bdopn" if blazing else "doropn", sec))
            else:
                if not is_player:
                    return
                mv["phase"] = "down"
                self.events.append(("bdcls" if blazing else "dorcls", sec))
            return
        self.events.append(("bdopn" if blazing else "doropn", sec))
        self.movers.append(
            dict(
                kind="doorBlazeRaise" if blazing else "doorNormal",
                phase="up",
                sector=sec,
                top=self.lowest_ceiling_surrounding(sec) - DOOR_HEADROOM,
                bottom=self.floor[sec],
                speed=BLAZESPEED if blazing else VDOORSPEED,
                wait=VDOORWAIT,
                count=0,
            )
        )

    # --- the entry points -------------------------------------------------
    def line_special(self, line_id: int) -> tuple[int, int]:
        if line_id in self.used:
            return 0, 0
        line = self.level["lines"][line_id]
        return line["special"], line["tag"]

    def use_line(self, line_id: int, side: int, is_player: bool, blue_key: bool) -> bool:
        if side:
            return False
        special, tag = self.line_special(line_id)
        line = dict(self.level["lines"][line_id])
        line["special"] = special
        if not is_player:
            if line["flags"] & ML_SECRET:
                return False
            if special != 1:
                return False
        if special in (1, 26, 117):
            self.ev_vertical_door(line, is_player, blue_key)
            return True
        if special == 11:
            self.used.add(line_id)
            self.events.append(("switch", line_id))
            self.exit = True
            return True
        if special == 23:
            if self.ev_do_floor(tag):
                self.used.add(line_id)
                self.events.append(("switch", line_id))
            return True
        if special == 62:
            if self.ev_do_plat(tag):
                self.events.append(("switch", line_id))
            return True
        return False

    def cross_line(self, line_id: int, side: int, is_player: bool) -> None:
        special, tag = self.line_special(line_id)
        if not is_player and special != 88:
            return
        if special == 2:
            self.ev_do_door(tag, "doorOpen")
            self.used.add(line_id)
        elif special == 88:
            self.ev_do_plat(tag)

    def player_in_special_sector(
        self, sec: int, on_floor: bool, suit: bool, tic: int
    ) -> tuple[int, bool]:
        if not on_floor:
            return 0, False
        special = self.special[sec]
        if special == 7:
            if suit or tic % 32:
                return 0, False
            return 5, False
        if special == 9:
            self.secrets += 1
            self.special[sec] = 0
            return 0, True
        return 0, False


# --------------------------------------------------------------------------
# The scripted 700-tic run
# --------------------------------------------------------------------------

#: `use` the first DR door (linedef 55, back sector 10).
DOOR_LINE = 55
#: `use` the first switch lift (linedef 594, tag 1 -> sector 98).
LIFT_LINE = 594
#: walk over the repeatable lift trigger (linedef 593, same tag).
WALK_LIFT_LINE = 593
SEQUENCE_TICS = 700
SAMPLE_EVERY = 25


def phase_of(model: "Specials", sector: int) -> str | None:
    for mv in model.movers:
        if mv["sector"] == sector:
            return mv["phase"]
    return None


def scripted_run(level: dict, table: list[int]) -> dict:
    model = Specials(level, table)
    door_sector = level["lines"][DOOR_LINE]["back"]
    lift_sector = model.tagged(level["lines"][LIFT_LINE]["tag"])[0]
    light_sectors = [f["sector"] for f in model.lights]

    samples, checksum = [], 0
    door_open_tic = door_close_start = door_closed_tic = -1
    lift_bottom_tic = lift_up_tic = lift_stop_tic = -1
    for tic in range(SEQUENCE_TICS):
        if tic == 10:
            model.use_line(DOOR_LINE, 0, True, False)
        if tic == 200:
            model.use_line(LIFT_LINE, 0, True, False)
        if tic == 400:
            # The lift is parked at the top again by now: a walk trigger
            # sends it back down.
            model.cross_line(WALK_LIFT_LINE, 0, True)
        before_door = phase_of(model, door_sector)
        before_lift = phase_of(model, lift_sector)
        model.tick(tic)
        after_door = phase_of(model, door_sector)
        after_lift = phase_of(model, lift_sector)
        if before_door == "up" and after_door == "wait" and door_open_tic < 0:
            door_open_tic = tic
        if before_door == "wait" and after_door == "down" and door_close_start < 0:
            door_close_start = tic
        if before_door is not None and after_door is None and door_closed_tic < 0:
            door_closed_tic = tic
        if before_lift == "down" and after_lift == "wait" and lift_bottom_tic < 0:
            lift_bottom_tic = tic
        if before_lift == "wait" and after_lift == "up" and lift_up_tic < 0:
            lift_up_tic = tic
        if before_lift is not None and after_lift is None and lift_stop_tic < 0:
            lift_stop_tic = tic

        lights = sum(model.light[s] for s in light_sectors)
        checksum += (tic + 1) * (
            (model.ceiling[door_sector] + BIAS)
            + 5 * (model.floor[lift_sector] + BIAS)
            + 11 * lights
        )
        if tic % SAMPLE_EVERY == 0:
            samples.append(
                (
                    tic,
                    model.ceiling[door_sector] + BIAS,
                    model.floor[lift_sector] + BIAS,
                    lights,
                )
            )
    return dict(
        door_sector=door_sector,
        lift_sector=lift_sector,
        light_sectors=light_sectors,
        samples=samples,
        checksum=checksum,
        door_open_tic=door_open_tic,
        door_close_start=door_close_start,
        door_closed_tic=door_closed_tic,
        lift_bottom_tic=lift_bottom_tic,
        lift_up_tic=lift_up_tic,
        lift_stop_tic=lift_stop_tic,
        rng_index=model.rng,
    )


def light_timeline(level: dict, table: list[int], tics: int) -> list[int]:
    """The nine light levels at every tic, folded so the Cairo side can
    compare a single number per sampled tic."""
    model = Specials(level, table)
    out = []
    for tic in range(tics):
        model.tick(tic)
        out.append([model.light[f["sector"]] for f in model.lights])
    return out


# --------------------------------------------------------------------------
# Emission
# --------------------------------------------------------------------------

HEADER = """// SPDX-License-Identifier: GPL-2.0-only
//
//! GENERATED -- do not edit (see `scripts/reference.py`).
//!
//! What an independent Python transcription of linuxdoom-1.10's
//! `p_spec.c` / `p_doors.c` / `p_plats.c` / `p_floor.c` / `p_lights.c`
//! computes on Freedoom E1M1. `src/tests.cairo` checks the Cairo thinkers
//! against these numbers; nothing here is read back out of the Cairo
//! implementation, so the two can only agree by both being right.
"""


def emit(name: str, kind: str, values: list[int], doc: str) -> str:
    body = ", ".join(str(v) for v in values)
    return "\n/// %s\npub const %s: [%s; %d] = [%s];\n" % (
        doc,
        name,
        kind,
        len(values),
        body,
    )


def build_vectors(level: dict, table: list[int]) -> str:
    model = Specials(level, table)
    run = scripted_run(level, table)

    text = HEADER

    # --- P_SpawnSpecials -------------------------------------------------
    spawn: list[int] = []
    for flash in model.lights:
        spawn.extend(
            [
                flash["sector"],
                0 if flash["kind"] == "flash" else 1,
                flash["maxlight"],
                flash["maxlight"],
                flash["minlight"],
                flash["maxtime"] if flash["kind"] == "flash" else flash["brighttime"],
                flash["mintime"] if flash["kind"] == "flash" else flash["darktime"],
                flash["count"] - 1,
            ]
        )
    text += "\n/// Number of light thinkers `P_SpawnSpecials` creates.\npub const NUM_LIGHTS: u32 = %d;\n" % len(
        model.lights
    )
    text += emit(
        "SPAWN_LIGHTS",
        "u32",
        spawn,
        "Eight fields per light thinker at spawn: sector, kind (0 flash, "
        "1 strobe), light, maxlight, minlight, hi_time, lo_time, next "
        "(= Doom's initial `count - 1`, the absolute tic of the first flip).",
    )
    text += "\n/// `P_Random` cursor after `P_SpawnSpecials`, from `from_index(1)`.\npub const SPAWN_RNG: u32 = %d;\n" % (
        model.rng
    )

    # --- doors -----------------------------------------------------------
    doors: list[int] = []
    for line in level["lines"]:
        if line["special"] in (1, 26, 117):
            sec = line["back"]
            doors.extend(
                [
                    line["id"],
                    sec,
                    model.ceiling[sec] + BIAS,
                    model.lowest_ceiling_surrounding(sec) - DOOR_HEADROOM + BIAS,
                ]
            )
    text += "\n/// Manual-door lines (specials 1, 26, 117).\npub const NUM_MANUAL_DOORS: u32 = %d;\n" % (
        len(doors) // 4
    )
    text += emit(
        "MANUAL_DOORS",
        "felt252",
        doors,
        "Four fields per manual-door line: linedef, its back sector, that "
        "sector's ceiling at spawn and the `topheight` "
        "`P_FindLowestCeilingSurrounding(sec) - 4 * FRACUNIT` a door opens "
        "to, both in `fixed` encoding.",
    )

    # --- tagged specials --------------------------------------------------
    tagged: list[int] = []
    for line in level["lines"]:
        if line["special"] in (2, 23, 62, 88):
            for sec in model.tagged(line["tag"]):
                tagged.extend([line["id"], line["special"], line["tag"], sec])
    text += "\n/// (linedef, special, tag, sector) rows for every tagged special.\npub const NUM_TAGGED: u32 = %d;\n" % (
        len(tagged) // 4
    )
    text += emit("TAGGED", "u32", tagged, "Four fields per row: linedef, special, tag, sector.")

    # --- the scripted run -------------------------------------------------
    text += "\n/// Sector the scripted run's door moves (linedef %d's back sector).\npub const SEQ_DOOR_SECTOR: u32 = %d;\n" % (
        DOOR_LINE,
        run["door_sector"],
    )
    text += "\n/// Sector the scripted run's lift moves (linedef %d's tag).\npub const SEQ_LIFT_SECTOR: u32 = %d;\n" % (
        LIFT_LINE,
        run["lift_sector"],
    )
    text += "\n/// Linedefs the scripted run touches, at tics 10, 200 and 400.\npub const SEQ_DOOR_LINE: u32 = %d;\npub const SEQ_LIFT_LINE: u32 = %d;\npub const SEQ_WALK_LIFT_LINE: u32 = %d;\n" % (
        DOOR_LINE,
        LIFT_LINE,
        WALK_LIFT_LINE,
    )
    text += "\n/// Length of the scripted run, and its sampling period.\npub const SEQ_TICS: u32 = %d;\npub const SEQ_SAMPLE_EVERY: u32 = %d;\n" % (
        SEQUENCE_TICS,
        SAMPLE_EVERY,
    )
    flat: list[int] = []
    for tic, ceiling, floor, lights in run["samples"]:
        flat.extend([tic, ceiling, floor, lights])
    text += "\n/// Samples taken by the scripted run.\npub const NUM_SEQ_SAMPLES: u32 = %d;\n" % len(
        run["samples"]
    )
    text += emit(
        "SEQ_SAMPLES",
        "felt252",
        flat,
        "Four fields per sample: tic, the door sector's ceiling and the lift "
        "sector's floor in `fixed` encoding, and the sum of the nine light "
        "levels.",
    )
    text += (
        "\n/// `sum over tics of (tic + 1) * (ceiling + 5 * floor + 11 * lights)`\n"
        "/// over the whole 700-tic run -- one number that moves if any tic of\n"
        "/// any thinker moves.\npub const SEQ_CHECKSUM: felt252 = %d;\n" % run["checksum"]
    )
    text += (
        "\n/// Phase changes of the scripted run's door and lift, as absolute\n"
        "/// tics: door fully open, door starts closing, door thinker removed;\n"
        "/// lift reaches the bottom, starts back up, thinker removed.\n"
        "pub const SEQ_DOOR_OPEN_TIC: u32 = %d;\n"
        "pub const SEQ_DOOR_CLOSE_TIC: u32 = %d;\n"
        "pub const SEQ_DOOR_DONE_TIC: u32 = %d;\n"
        "pub const SEQ_LIFT_BOTTOM_TIC: u32 = %d;\n"
        "pub const SEQ_LIFT_UP_TIC: u32 = %d;\n"
        "pub const SEQ_LIFT_DONE_TIC: u32 = %d;\n"
        % (
            run["door_open_tic"],
            run["door_close_start"],
            run["door_closed_tic"],
            run["lift_bottom_tic"],
            run["lift_up_tic"],
            run["lift_stop_tic"],
        )
    )

    # --- the light timeline ----------------------------------------------
    timeline = light_timeline(level, table, 200)
    flat = []
    for tic in range(0, 200, 10):
        flat.extend(timeline[tic])
    text += emit(
        "LIGHT_TIMELINE",
        "u32",
        flat,
        "The nine light levels every 10 tics for the first 200 tics of a run "
        "with no trigger at all, nine values per sample -- the `T_StrobeFlash` "
        "and `T_LightFlash` reference.",
    )
    text += "\n/// Samples in `LIGHT_TIMELINE`, nine values each.\npub const LIGHT_SAMPLES: u32 = %d;\n" % (
        len(flat) // 9
    )
    return text


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    level = load_level()
    table = load_rndtable()
    run = scripted_run(level, table)
    print("door sector %d, lift sector %d" % (run["door_sector"], run["lift_sector"]))
    print(
        "door: open at tic %d, closes at %d, gone at %d"
        % (run["door_open_tic"], run["door_close_start"], run["door_closed_tic"])
    )
    print(
        "lift: bottom at tic %d, up at %d, gone at %d"
        % (run["lift_bottom_tic"], run["lift_up_tic"], run["lift_stop_tic"])
    )
    print("checksum %d" % run["checksum"])

    text = build_vectors(level, table)
    if args.write:
        out = CRATE / "src" / "tests" / "vectors.cairo"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
        print("wrote %s" % out)
        subprocess.run(["scarb", "fmt"], cwd=str(CRATE), check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())

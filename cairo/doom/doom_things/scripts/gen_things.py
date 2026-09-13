#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Derive `doom_things`'s tables from linuxdoom-1.10's data tables.

Reads `info.h`, `info.c`, `m_random.c` and `d_items.c` from a local checkout
of the original sources (id Software's linuxdoom-1.10, GPL-2.0-only since the
1999 release -- the same tables `doomgeneric` ships) and emits:

* `src/tables.cairo` -- the `fsm::StateTables` columns (sprite, frame, tics,
  action id, next state), the planar `mobjinfo` columns, Doom's 256-entry
  `rndtable` for `prng`, and the doomednum lookup;
* `generated/sprites.json` -- the sprite-name table and the doomednum ->
  spawn sprite map the TypeScript client needs to draw a thing.

**No C code is copied**: this script parses the upstream tables and re-emits
the *numbers* in this project's own layout, with state and mobj ids remapped
to a compact range that covers only what Freedoom E1M1 can spawn. The C files
are never committed; fetch them yourself, e.g.

    cd /tmp && for f in info.h info.c m_random.c d_items.c; do
      curl -sSO https://raw.githubusercontent.com/id-Software/DOOM/master/linuxdoom-1.10/$f
    done
    python3 cairo/doom/doom_things/scripts/gen_things.py \\
        --src /tmp --level /tmp/wadout/e1m1.json --write

## What is included

Everything Freedoom E1M1 can spawn, at any skill (the skill-2 subset is
flagged in the generated table but not used to *exclude* an entry: the skill
is a decision, docs/G0.md D3, and keeping the whole map roster costs ~200
words), plus:

* `MT_PLAYER` and the four player weapons reachable on the map (fist,
  chainsaw, pistol, shotgun, chaingun -- the last two only via a shotgun
  guy's drop, since the shotgun and chaingun *pickups* are all multiplayer-
  only or easy-only at skill 2);
* the things monsters and the player create at run time: `MT_TROOPSHOT`
  (the imp's fireball), `MT_PUFF`, `MT_BLOOD`, and the items `P_KillMobj`
  drops (`MT_CLIP` for a zombieman, `MT_SHOTGUN` for a shotgun guy);
* the transitive closure of every state those entries reach.
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

FRACUNIT = 65536
BIAS = 1 << 32  # fixed::BIAS
NO_ACTION = "NO_ACTION"  # fsm::NO_ACTION, reserved for row 0

# Entries that are not on the map but are reachable at run time.
EXTRA_TYPES = [
    "MT_PLAYER",
    "MT_TROOPSHOT",  # the imp's fireball
    "MT_PUFF",  # hitscan hitting a wall
    "MT_BLOOD",  # hitscan hitting a body
    "MT_CLIP",  # P_KillMobj drops one for MT_POSSESSED
    "MT_SHOTGUN",  # ... and one for MT_SHOTGUY
]

# The weapons the player can hold on this map, as (name, weaponinfo index).
WEAPONS = [("fist", 0), ("pistol", 1), ("shotgun", 2), ("chaingun", 3), ("chainsaw", 7)]

MOBJINFO_FIELDS = [
    "doomednum",
    "spawnstate",
    "spawnhealth",
    "seestate",
    "seesound",
    "reactiontime",
    "attacksound",
    "painstate",
    "painchance",
    "painsound",
    "meleestate",
    "missilestate",
    "deathstate",
    "xdeathstate",
    "deathsound",
    "speed",
    "radius",
    "height",
    "mass",
    "damage",
    "activesound",
    "flags",
    "raisestate",
]

# Fields the simulation reads. Sounds are dropped (D10: no audio in the
# proven core; the client plays sounds off the state it is handed).
KEPT_FIELDS = [
    "doomednum",
    "spawnstate",
    "spawnhealth",
    "seestate",
    "reactiontime",
    "painstate",
    "painchance",
    "meleestate",
    "missilestate",
    "deathstate",
    "xdeathstate",
    "raisestate",
    "speed",
    "radius",
    "height",
    "mass",
    "damage",
    "flags",
]
STATE_FIELDS = {
    "spawnstate",
    "seestate",
    "painstate",
    "meleestate",
    "missilestate",
    "deathstate",
    "xdeathstate",
    "raisestate",
}

MF_FLAGS = {
    "MF_SPECIAL": 1,
    "MF_SOLID": 2,
    "MF_SHOOTABLE": 4,
    "MF_NOSECTOR": 8,
    "MF_NOBLOCKMAP": 16,
    "MF_AMBUSH": 32,
    "MF_JUSTHIT": 64,
    "MF_JUSTATTACKED": 128,
    "MF_SPAWNCEILING": 256,
    "MF_NOGRAVITY": 512,
    "MF_DROPOFF": 1024,
    "MF_PICKUP": 2048,
    "MF_NOCLIP": 4096,
    "MF_SLIDE": 8192,
    "MF_FLOAT": 16384,
    "MF_TELEPORT": 32768,
    "MF_MISSILE": 65536,
    "MF_DROPPED": 131072,
    "MF_SHADOW": 262144,
    "MF_NOBLOOD": 524288,
    "MF_CORPSE": 1048576,
    "MF_INFLOAT": 2097152,
    "MF_COUNTKILL": 4194304,
    "MF_COUNTITEM": 8388608,
    "MF_SKULLFLY": 16777216,
    "MF_NOTDMATCH": 33554432,
    "MF_TRANSLATION": 0xC000000,
    "MF_TRANSSHIFT": 26,
}


# --------------------------------------------------------------------------
# Parsing the upstream tables
# --------------------------------------------------------------------------


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def parse_enum(header: str, first: str) -> list[str]:
    """The identifiers of the C enum whose first member is `first`."""
    body = header[header.index(first) :]
    body = body[: body.index("}")]
    names = []
    for raw in body.split(","):
        name = raw.strip()
        if not name:
            continue
        name = name.split("=")[0].strip()
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            names.append(name)
    return names


def parse_sprnames(source: str) -> list[str]:
    body = source[source.index("sprnames[NUMSPRITES]") :]
    body = body[body.index("{") + 1 : body.index("};")]
    return re.findall(r'"([A-Z0-9]{4})"', body)


def parse_states(source: str) -> list[dict]:
    """One dict per row of `states[]`: sprite, frame, tics, action, next."""
    body = source[source.index("states[NUMSTATES]") :]
    body = body[body.index("{") + 1 : body.index("\n};")]
    rows = []
    for m in re.finditer(
        r"\{\s*(SPR_[A-Z0-9]+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,"
        r"\s*\{\s*([A-Za-z0-9_]+)\s*\}\s*,\s*(S_[A-Z0-9_]+)\s*,",
        body,
    ):
        rows.append(
            dict(
                sprite=m.group(1),
                frame=int(m.group(2)),
                tics=int(m.group(3)),
                action=m.group(4),
                next=m.group(5),
            )
        )
    return rows


def eval_c_int(expr: str) -> int:
    """Evaluate the arithmetic that appears in `mobjinfo` fields."""
    expr = expr.strip()
    if expr.startswith("S_") or expr.startswith("sfx_") or expr.startswith("MT_"):
        raise ValueError(expr)
    expr = expr.replace("FRACUNIT", str(FRACUNIT))
    for name, value in MF_FLAGS.items():
        expr = re.sub(r"\b%s\b" % name, str(value), expr)
    if not re.fullmatch(r"[0-9\s()+*|<>\-]+", expr):
        raise ValueError(expr)
    return int(eval(expr, {"__builtins__": {}}, {}))  # noqa: S307 - fixed grammar


def parse_mobjinfo(source: str, types: list[str]) -> dict[str, dict]:
    """One dict per `mobjinfo[]` entry, keyed by its `MT_*` name."""
    body = source[source.index("mobjinfo[NUMMOBJTYPES]") :]
    body = body[body.index("{") + 1 :]
    entries: dict[str, dict] = {}
    depth = 0
    current: list[str] = []
    index = 0
    for ch in body:
        if ch == "{":
            depth += 1
            if depth == 1:
                current = []
                continue
        elif ch == "}":
            depth -= 1
            if depth == 0:
                fields = [f.strip() for f in "".join(current).split(",")]
                fields = [f for f in fields if f]
                if len(fields) != len(MOBJINFO_FIELDS):
                    raise SystemExit(
                        "mobjinfo entry %d has %d fields, expected %d"
                        % (index, len(fields), len(MOBJINFO_FIELDS))
                    )
                entries[types[index]] = dict(zip(MOBJINFO_FIELDS, fields))
                index += 1
                continue
        if depth >= 1:
            current.append(ch)
    if index != len(types):
        raise SystemExit("parsed %d mobjinfo entries, expected %d" % (index, len(types)))
    return entries


def parse_rndtable(source: str) -> list[int]:
    body = source[source.index("rndtable[256]") :]
    body = body[body.index("{") + 1 : body.index("};")]
    values = [int(v) for v in re.findall(r"\d+", body)]
    if len(values) != 256:
        raise SystemExit("rndtable has %d entries" % len(values))
    return values


def parse_weaponinfo(source: str) -> list[dict]:
    body = source[source.index("weaponinfo[NUMWEAPONS]") :]
    body = body[body.index("{") + 1 :]
    out = []
    depth = 0
    current: list[str] = []
    for ch in body:
        if ch == "{":
            depth += 1
            if depth == 1:
                current = []
                continue
        elif ch == "}":
            depth -= 1
            if depth == 0:
                fields = [f.strip() for f in "".join(current).split(",") if f.strip()]
                if len(fields) == 6:
                    out.append(
                        dict(
                            ammo=fields[0],
                            upstate=fields[1],
                            downstate=fields[2],
                            readystate=fields[3],
                            atkstate=fields[4],
                            flashstate=fields[5],
                        )
                    )
                current = []
                if len(out) == 9:
                    break
                continue
        if depth >= 1:
            current.append(ch)
    return out


# --------------------------------------------------------------------------
# Roster and closure
# --------------------------------------------------------------------------


def state_name(raw: str) -> str:
    """`mobjinfo` spells "no state" both as `S_NULL` and as a bare `0`."""
    return "S_NULL" if raw.strip() == "0" else raw.strip()


def roster(level: dict, mobjinfo: dict[str, dict], types: list[str]) -> list[str]:
    """The `MT_*` entries this level needs, in `mobjtype_t` order."""
    present = {t["type"] for t in level["things"]}
    by_num = {}
    for name in types:
        num = int(mobjinfo[name]["doomednum"])
        if num >= 0:
            by_num.setdefault(num, name)
    wanted = set(EXTRA_TYPES)
    missing = []
    for num in sorted(present):
        if num in (1, 2, 3, 4, 11):
            continue  # player and deathmatch starts have no mobjinfo entry
        if num in by_num:
            wanted.add(by_num[num])
        else:
            missing.append(num)
    if missing:
        raise SystemExit("doomednums with no mobjinfo entry: %s" % missing)
    return [t for t in types if t in wanted]


def state_closure(
    states: list[dict], state_index: dict[str, int], seeds: list[str]
) -> list[str]:
    """Every state reachable from `seeds` through `next_state`, S_NULL first."""
    seen = {"S_NULL"}
    stack = [s for s in seeds if s != "S_NULL"]
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        row = states[state_index[name]]
        if row["next"] not in seen:
            stack.append(row["next"])
    ordered = ["S_NULL"]
    ordered += [n for n in state_index if n in seen and n != "S_NULL"]
    return ordered


# --------------------------------------------------------------------------
# Emission
# --------------------------------------------------------------------------


def emit_array(name: str, ty: str, values: list[int], doc: str) -> str:
    return "/// %s\npub const %s: [%s; %d] = [%s];\n\n" % (
        doc,
        name,
        ty,
        len(values),
        ", ".join(str(v) for v in values),
    )


HEADER = "// SPDX-" """License-Identifier: GPL-2.0-only
//
//! GENERATED -- do not edit. Regenerate with
//! `python3 cairo/doom/doom_things/scripts/gen_things.py --src <linuxdoom-1.10> \\
//!     --level <e1m1.json> --write`.
//!
//! Data **derived from** id Software's linuxdoom-1.10 (`info.c`'s `states`
//! and `mobjinfo` tables, `m_random.c`'s `rndtable`, `d_items.c`'s
//! `weaponinfo`), GPL-2.0-only. No C code is reproduced here: the ids are
//! remapped to a compact range covering only what Freedoom E1M1 can spawn,
//! and the layout is this project's (planar `const` columns, S1 §5.3).
//!
//! * the five `STATE_*` columns are `fsm::StateTables`, in that order;
//! * `STATE_ACTION` holds this crate's own action ids (`super::action`), not
//!   C function pointers -- Cairo has none, so `fsm::advance` returns the id
//!   and `doom_monsters`/`doom_player` dispatch on it (D15);
//! * `MI_*` are the `mobjinfo` fields the simulation reads; sounds are
//!   dropped (the client plays those off the serialized state);
//! * `MI_RADIUS`/`MI_HEIGHT` are `fixed` offset-encoded (`enc = raw + 2^32`),
//!   `MI_SPEED` is the raw `info.c` value (map units for a walker, 16.16 for
//!   a projectile), `MI_FLAGS` is the raw `MF_*` word.
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", required=True, help="directory holding linuxdoom-1.10 sources")
    ap.add_argument("--level", required=True, help="tools/wad JSON, for the thing roster")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    src = Path(args.src)
    info_h = strip_comments((src / "info.h").read_text(errors="replace"))
    info_c = strip_comments((src / "info.c").read_text(errors="replace"))
    random_c = strip_comments((src / "m_random.c").read_text(errors="replace"))
    items_c = strip_comments((src / "d_items.c").read_text(errors="replace"))
    level = json.loads(Path(args.level).read_text())

    sprite_names_enum = parse_enum(info_h, "SPR_TROO")
    state_names = parse_enum(info_h, "S_NULL")
    type_names = parse_enum(info_h, "MT_PLAYER")
    sprite_names_enum = [s for s in sprite_names_enum if s != "NUMSPRITES"]
    state_names = [s for s in state_names if s != "NUMSTATES"]
    type_names = [s for s in type_names if s != "NUMMOBJTYPES"]

    sprnames = parse_sprnames(info_c)
    states = parse_states(info_c)
    if len(states) != len(state_names):
        raise SystemExit("parsed %d states, enum has %d" % (len(states), len(state_names)))
    if len(sprnames) != len(sprite_names_enum):
        raise SystemExit("sprite name / enum length mismatch")
    state_index = {name: i for i, name in enumerate(state_names)}
    mobjinfo = parse_mobjinfo(info_c, type_names)
    rndtable = parse_rndtable(random_c)
    weaponinfo = parse_weaponinfo(items_c)

    kinds = roster(level, mobjinfo, type_names)

    # Seeds: every state field of every kept mobj, plus the weapon chains.
    seeds: list[str] = []
    for kind in kinds:
        for f in STATE_FIELDS:
            seeds.append(state_name(mobjinfo[kind][f]))
    weapon_rows = []
    for name, idx in WEAPONS:
        w = weaponinfo[idx]
        weapon_rows.append((name, w))
        seeds += [w["upstate"], w["downstate"], w["readystate"], w["atkstate"], w["flashstate"]]
    seeds.append("S_LIGHTDONE")  # every flash chains back through it

    kept_states = state_closure(states, state_index, seeds)
    new_state_id = {name: i for i, name in enumerate(kept_states)}

    # Action ids: 0 is fsm::NO_ACTION, then the distinct actions used, sorted.
    used_actions = sorted(
        {states[state_index[n]]["action"] for n in kept_states} - {"NULL"}
    )
    action_id = {"NULL": 0}
    for i, name in enumerate(used_actions, start=1):
        action_id[name] = i

    # Sprites: renumber to the sprites actually used.
    used_sprites = []
    for n in kept_states:
        s = states[state_index[n]]["sprite"]
        if s not in used_sprites:
            used_sprites.append(s)
    sprite_id = {name: i for i, name in enumerate(used_sprites)}

    col_sprite, col_frame, col_tics, col_action, col_next = [], [], [], [], []
    for n in kept_states:
        row = states[state_index[n]]
        col_sprite.append(sprite_id[row["sprite"]])
        col_frame.append(row["frame"])
        # Doom's `tics == -1` is "stay for ever"; `fsm` spells that FOREVER.
        col_tics.append(0xFFFFFFFF if row["tics"] < 0 else row["tics"])
        col_action.append(action_id[row["action"]])
        col_next.append(new_state_id[row["next"]])

    columns: dict[str, list[int]] = {f: [] for f in KEPT_FIELDS}
    for kind in kinds:
        e = mobjinfo[kind]
        for f in KEPT_FIELDS:
            raw = e[f]
            if f in STATE_FIELDS:
                columns[f].append(new_state_id[state_name(raw)])
            elif f in ("radius", "height"):
                columns[f].append(eval_c_int(raw) + BIAS)
            elif f == "doomednum":
                columns[f].append(eval_c_int(raw) if not raw.startswith("-") else 0xFFFF)
            else:
                columns[f].append(eval_c_int(raw))

    # doomednum -> kind index, sorted for a binary search.
    lookup = sorted(
        (columns["doomednum"][i], i)
        for i in range(len(kinds))
        if columns["doomednum"][i] != 0xFFFF
    )

    out = [HEADER, "\n"]
    out.append(
        "// Action ids. `fsm::advance` returns one of these for the state it\n"
        "// enters and the caller dispatches on it, because Cairo has no\n"
        "// function pointers (D15). `generated/actions.md` is the same table\n"
        "// in prose, for `doom_monsters` and `doom_player`.\n"
    )
    for name in used_actions:
        out.append(
            "/// `%s` of linuxdoom's `p_enemy.c` / `p_pspr.c`.\n"
            "pub const %s: u32 = %d;\n\n" % (name, name.upper(), action_id[name])
        )
    out.append(
        "// Indices into the `MI_*` columns, one per `mobjinfo` entry kept.\n"
    )
    for i, kind in enumerate(kinds):
        out.append(
            "/// linuxdoom's `%s` (doomednum %s).\n"
            "pub const KIND_%s: u32 = %d;\n\n"
            % (
                kind,
                "none" if columns["doomednum"][i] == 0xFFFF else columns["doomednum"][i],
                kind[3:],
                i,
            )
        )
    out.append("/// Number of states in the tables below.\n")
    out.append("pub const NUM_STATES: u32 = %d;\n\n" % len(kept_states))
    out.append("/// Number of `mobjinfo` entries.\n")
    out.append("pub const NUM_KINDS: u32 = %d;\n\n" % len(kinds))
    out.append("/// Number of distinct action ids (0 is `fsm::NO_ACTION`).\n")
    out.append("pub const NUM_ACTIONS: u32 = %d;\n\n" % (len(used_actions) + 1))
    out.append(emit_array("STATE_SPRITE", "u32", col_sprite, "`fsm::StateTables::sprite`."))
    out.append(
        emit_array(
            "STATE_FRAME",
            "u32",
            col_frame,
            "`fsm::StateTables::frame`; bit 15 (32768) is Doom's full-bright flag.",
        )
    )
    out.append(
        emit_array(
            "STATE_TICS", "u32", col_tics, "`fsm::StateTables::tics`; `fsm::FOREVER` is `-1`."
        )
    )
    out.append(
        emit_array("STATE_ACTION", "u32", col_action, "`fsm::StateTables::action_id`.")
    )
    out.append(emit_array("STATE_NEXT", "u32", col_next, "`fsm::StateTables::next_state`."))
    docs = {
        "doomednum": "THINGS type id, `0xFFFF` when the entry cannot be placed on a map.",
        "spawnstate": "State a freshly spawned mobj enters.",
        "spawnhealth": "Starting health.",
        "seestate": "State entered when `A_Look` finds a target.",
        "reactiontime": "Tics a monster waits before its first attack.",
        "painstate": "State entered when the pain roll succeeds.",
        "painchance": "`P_Random () < painchance` triggers `painstate`.",
        "meleestate": "Close-range attack chain, `0` when there is none.",
        "missilestate": "Ranged attack chain, `0` when there is none.",
        "deathstate": "Normal death chain.",
        "xdeathstate": "Gib death chain, `0` when there is none.",
        "raisestate": "Resurrection chain (archvile); `0` on this roster.",
        "speed": "Map units per move for a walker, 16.16 for a projectile.",
        "radius": "Collision radius, `fixed` offset encoding.",
        "height": "Collision height, `fixed` offset encoding.",
        "mass": "Used by `P_DamageMobj`'s thrust.",
        "damage": "Projectile damage multiplier.",
        "flags": "Raw `MF_*` word.",
    }
    for f in KEPT_FIELDS:
        ty = "felt252" if f in ("radius", "height") else "u32"
        out.append(
            emit_array("MI_%s" % f.upper(), ty, columns[f], "`mobjinfo.%s`: %s" % (f, docs[f]))
        )
    out.append(
        emit_array(
            "DOOMEDNUM_KEYS",
            "u32",
            [k for k, _ in lookup],
            "Sorted `doomednum`s, the search key of `kind_of_doomednum`.",
        )
    )
    out.append(
        emit_array(
            "DOOMEDNUM_KINDS",
            "u32",
            [v for _, v in lookup],
            "The kind index each `DOOMEDNUM_KEYS` entry maps to.",
        )
    )
    out.append(
        emit_array(
            "RNDTABLE",
            "u8",
            rndtable,
            "Doom's `rndtable` (`m_random.c`), the 256 bytes `prng` indexes.",
        )
    )
    for name, w in weapon_rows:
        out.append(
            "/// `weaponinfo[%s]`: up, down, ready, attack, flash.\n"
            "pub const WEAPON_%s: [u32; 5] = [%d, %d, %d, %d, %d];\n\n"
            % (
                name,
                name.upper(),
                new_state_id[w["upstate"]],
                new_state_id[w["downstate"]],
                new_state_id[w["readystate"]],
                new_state_id[w["atkstate"]],
                new_state_id[w["flashstate"]],
            )
        )

    arrays = [
        dict(name="STATE_* (5)", group="states", layout="planar", words=5 * len(kept_states)),
        dict(
            name="MI_* (%d)" % len(KEPT_FIELDS),
            group="mobjinfo",
            layout="planar",
            words=len(KEPT_FIELDS) * len(kinds),
        ),
        dict(name="RNDTABLE", group="prng", layout="planar", words=256),
        dict(name="DOOMEDNUM_* (2)", group="lookup", layout="planar", words=2 * len(lookup)),
        dict(
            name="WEAPON_* (%d)" % len(weapon_rows),
            group="weapons",
            layout="planar",
            words=5 * len(weapon_rows),
        ),
        dict(name="(scalars)", group="scalar", layout="-", words=3),
    ]
    words = sum(a["words"] for a in arrays)
    print("states kept: %d of %d" % (len(kept_states), len(states)))
    print("mobj kinds:  %d of %d" % (len(kinds), len(type_names)))
    print("actions:     %d (plus NO_ACTION)" % len(used_actions))
    print("sprites:     %d" % len(used_sprites))
    print("\n%-22s %8s" % ("array", "words"))
    for a in arrays:
        print("%-22s %8d" % (a["name"], a["words"]))
    print("%-22s %8d" % ("TOTAL", words))

    actions_doc = "\n".join(
        "//! | %d | `%s` |" % (action_id[a], a) for a in used_actions
    )
    sprites_json = dict(
        note=(
            "Generated by cairo/doom/doom_things/scripts/gen_things.py. "
            "`sprites` is indexed by the sprite id in STATE_SPRITE; "
            "`byDoomednum` gives each map thing's spawn sprite and frame."
        ),
        sprites=[sprnames[sprite_names_enum.index(s)] for s in used_sprites],
        byDoomednum={
            str(columns["doomednum"][i]): dict(
                type=kinds[i],
                sprite=sprnames[
                    sprite_names_enum.index(used_sprites[col_sprite[columns["spawnstate"][i]]])
                ],
                frame=col_frame[columns["spawnstate"][i]] % 32768,
                fullbright=col_frame[columns["spawnstate"][i]] >= 32768,
            )
            for i in range(len(kinds))
            if columns["doomednum"][i] != 0xFFFF
        },
        states=[
            dict(
                sprite=sprnames[sprite_names_enum.index(used_sprites[col_sprite[i]])],
                frame=col_frame[i] % 32768,
                fullbright=col_frame[i] >= 32768,
                tics=None if col_tics[i] == 0xFFFFFFFF else col_tics[i],
            )
            for i in range(len(kept_states))
        ],
    )

    if not args.write:
        return 0

    (CRATE / "src").mkdir(parents=True, exist_ok=True)
    (CRATE / "generated").mkdir(parents=True, exist_ok=True)
    (CRATE / "src" / "tables.cairo").write_text("".join(out))
    (CRATE / "generated" / "sprites.json").write_text(
        json.dumps(sprites_json, indent=2) + "\n"
    )
    (CRATE / "generated" / "actions.md").write_text(
        "<!-- SPDX-" "License-Identifier: GPL-2.0-only -->\n"
        "# Action ids\n\n"
        "Generated by `scripts/gen_things.py`. `fsm::advance` returns one of\n"
        "these for the state it enters; `doom_monsters` and `doom_player`\n"
        "dispatch on it. `0` is `fsm::NO_ACTION`.\n\n"
        "| id | linuxdoom function |\n|---:|---|\n"
        + "\n".join("| %d | `%s` |" % (action_id[a], a) for a in used_actions)
        + "\n"
    )
    manifest = dict(
        states=len(kept_states),
        kinds=len(kinds),
        actions=len(used_actions) + 1,
        sprites=len(used_sprites),
        total_words=words,
        arrays=arrays,
        array_count=5 + len(KEPT_FIELDS) + 1 + 2 + len(weapon_rows),
        kind_names=kinds,
        action_names=["NO_ACTION"] + used_actions,
    )
    (CRATE / "bench").mkdir(parents=True, exist_ok=True)
    (CRATE / "bench" / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("\nwrote src/tables.cairo, generated/sprites.json, generated/actions.md")

    fmt = subprocess.run(
        ["scarb", "fmt", "-p", "doom_things"],
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

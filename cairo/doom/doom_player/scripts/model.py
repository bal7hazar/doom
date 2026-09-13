#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""An independent Python model of linuxdoom-1.10's player rules.

This is the *reference* half of `doom_player`'s test suite (PLAN.md §3.1
rule 4): a transcription of `p_user.c`, `p_pspr.c` and the player's half of
`p_inter.c` that shares no code with the Cairo implementation, over the same
`doom_things` tables read straight out of the generated Cairo constants. What
it computes becomes `src/tests/vectors.cairo`.

Three things are modelled the *vanilla* way on purpose, so the Cairo side is
checked rather than mirrored:

* `P_XYMovement` is transcribed from C, halving branch included, and the
  generator **refuses to write** if any scripted tic would take that branch
  or would touch a wall — `doom_physics` transcribes the halves as
  `floor`/`ceil` of the same split rather than C's `trunc`/`>>`, and the two
  only agree below `MAXMOVE/2`. The scripted walk stays there (Doom's own
  walk speed, `forwardmove[0] = 25`, tops out near 7.6 units a tic);
* `P_CalcHeight` keeps the dead first assignment of the off-ground branch,
  so that its *observable* result (no ceiling clamp when airborne) is what
  the Cairo side is compared against;
* the whole psprite chain runs Doom's `do … while (!psp->tics)` loop, with no
  bound: if the tables ever grew a longer zero-tic chain than the Cairo
  side's guard allows, the vectors would diverge.

The walk vectors are **relative** — `x - x0`, `y - y0`, `viewz - mo.z` — so
that the model needs no BSP descent and no sector heights: the Cairo test
spawns the player on the real E1M1 and checks the deltas, asserting on every
tic that the move was accepted, that the player is on the ground, and that
the ceiling is far enough above the eye for the clamp not to fire.

Usage:

    python3 scripts/model.py             # run the model, print a summary
    python3 scripts/model.py --write     # rewrite src/tests/vectors.cairo
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
TABLES = CAIRO / "doom" / "doom_things" / "src" / "tables.cairo"
BAM_TABLES = CAIRO / "crates" / "bam" / "src" / "tables.cairo"
OUT = CRATE / "src" / "tests" / "vectors.cairo"

FRACUNIT = 65536
BIAS = 1 << 32
FOREVER = 0xFFFFFFFF
ANGMASK = 0xFFFFFFFF
ANG90 = 0x40000000
ANG180 = 0x80000000
ANG5 = ANG90 // 18
FINEANGLES = 8192
ANGLETOFINESHIFT = 19

VIEWHEIGHT = 41 * FRACUNIT
MAXBOB = 0x100000
MAXMOVE = 30 * FRACUNIT
STOPSPEED = 0x1000
FRICTION = 0xE800
WEAPONBOTTOM = 128 * FRACUNIT
WEAPONTOP = 32 * FRACUNIT
RAISESPEED = 6 * FRACUNIT
LOWERSPEED = 6 * FRACUNIT
BONUSADD = 6
MAXHEALTH = 100

BT_ATTACK, BT_USE, BT_CHANGE = 1, 2, 4
BT_WEAPONMASK, BT_WEAPONSHIFT = 8 + 16 + 32, 3

WP_FIST, WP_PISTOL, WP_SHOTGUN, WP_CHAINGUN, WP_CHAINSAW, WP_NOCHANGE = 0, 1, 2, 3, 4, 5
AM_CLIP, AM_SHELL, AM_CELL, AM_MISL, AM_NOAMMO = 0, 1, 2, 3, 4
MAXAMMO = [200, 50, 300, 50]
CLIPAMMO = [10, 4, 20, 1]
WEAPON_AMMO = [AM_NOAMMO, AM_CLIP, AM_SHELL, AM_CLIP, AM_NOAMMO]
WEAPON_OF_BUTTON = [WP_FIST, WP_PISTOL, WP_SHOTGUN, WP_CHAINGUN,
                    WP_NOCHANGE, WP_NOCHANGE, WP_NOCHANGE, WP_CHAINSAW]

PST_LIVE, PST_DEAD = 0, 1
PS_WEAPON, PS_FLASH = 0, 1
CARD_BLUE = 1

S_PLAY = 58
S_PLAY_RUN1 = 59
S_PLAY_ATK = 63

MF_SPECIAL = 1
MF_DROPPED = 1 << 17
MF_COUNTITEM = 1 << 23

# doom_things kind ids of everything E1M1 can hand a player.
(KIND_CLIP, KIND_CHAINGUN, KIND_SHOTGUN) = (19, 28, 32)
(K_ARM1, K_ARM2, K_BON1, K_BON2, K_BKEY, K_STIM, K_MEDI, K_SOUL, K_PSTR) = (
    10, 11, 12, 13, 14, 15, 16, 17, 18)
(K_AMMO, K_ROCK, K_BROK, K_CELL, K_CELP, K_SHEL, K_SBOX, K_BPAK, K_CSAW) = (
    20, 21, 22, 23, 24, 25, 26, 27, 29)


def fixed_mul(a: int, b: int) -> int:
    """Doom's `FixedMul`: the exact product, arithmetically shifted down."""
    return (a * b) >> 16


def enc(raw: int) -> int:
    return raw + BIAS


# --------------------------------------------------------------------------
# The generated tables, read from Cairo (data, never rules)
# --------------------------------------------------------------------------


def read_array(text: str, name: str) -> list[int]:
    m = re.search(r"pub const %s: \[[a-z0-9]+; \d+\] = \[(.*?)\];" % name, text, re.S)
    if m is None:
        raise SystemExit("array %s not found" % name)
    return [int(x) for x in m.group(1).replace("\n", "").split(",") if x.strip()]


class Tables:
    def __init__(self) -> None:
        t = TABLES.read_text()
        self.tics = read_array(t, "STATE_TICS")
        self.action = read_array(t, "STATE_ACTION")
        self.next = read_array(t, "STATE_NEXT")
        self.rnd = read_array(t, "RNDTABLE")
        self.weapon = {
            WP_FIST: read_array(t, "WEAPON_FIST"),
            WP_PISTOL: read_array(t, "WEAPON_PISTOL"),
            WP_SHOTGUN: read_array(t, "WEAPON_SHOTGUN"),
            WP_CHAINGUN: read_array(t, "WEAPON_CHAINGUN"),
            WP_CHAINSAW: read_array(t, "WEAPON_CHAINSAW"),
        }
        for name in ("A_WEAPONREADY", "A_LOWER", "A_RAISE", "A_REFIRE", "A_PUNCH",
                     "A_SAW", "A_FIREPISTOL", "A_FIRESHOTGUN", "A_FIRECGUN",
                     "A_LIGHT0", "A_LIGHT1", "A_LIGHT2"):
            m = re.search(r"pub const %s: u32 = (\d+);" % name, t)
            setattr(self, name, int(m.group(1)))
        q = read_array(BAM_TABLES.read_text(), "FINESINE_Q")
        self.finesine = [0] * FINEANGLES
        for i in range(FINEANGLES):
            negative, half = (True, i - 4096) if i >= 4096 else (False, i)
            k = 4095 - half if half >= 2048 else half
            self.finesine[i] = -q[k] if negative else q[k]

    def up(self, w): return self.weapon[w][0]
    def down(self, w): return self.weapon[w][1]
    def ready(self, w): return self.weapon[w][2]
    def attack(self, w): return self.weapon[w][3]
    def flash(self, w): return self.weapon[w][4]

    def finecosine(self, idx: int) -> int:
        return self.finesine[(idx + 2048) % FINEANGLES]


T = Tables()


class Rng:
    """`prng::Prng` over Doom's `rndtable`: read, then advance."""

    def __init__(self, index: int = 1) -> None:
        self.index = index

    def next(self) -> int:
        v = T.rnd[self.index]
        self.index = 0 if self.index == 255 else self.index + 1
        return v

    def below(self, n: int) -> int:
        v = self.next()
        return 0 if n == 0 else v % n

    def sub(self) -> int:
        return self.next() - self.next()


# --------------------------------------------------------------------------
# The two records
# --------------------------------------------------------------------------


class Mobj:
    def __init__(self, x=0, y=0, z=0, angle=0):
        self.x, self.y, self.z, self.angle = x, y, z, angle
        self.momx = self.momy = self.momz = 0
        self.floorz, self.ceilingz = 0, 1 << 30
        self.state, self.tics = S_PLAY, FOREVER
        self.health = 100
        self.flags = 0
        self.reaction_time = 0


class Player:
    def __init__(self, mo: Mobj):
        self.mo = mo
        self.playerstate = PST_LIVE
        self.health = 100
        self.armor_points = 0
        self.armor_type = 0
        self.ammo = [50, 0, 0, 0]
        self.backpack = False
        self.weapons = (1 << WP_FIST) | (1 << WP_PISTOL)
        self.ready_weapon = WP_PISTOL
        self.pending_weapon = WP_NOCHANGE
        self.cards = 0
        self.strength = 0
        self.viewz = VIEWHEIGHT
        self.viewheight = VIEWHEIGHT
        self.deltaviewheight = 0
        self.bob = 0
        self.psp = [[0, 0], [0, 0]]          # [state, tics] per slot
        self.psp_sx, self.psp_sy = FRACUNIT, WEAPONBOTTOM
        self.extralight = 0
        self.damagecount = self.bonuscount = 0
        self.attacker = 0xFFFF
        self.attackdown = self.usedown = False
        self.refire = 0
        self.cheats = 0
        self.killcount = self.itemcount = self.secretcount = 0

    def max_ammo(self, a: int) -> int:
        return MAXAMMO[a] * (2 if self.backpack else 1)

    def owns(self, w: int) -> bool:
        return (self.weapons >> w) & 1 == 1


# --------------------------------------------------------------------------
# p_pspr.c
# --------------------------------------------------------------------------


class Shots:
    """The RNG draws a fired weapon makes, which is all a geometry-free
    model can predict of `P_LineAttack` (the hit itself is
    `doom_physics::line_attack`'s, and the Cairo test compares it there)."""

    def __init__(self) -> None:
        self.damages: list[int] = []


def set_psprite(p: Player, rng: Rng, shots: Shots, buttons: int, slot: int, stnum: int) -> None:
    while True:
        if stnum == 0:
            p.psp[slot] = [0, 0]
            break
        p.psp[slot] = [stnum, T.tics[stnum]]
        action = T.action[stnum]
        if action:
            run_action(p, rng, shots, buttons, action)
            if p.psp[slot][0] == 0:
                break
        if p.psp[slot][1] != 0:
            break
        stnum = T.next[p.psp[slot][0]]


def move_psprites(p: Player, rng: Rng, shots: Shots, buttons: int) -> None:
    for slot in (PS_WEAPON, PS_FLASH):
        st = p.psp[slot][0]
        if st == 0:
            continue
        if p.psp[slot][1] == FOREVER:
            continue
        p.psp[slot][1] -= 1
        if p.psp[slot][1] == 0:
            set_psprite(p, rng, shots, buttons, slot, T.next[st])


def bring_up_weapon(p: Player, rng: Rng, shots: Shots, buttons: int) -> None:
    if p.pending_weapon == WP_NOCHANGE:
        p.pending_weapon = p.ready_weapon
    newstate = T.up(p.pending_weapon)
    p.pending_weapon = WP_NOCHANGE
    p.psp_sy = WEAPONBOTTOM
    set_psprite(p, rng, shots, buttons, PS_WEAPON, newstate)


def check_ammo(p: Player, rng: Rng, shots: Shots, buttons: int) -> bool:
    ammo = WEAPON_AMMO[p.ready_weapon]
    if ammo == AM_NOAMMO or p.ammo[ammo] >= 1:
        return True
    if p.owns(WP_CHAINGUN) and p.ammo[AM_CLIP]:
        p.pending_weapon = WP_CHAINGUN
    elif p.owns(WP_SHOTGUN) and p.ammo[AM_SHELL]:
        p.pending_weapon = WP_SHOTGUN
    elif p.ammo[AM_CLIP]:
        p.pending_weapon = WP_PISTOL
    elif p.owns(WP_CHAINSAW):
        p.pending_weapon = WP_CHAINSAW
    else:
        p.pending_weapon = WP_FIST
    set_psprite(p, rng, shots, buttons, PS_WEAPON, T.down(p.ready_weapon))
    return False


def fire_weapon(p: Player, rng: Rng, shots: Shots, buttons: int) -> None:
    if not check_ammo(p, rng, shots, buttons):
        return
    set_mobj_state(p.mo, S_PLAY_ATK)
    set_psprite(p, rng, shots, buttons, PS_WEAPON, T.attack(p.ready_weapon))


def set_mobj_state(mo: Mobj, state: int) -> None:
    mo.state, mo.tics = state, T.tics[state]


def gun_shots(p: Player, rng: Rng, shots: Shots, count: int, accurate: bool) -> None:
    for _ in range(count):
        damage = 5 * (rng.below(3) + 1)
        if not accurate:
            rng.sub()
        shots.damages.append(damage)


def run_action(p: Player, rng: Rng, shots: Shots, buttons: int, action: int) -> None:
    if action == T.A_WEAPONREADY:
        if p.mo.state == S_PLAY_ATK:
            set_mobj_state(p.mo, S_PLAY)
        if p.pending_weapon != WP_NOCHANGE or p.health == 0:
            set_psprite(p, rng, shots, buttons, PS_WEAPON, T.down(p.ready_weapon))
            return
        if buttons & BT_ATTACK:
            p.attackdown = True
            fire_weapon(p, rng, shots, buttons)
            return
        p.attackdown = False
        idx = (128 * p.leveltime) % FINEANGLES
        p.psp_sx = FRACUNIT + fixed_mul(p.bob, T.finecosine(idx))
        p.psp_sy = WEAPONTOP + fixed_mul(p.bob, T.finesine[idx % 4096])
    elif action == T.A_LOWER:
        p.psp_sy += LOWERSPEED
        if p.psp_sy < WEAPONBOTTOM:
            return
        if p.playerstate == PST_DEAD:
            p.psp_sy = WEAPONBOTTOM
            return
        if p.health == 0:
            set_psprite(p, rng, shots, buttons, PS_WEAPON, 0)
            return
        p.ready_weapon = p.pending_weapon
        bring_up_weapon(p, rng, shots, buttons)
    elif action == T.A_RAISE:
        p.psp_sy -= RAISESPEED
        if p.psp_sy > WEAPONTOP:
            return
        p.psp_sy = WEAPONTOP
        set_psprite(p, rng, shots, buttons, PS_WEAPON, T.ready(p.ready_weapon))
    elif action == T.A_REFIRE:
        if (buttons & BT_ATTACK) and p.pending_weapon == WP_NOCHANGE and p.health:
            p.refire += 1
            fire_weapon(p, rng, shots, buttons)
        else:
            p.refire = 0
            check_ammo(p, rng, shots, buttons)
    elif action in (T.A_FIREPISTOL, T.A_FIRESHOTGUN, T.A_FIRECGUN):
        count = 7 if action == T.A_FIRESHOTGUN else 1
        ammo = WEAPON_AMMO[p.ready_weapon]
        if action == T.A_FIRECGUN and p.ammo[ammo] == 0:
            return
        set_mobj_state(p.mo, S_PLAY_ATK)
        p.ammo[ammo] -= 1
        set_psprite(p, rng, shots, buttons, PS_FLASH, T.flash(p.ready_weapon))
        gun_shots(p, rng, shots, count, count == 1 and p.refire == 0)
    elif action in (T.A_PUNCH, T.A_SAW):
        saw = action == T.A_SAW
        damage = 2 * (rng.below(10) + 1)
        if not saw and p.strength:
            damage *= 10
        rng.sub()
        shots.damages.append(damage)
    elif action == T.A_LIGHT0:
        p.extralight = 0
    elif action == T.A_LIGHT1:
        p.extralight = 1
    elif action == T.A_LIGHT2:
        p.extralight = 2


# --------------------------------------------------------------------------
# p_user.c
# --------------------------------------------------------------------------


def thrust(mo: Mobj, angle: int, move: int) -> None:
    idx = (angle & ANGMASK) >> ANGLETOFINESHIFT
    mo.momx += fixed_mul(move, T.finecosine(idx))
    mo.momy += fixed_mul(move, T.finesine[idx])


def move_player(p: Player, forward: int, side: int, turn: int) -> None:
    mo = p.mo
    mo.angle = (mo.angle + (turn << 16)) & ANGMASK
    onground = mo.z <= mo.floorz
    if forward and onground:
        thrust(mo, mo.angle, forward * 2048)
    if side and onground:
        thrust(mo, (mo.angle - ANG90) & ANGMASK, side * 2048)
    if (forward or side) and mo.state == S_PLAY:
        set_mobj_state(mo, S_PLAY_RUN1)


def calc_height(p: Player) -> None:
    mo = p.mo
    p.bob = fixed_mul(mo.momx, mo.momx) + fixed_mul(mo.momy, mo.momy)
    p.bob >>= 2
    if p.bob > MAXBOB:
        p.bob = MAXBOB
    onground = mo.z <= mo.floorz
    if p.cheats or not onground:
        # Vanilla assigns `viewz` twice here and keeps the second, unclamped.
        p.viewz = mo.z + p.viewheight
        return
    angle = (FINEANGLES // 20 * p.leveltime) & (FINEANGLES - 1)
    bob = fixed_mul(p.bob // 2, T.finesine[angle])
    if p.playerstate == PST_LIVE:
        p.viewheight += p.deltaviewheight
        if p.viewheight > VIEWHEIGHT:
            p.viewheight = VIEWHEIGHT
            p.deltaviewheight = 0
        if p.viewheight < VIEWHEIGHT // 2:
            p.viewheight = VIEWHEIGHT // 2
            if p.deltaviewheight <= 0:
                p.deltaviewheight = 1
        if p.deltaviewheight:
            p.deltaviewheight += FRACUNIT // 4
            if p.deltaviewheight == 0:
                p.deltaviewheight = 1
    p.viewz = mo.z + p.viewheight + bob
    if p.viewz > mo.ceilingz - 4 * FRACUNIT:
        p.viewz = mo.ceilingz - 4 * FRACUNIT


def change_weapon(p: Player, buttons: int) -> None:
    new = WEAPON_OF_BUTTON[(buttons & BT_WEAPONMASK) >> BT_WEAPONSHIFT]
    if new == WP_FIST and p.owns(WP_CHAINSAW) and not (
            p.ready_weapon == WP_CHAINSAW and p.strength):
        new = WP_CHAINSAW
    if new != WP_NOCHANGE and p.owns(new) and new != p.ready_weapon:
        p.pending_weapon = new


def death_think(p: Player, rng: Rng, shots: Shots, buttons: int) -> None:
    move_psprites(p, rng, shots, buttons)
    if p.viewheight > 6 * FRACUNIT:
        p.viewheight -= FRACUNIT
    if p.viewheight < 6 * FRACUNIT:
        p.viewheight = 6 * FRACUNIT
    p.deltaviewheight = 0
    calc_height(p)
    if p.damagecount:
        p.damagecount -= 1


def player_think(p: Player, forward: int, side: int, turn: int, buttons: int,
                 leveltime: int, rng: Rng, shots: Shots,
                 sector_damage: int = 0, sector_secret: bool = False) -> None:
    p.leveltime = leveltime
    if p.playerstate == PST_DEAD:
        death_think(p, rng, shots, buttons)
        return
    if p.mo.reaction_time:
        p.mo.reaction_time -= 1
    else:
        move_player(p, forward, side, turn)
    calc_height(p)
    if sector_secret:
        p.secretcount += 1
    if sector_damage:
        damage_player(p, sector_damage)
    if buttons & BT_CHANGE:
        change_weapon(p, buttons)
    if buttons & BT_USE:
        p.usedown = True
    else:
        p.usedown = False
    move_psprites(p, rng, shots, buttons)
    if p.strength:
        p.strength += 1
    if p.damagecount:
        p.damagecount -= 1
    if p.bonuscount:
        p.bonuscount -= 1


# --------------------------------------------------------------------------
# p_mobj.c: the no-collision half of P_XYMovement
# --------------------------------------------------------------------------


def clamp(v: int) -> int:
    return max(-MAXMOVE, min(MAXMOVE, v))


def c_div2(v: int) -> int:
    """C's `v/2` on an int: truncation toward zero."""
    return -((-v) // 2) if v < 0 else v // 2


def xy_movement(mo: Mobj, player_input: bool) -> None:
    """`P_XYMovement` where every `P_TryMove` succeeds. Raises when the
    halving branch is reached: `doom_physics` splits the move differently
    there and the vectors would stop being a reference (see the module
    docstring)."""
    if mo.momx == 0 and mo.momy == 0:
        return
    mo.momx, mo.momy = clamp(mo.momx), clamp(mo.momy)
    xmove, ymove = mo.momx, mo.momy
    if xmove > MAXMOVE // 2 or ymove > MAXMOVE // 2:
        raise ValueError("scripted move reached P_XYMovement's halving branch")
    mo.x += xmove
    mo.y += ymove
    if mo.z > mo.floorz:
        return
    if (abs(mo.momx) < STOPSPEED and abs(mo.momy) < STOPSPEED and not player_input):
        if S_PLAY_RUN1 <= mo.state < S_PLAY_RUN1 + 4:
            set_mobj_state(mo, S_PLAY)
        mo.momx = mo.momy = 0
    else:
        mo.momx = fixed_mul(mo.momx, FRICTION)
        mo.momy = fixed_mul(mo.momy, FRICTION)


# --------------------------------------------------------------------------
# p_inter.c
# --------------------------------------------------------------------------


def give_ammo(p: Player, ammo: int, num: int) -> bool:
    if ammo == AM_NOAMMO:
        return False
    if p.ammo[ammo] == p.max_ammo(ammo):
        return False
    amount = num * CLIPAMMO[ammo] if num else CLIPAMMO[ammo] // 2
    old = p.ammo[ammo]
    p.ammo[ammo] = min(old + amount, p.max_ammo(ammo))
    if old:
        return True
    if ammo == AM_CLIP and p.ready_weapon == WP_FIST:
        p.pending_weapon = WP_CHAINGUN if p.owns(WP_CHAINGUN) else WP_PISTOL
    elif ammo == AM_SHELL and p.ready_weapon in (WP_FIST, WP_PISTOL) and p.owns(WP_SHOTGUN):
        p.pending_weapon = WP_SHOTGUN
    return True


def give_weapon(p: Player, weapon: int, dropped: bool) -> bool:
    ammo = WEAPON_AMMO[weapon]
    gave_ammo = give_ammo(p, ammo, 1 if dropped else 2) if ammo != AM_NOAMMO else False
    if p.owns(weapon):
        return gave_ammo
    p.weapons |= 1 << weapon
    p.pending_weapon = weapon
    return True


def give_body(p: Player, num: int) -> bool:
    if p.health >= MAXHEALTH:
        return False
    p.health = min(p.health + num, MAXHEALTH)
    p.mo.health = p.health
    return True


def give_armor(p: Player, armortype: int) -> bool:
    hits = armortype * 100
    if p.armor_points >= hits:
        return False
    p.armor_type = armortype
    p.armor_points = hits
    return True


def touch_special(p: Player, kind: int, flags: int) -> bool:
    if p.mo.health <= 0:
        return False
    took = True
    if kind == K_ARM1:
        took = give_armor(p, 1)
    elif kind == K_ARM2:
        took = give_armor(p, 2)
    elif kind == K_BON1:
        p.health = min(p.health + 1, 200)
        p.mo.health = p.health
    elif kind == K_BON2:
        p.armor_points = min(p.armor_points + 1, 200)
        if not p.armor_type:
            p.armor_type = 1
    elif kind == K_BKEY:
        if not (p.cards & CARD_BLUE):
            p.bonuscount = BONUSADD
            p.cards |= CARD_BLUE
    elif kind == K_STIM:
        took = give_body(p, 10)
    elif kind == K_MEDI:
        took = give_body(p, 25)
    elif kind == K_SOUL:
        p.health = min(p.health + 100, 200)
        p.mo.health = p.health
    elif kind == K_PSTR:
        give_body(p, 100)
        p.strength = 1
        if p.ready_weapon != WP_FIST:
            p.pending_weapon = WP_FIST
    elif kind == KIND_CLIP:
        took = give_ammo(p, AM_CLIP, 0 if flags & MF_DROPPED else 1)
    elif kind == K_AMMO:
        took = give_ammo(p, AM_CLIP, 5)
    elif kind == K_SHEL:
        took = give_ammo(p, AM_SHELL, 1)
    elif kind == K_SBOX:
        took = give_ammo(p, AM_SHELL, 5)
    elif kind == K_ROCK:
        took = give_ammo(p, AM_MISL, 1)
    elif kind == K_BROK:
        took = give_ammo(p, AM_MISL, 5)
    elif kind == K_CELL:
        took = give_ammo(p, AM_CELL, 1)
    elif kind == K_CELP:
        took = give_ammo(p, AM_CELL, 5)
    elif kind == K_BPAK:
        p.backpack = True
        for a in range(4):
            give_ammo(p, a, 1)
    elif kind == KIND_SHOTGUN:
        took = give_weapon(p, WP_SHOTGUN, bool(flags & MF_DROPPED))
    elif kind == KIND_CHAINGUN:
        took = give_weapon(p, WP_CHAINGUN, bool(flags & MF_DROPPED))
    elif kind == K_CSAW:
        took = give_weapon(p, WP_CHAINSAW, False)
    else:
        return False
    if not took:
        return False
    if flags & MF_COUNTITEM:
        p.itemcount += 1
    p.bonuscount += BONUSADD
    return True


def absorb(p: Player, damage: int) -> int:
    if not p.armor_type:
        return damage
    saved = damage // 3 if p.armor_type == 1 else damage // 2
    if p.armor_points <= saved:
        saved = p.armor_points
        p.armor_type = 0
    p.armor_points -= saved
    return damage - saved


def damage_player(p: Player, damage: int) -> int:
    net = absorb(p, damage)
    p.health = max(0, p.health - net)
    p.damagecount = min(p.damagecount + net, 100)
    p.mo.health -= net
    if p.mo.health <= 0:
        p.playerstate = PST_DEAD
    return net


# --------------------------------------------------------------------------
# Vector generation
# --------------------------------------------------------------------------


def fresh(angle: int = 0) -> Player:
    mo = Mobj(angle=angle)
    mo.height = 56 * FRACUNIT
    p = Player(mo)
    p.leveltime = 0
    return p


def gen_thrust() -> list[list[int]]:
    rows = []
    cases = [
        (0, 25, 0, 0), (0, 0, 25, 0), (ANG90, 50, 0, 0), (0x20000000, 25, 25, 0),
        (0, -25, 0, 0), (0, 0, -25, 0), (0x12345600, 19, -7, 256), (ANG180, 25, 0, -512),
        (0xC0000000, -12, 31, 1024), (0, 127, -128, 0),
    ]
    for angle, forward, side, turn in cases:
        p = fresh(angle)
        move_player(p, forward, side, turn)
        rows.append([angle, forward, side, turn, p.mo.angle,
                     enc(p.mo.momx), enc(p.mo.momy)])
    return rows


def gen_friction() -> tuple[list[list[int]], list[list[int]]]:
    """A dozen tics of held input, then a dozen of coasting."""
    heads, rows = [], []
    # Every run starts facing east (E1M1's START_ANGLE) and stays in the
    # hall: the Cairo side replays them on the real map from the Player 1
    # start, where a wall would show up as a position mismatch.
    for angle, forward, side, hold in (
            (0, 25, 0, 6), (0, -25, 0, 8), (0, 0, 12, 6),
            (0, 0, -12, 10), (0, 20, 10, 6)):
        p = fresh(angle)
        heads.append([angle, forward, side, hold])
        for tic in range(12):
            f = forward if tic < hold else 0
            s = side if tic < hold else 0
            player_think(p, f, s, 0, 0, tic, Rng(), Shots())
            xy_movement(p.mo, bool(f or s))
            rows.append([enc(p.mo.momx), enc(p.mo.momy), enc(p.mo.x), enc(p.mo.y)])
    return heads, rows


def gen_calc() -> list[list[int]]:
    rows = []
    cases = [
        (0, 0, VIEWHEIGHT, 0, 0), (FRACUNIT, 0, VIEWHEIGHT, 0, 1),
        (5 * FRACUNIT, 0, VIEWHEIGHT, 0, 7), (0, 5 * FRACUNIT, VIEWHEIGHT, 0, 13),
        (7 * FRACUNIT, 7 * FRACUNIT, VIEWHEIGHT, 0, 20),
        (30 * FRACUNIT, 30 * FRACUNIT, VIEWHEIGHT, 0, 33),   # bob clamps at MAXBOB
        (2 * FRACUNIT, 0, VIEWHEIGHT // 2, -FRACUNIT, 5),
        (0, 0, 20 * FRACUNIT, FRACUNIT, 9),
        (0, 0, 40 * FRACUNIT, FRACUNIT, 11),
        (-4 * FRACUNIT, 3 * FRACUNIT, 30 * FRACUNIT, -2 * FRACUNIT, 40),
        (0, 0, VIEWHEIGHT, 0, 4095), (0, 0, VIEWHEIGHT, 0, 4096),
    ]
    for momx, momy, vh, dvh, tic in cases:
        p = fresh()
        p.mo.momx, p.mo.momy = momx, momy
        p.viewheight, p.deltaviewheight = vh, dvh
        p.leveltime = tic
        calc_height(p)
        rows.append([enc(momx), enc(momy), enc(vh), enc(dvh), tic,
                     enc(p.bob), enc(p.viewheight), enc(p.deltaviewheight),
                     enc(p.viewz - p.mo.z)])
    return rows


PSPR_SCRIPT = (
    [0] * 3                       # nothing: the pistol is already up
    + [BT_ATTACK] * 30            # hold fire: pistol cycle + refire
    + [0] * 8
    + [BT_CHANGE | (WP_FIST << BT_WEAPONSHIFT)] + [0] * 12   # switch to the fist
    + [BT_ATTACK] * 20            # punch, twice
    + [0] * 6
    + [BT_CHANGE | (WP_PISTOL << BT_WEAPONSHIFT)] + [0] * 12
    + [BT_ATTACK] * 24
    + [0] * 4
)


def gen_pspr() -> list[list[int]]:
    p = fresh()
    p.psp[PS_WEAPON] = [T.ready(WP_PISTOL), T.tics[T.ready(WP_PISTOL)]]
    p.psp_sy = WEAPONTOP
    p.ammo[AM_CLIP] = 8
    rng, shots = Rng(1), Shots()
    rows = []
    for tic, buttons in enumerate(PSPR_SCRIPT):
        player_think(p, 0, 0, 0, buttons, tic, rng, shots)
        rows.append([buttons, p.psp[PS_WEAPON][0], p.psp[PS_WEAPON][1],
                     p.psp[PS_FLASH][0], p.ammo[AM_CLIP], p.refire,
                     p.extralight, p.ready_weapon, p.pending_weapon, rng.index])
    return rows


def gen_pickups() -> list[list[int]]:
    rows = []
    cases = [
        # kind, flags, health, armor_pts, armor_type, ammo0, ammo1, weapons, backpack
        (K_BON1, MF_SPECIAL | MF_COUNTITEM, 100, 0, 0, 50, 0, 3, 0),
        (K_BON1, MF_SPECIAL | MF_COUNTITEM, 200, 0, 0, 50, 0, 3, 0),
        (K_BON2, MF_SPECIAL | MF_COUNTITEM, 100, 0, 0, 50, 0, 3, 0),
        (K_BON2, MF_SPECIAL | MF_COUNTITEM, 100, 200, 2, 50, 0, 3, 0),
        (K_STIM, MF_SPECIAL, 90, 0, 0, 50, 0, 3, 0),
        (K_STIM, MF_SPECIAL, 100, 0, 0, 50, 0, 3, 0),
        (K_MEDI, MF_SPECIAL, 50, 0, 0, 50, 0, 3, 0),
        (K_MEDI, MF_SPECIAL, 99, 0, 0, 50, 0, 3, 0),
        (K_SOUL, MF_SPECIAL | MF_COUNTITEM, 100, 0, 0, 50, 0, 3, 0),
        (K_SOUL, MF_SPECIAL | MF_COUNTITEM, 150, 0, 0, 50, 0, 3, 0),
        (K_ARM1, MF_SPECIAL, 100, 0, 0, 50, 0, 3, 0),
        (K_ARM1, MF_SPECIAL, 100, 100, 1, 50, 0, 3, 0),
        (K_ARM2, MF_SPECIAL, 100, 100, 1, 50, 0, 3, 0),
        (K_ARM2, MF_SPECIAL, 100, 200, 2, 50, 0, 3, 0),
        (K_BKEY, MF_SPECIAL, 100, 0, 0, 50, 0, 3, 0),
        (K_PSTR, MF_SPECIAL | MF_COUNTITEM, 20, 0, 0, 50, 0, 3, 0),
        (KIND_CLIP, MF_SPECIAL, 100, 0, 0, 50, 0, 3, 0),
        (KIND_CLIP, MF_SPECIAL | MF_DROPPED, 100, 0, 0, 50, 0, 3, 0),
        (KIND_CLIP, MF_SPECIAL, 100, 0, 0, 200, 0, 3, 0),
        (K_AMMO, MF_SPECIAL, 100, 0, 0, 50, 0, 3, 0),
        (K_AMMO, MF_SPECIAL, 100, 0, 0, 190, 0, 3, 0),
        (K_SHEL, MF_SPECIAL, 100, 0, 0, 0, 0, 3, 0),
        (K_SBOX, MF_SPECIAL, 100, 0, 0, 0, 0, 7, 0),
        (K_BPAK, MF_SPECIAL, 100, 0, 0, 195, 48, 3, 0),
        (K_BPAK, MF_SPECIAL, 100, 0, 0, 50, 0, 3, 1),
        (KIND_SHOTGUN, MF_SPECIAL, 100, 0, 0, 50, 0, 3, 0),
        (KIND_SHOTGUN, MF_SPECIAL | MF_DROPPED, 100, 0, 0, 50, 0, 3, 0),
        (KIND_SHOTGUN, MF_SPECIAL, 100, 0, 0, 50, 48, 7, 0),
        (K_CSAW, MF_SPECIAL, 100, 0, 0, 50, 0, 3, 0),
        (KIND_CHAINGUN, MF_SPECIAL, 100, 0, 0, 50, 0, 3, 0),
        (K_ROCK, MF_SPECIAL, 100, 0, 0, 50, 0, 3, 0),
        (K_CELL, MF_SPECIAL, 100, 0, 0, 50, 0, 3, 0),
    ]
    for kind, flags, health, ap, at, a0, a1, weapons, backpack in cases:
        p = fresh()
        p.health, p.armor_points, p.armor_type = health, ap, at
        p.ammo[AM_CLIP], p.ammo[AM_SHELL] = a0, a1
        p.weapons, p.backpack = weapons, bool(backpack)
        p.mo.health = health
        took = touch_special(p, kind, flags)
        rows.append([kind, flags, health, ap, at, a0, a1, weapons, backpack,
                     1 if took else 0, p.health, p.armor_points, p.armor_type,
                     p.ammo[AM_CLIP], p.ammo[AM_SHELL], p.ammo[AM_CELL],
                     p.ammo[AM_MISL], p.weapons, 1 if p.backpack else 0,
                     p.pending_weapon, p.itemcount, p.bonuscount, p.strength,
                     p.cards])
    return rows


def gen_damage() -> list[list[int]]:
    rows = []
    cases = [
        (0, 0, 100, 10), (1, 100, 100, 30), (2, 200, 100, 30),
        (1, 100, 100, 1), (1, 2, 100, 30), (2, 3, 100, 30),
        (1, 100, 100, 250), (0, 0, 100, 100), (0, 0, 100, 150),
        (2, 200, 100, 7), (1, 1, 50, 5), (0, 0, 5, 4),
    ]
    for at, ap, health, damage in cases:
        p = fresh()
        p.armor_type, p.armor_points, p.health = at, ap, health
        p.mo.health = health
        net = damage_player(p, damage)
        rows.append([at, ap, health, damage, net, p.armor_type, p.armor_points,
                     p.health, p.damagecount, p.playerstate])
    return rows


# --------------------------------------------------------------------------
# The 350-tic scripted run
# --------------------------------------------------------------------------

WALK_TICS = 350


def walk_script(tic: int) -> tuple[int, int, int, int]:
    """(forward, side, turn, buttons) — Doom's own walk speed (25) and a
    quantised turn (D12), so that `P_XYMovement` never halves; the bursts are
    short and symmetric so the player stays in the open hall east of E1M1's
    Player 1 start and never touches a wall."""
    if tic < 25:
        return 25, 0, 0, 0           # east, into the hall
    if tic < 50:
        return -25, 0, 0, 0          # back
    if tic < 80:
        return 0, 0, 256, 0          # turn in place
    if tic < 100:
        return 0, 12, 0, 0           # strafe
    if tic < 120:
        return 0, -12, 0, 0
    if tic < 150:
        return 0, 0, -256, 0         # turn back to east
    if tic < 190:
        return 0, 0, 0, BT_ATTACK    # empty rounds into the far wall
    if tic < 200:
        return 0, 0, 0, 0
    if tic < 210:
        return 0, 0, 0, BT_CHANGE | (WP_FIST << BT_WEAPONSHIFT)
    if tic < 260:
        return 0, 0, 0, BT_ATTACK    # punch the air
    if tic < 270:
        return 0, 0, 0, BT_CHANGE | (WP_PISTOL << BT_WEAPONSHIFT)
    if tic < 295:
        return 25, 0, 0, 0
    if tic < 320:
        return -25, 0, 0, 0
    return 0, 0, 0, BT_USE


def gen_walk() -> tuple[list[int], list[list[int]], int]:
    p = fresh(angle=0)   # E1M1's START_ANGLE
    p.psp[PS_WEAPON] = [T.ready(WP_PISTOL), T.tics[T.ready(WP_PISTOL)]]
    p.psp_sy = WEAPONTOP
    rng, shots = Rng(1), Shots()
    cmds, samples, checksum = [], [], 0
    bounds = [0, 0, 0, 0]
    for tic in range(WALK_TICS):
        forward, side, turn, buttons = walk_script(tic)
        cmds.append(encode_cmd(forward, side, turn, buttons))
        player_think(p, forward, side, turn, buttons, tic, rng, shots)
        xy_movement(p.mo, bool(forward or side))
        row = [enc(p.mo.x), enc(p.mo.y), p.mo.angle, enc(p.mo.momx), enc(p.mo.momy),
               enc(p.viewz - p.mo.z), p.psp[PS_WEAPON][0], p.psp[PS_FLASH][0],
               p.ammo[AM_CLIP], p.refire, p.ready_weapon, rng.index]
        if tic % 25 == 0 or tic == WALK_TICS - 1:
            samples.append([tic] + row)
        folded = 0
        for k, v in enumerate(row):
            folded += (k + 1) * v
        checksum += (tic + 1) * folded
        bounds[0] = min(bounds[0], p.mo.x)
        bounds[1] = max(bounds[1], p.mo.x)
        bounds[2] = min(bounds[2], p.mo.y)
        bounds[3] = max(bounds[3], p.mo.y)
    return cmds, samples, checksum, (bounds[0], bounds[1], bounds[2], bounds[3])


def encode_cmd(forward: int, side: int, turn: int, buttons: int) -> int:
    """`ticcmd::encode` (D12: the turn is a multiple of 256)."""
    assert -128 <= forward <= 127 and -128 <= side <= 127
    assert turn % 256 == 0 and -32768 <= turn <= 32512
    return ((forward + 128) | ((side + 128) << 8)
            | ((turn // 256 + 128) << 16) | (buttons << 24))


# --------------------------------------------------------------------------
# Emitting
# --------------------------------------------------------------------------


def flat(rows: list[list[int]]) -> list[int]:
    out: list[int] = []
    for r in rows:
        out.extend(r)
    return out


def array(name: str, values: list[int], ty: str = "felt252") -> str:
    body = ", ".join(str(v) for v in values)
    return "pub const %s: [%s; %d] = [%s];\n\n" % (name, ty, len(values), body)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    thrust_rows = gen_thrust()
    friction_heads, friction_rows = gen_friction()
    calc_rows = gen_calc()
    pspr_rows = gen_pspr()
    pickup_rows = gen_pickups()
    damage_rows = gen_damage()
    cmds, samples, checksum, bounds = gen_walk()

    print("thrust      %3d vectors" % len(thrust_rows))
    print("friction    %3d runs x 12 tics" % len(friction_heads))
    print("calc_height %3d vectors" % len(calc_rows))
    print("psprites    %3d tics" % len(pspr_rows))
    print("pickups     %3d vectors" % len(pickup_rows))
    print("damage      %3d vectors" % len(damage_rows))
    print("walk        %3d tics, %d samples, checksum %d"
          % (len(cmds), len(samples), checksum))
    print("walk bounds dx [%d, %d] dy [%d, %d] map units"
          % (bounds[0] // FRACUNIT, bounds[1] // FRACUNIT,
             bounds[2] // FRACUNIT, bounds[3] // FRACUNIT))

    if not args.write:
        return 0

    text = (
        "// SPDX-License-Identifier: GPL-2.0-only\n"
        "// GENERATED by scripts/model.py -- do not edit by hand.\n"
        "//\n"
        "// Reference values from an independent Python transcription of\n"
        "// linuxdoom-1.10's `p_user.c`, `p_pspr.c` and `p_inter.c`. Every\n"
        "// `Fixed` is offset-encoded (`enc = raw + 2^32`), so every felt here\n"
        "// is non-negative and below 2^72 (PLAN.md A7).\n\n"
        "/// `(angle_in, forward, side, turn, angle_out, momx, momy)`.\n"
        + array("THRUST", flat(thrust_rows))
        + "pub const THRUST_STRIDE: u32 = 7;\n\n"
        "/// `(angle, forward, side, hold)` per friction run.\n"
        + array("FRICTION_HEAD", flat(friction_heads))
        + "pub const FRICTION_HEAD_STRIDE: u32 = 4;\n"
        "/// `(momx, momy, x, y)` after each of the run's 12 tics.\n"
        + array("FRICTION", flat(friction_rows))
        + "pub const FRICTION_STRIDE: u32 = 4;\n"
        "pub const FRICTION_TICS: u32 = 12;\n\n"
        "/// `(momx, momy, viewheight, deltaviewheight, tic,\n"
        "///   bob, viewheight', deltaviewheight', viewz - mo.z)`.\n"
        + array("CALC", flat(calc_rows))
        + "pub const CALC_STRIDE: u32 = 9;\n\n"
        "/// `(buttons, psp_state, psp_tics, flash_state, ammo_clip, refire,\n"
        "///   extralight, ready_weapon, pending_weapon, rng_index)` per tic.\n"
        + array("PSPR", flat(pspr_rows))
        + "pub const PSPR_STRIDE: u32 = 10;\n\n"
        "/// `(kind, flags, health, armor_points, armor_type, ammo_clip,\n"
        "///   ammo_shell, weapons, backpack | took, health', armor_points',\n"
        "///   armor_type', ammo', weapons', backpack', pending_weapon,\n"
        "///   itemcount, bonuscount, strength, cards)`.\n"
        + array("PICKUP", flat(pickup_rows))
        + "pub const PICKUP_STRIDE: u32 = 24;\n\n"
        "/// `(armor_type, armor_points, health, damage | net, armor_type',\n"
        "///   armor_points', health', damagecount, playerstate)`.\n"
        + array("DAMAGE", flat(damage_rows))
        + "pub const DAMAGE_STRIDE: u32 = 10;\n\n"
        "/// The 350 encoded ticcmd words of the scripted run.\n"
        + array("WALK_CMDS", cmds)
        + "/// `(tic, x, y, angle, momx, momy, viewz - mo.z, psp_state,\n"
        "///   flash_state, ammo_clip, refire, ready_weapon, rng_index)`,\n"
        "/// every 25th tic. `x`/`y` are **relative to the spawn point**.\n"
        + array("WALK_SAMPLES", flat(samples))
        + "pub const WALK_SAMPLE_STRIDE: u32 = 13;\n"
        "pub const WALK_TICS: u32 = %d;\n" % WALK_TICS
        + "/// `sum over tics of (tic + 1) * sum over fields of (k + 1) * value`\n"
        "/// on every tic of the run, not only the sampled ones.\n"
        "pub const WALK_CHECKSUM: felt252 = %d;\n" % checksum
    )
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text)
    subprocess.run(["scarb", "fmt", "-p", "doom_player"], cwd=str(CAIRO), check=False)
    print("wrote %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())

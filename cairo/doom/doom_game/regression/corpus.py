# SPDX-License-Identifier: GPL-2.0-only
"""Deterministic command-only E1M1 scenarios; never construct or mutate game state."""
import random

SEED = 20260913


def word(forward=0, side=0, turn=0, buttons=0):
    if not (-128 <= forward <= 127 and -128 <= side <= 127 and
            -32768 <= turn <= 32512 and turn % 256 == 0 and 0 <= buttons <= 255):
        raise ValueError("noncanonical ticcmd")
    return ((forward + 128) | ((side + 128) << 8) |
            ((turn // 256 + 128) << 16) | (buttons << 24))


def script(parts):
    return [word(f, s, t, b) for n, f, s, t, b in parts for _ in range(n)]


def scenarios():
    # These five command logs mirror bench/profile.py and src/tests/e1m1.cairo.
    # Their historical Cairo pins are independent and are never changed here.
    idle = [(700, 0, 0, 0, 0)]
    walk = [(110, 25, 0, 0, 0), (240, 0, 0, 0, 0)]
    door = [(136, 25, 0, 0, 0), (1, 0, 0, 10240, 0), (25, 25, 0, 0, 0),
            (1, 0, 0, 6144, 0)] + [(34, 25, 0, 0, 0), (1, 25, 0, 0, 2)] * 5 + [(12, 0, 0, 0, 0)]
    fight = [(110, 25, 0, 0, 0), (1, 0, 0, 6656, 0)]
    for _ in range(2):
        fight += [(20, 0, 0, 0, 1), (1, 0, 0, -512, 1)] * 13 + [(1, 0, 0, 6656, 1)]
    fight += [(41, 0, 0, 0, 1)]
    death = [(150, 25, 0, 0, 0), (1, 0, 0, 1792, 0), (1049, 0, 0, 0, 0)]
    entries = [
        ("idle", "historical idle, dormant actors and lights", idle),
        ("walk_lift", "historical movement, pickup, lift and received damage", walk),
        ("door_pickups", "historical pulses of use, door and pickups", door),
        ("fight_sweep", "historical pistol sweep and confirmed kill", fight),
        ("death", "historical genuine death, commands after terminal are not counted", death),
        ("reverse_wall", "reverse movement into the starting room wall", [(180, -25, 0, 0, 0)]),
        ("strafe_left", "leftward collision and sliding", [(140, 0, -40, 0, 0)]),
        ("strafe_right", "rightward collision and sliding", [(145, 0, 40, 0, 0)]),
        ("turn_clockwise", "BAM wrap with a stationary player", [(129, 0, 0, 512, 0)]),
        ("reverse_turn", "backwards curve with strafe and quantized turns", [(120, -25, 20, -256, 0)]),
        ("diagonal_sprint", "simultaneous full forward and sideways input", [(220, 50, 40, 0, 0)]),
        ("zigzag", "alternating movement, turns and released controls",
         [(25, 25, 0, 0, 0), (10, 0, -20, 1024, 0), (20, 25, 20, 0, 0), (5, 0, 0, 0, 0)] * 3),
        ("coast_reverse", "momentum decay then reversed thrust",
         [(60, 50, 0, 0, 0), (40, 0, 0, 0, 0), (60, -50, 0, 0, 0), (40, 0, 0, 0, 0)]),
        ("pistol_spawn", "held attack, ammo depletion and wall puffs", [(120, 0, 0, 0, 1)]),
        ("fist_attack", "switch to owned fist then attack",
         [(1, 0, 0, 0, 4), (30, 0, 0, 0, 0), (100, 0, 0, 0, 1)]),
        ("pistol_taps", "attack press/release cadence", [(3, 0, 0, 0, 1), (8, 0, 0, 0, 0)] * 12),
        ("weapon_requests", "owned/unowned weapon requests, fist then pistol",
         [(1, 0, 0, 0, 4 | (2 << 3)), (30, 0, 0, 0, 1),
          (1, 0, 0, 0, 4), (30, 0, 0, 0, 1),
          (1, 0, 0, 0, 4 | (1 << 3)), (60, 0, 0, 0, 1)]),
        ("door_without_use", "same approach with use deliberately released",
         [(n, f, s, t, 0) for n, f, s, t, _ in door]),
        ("door_held_use", "same approach with held use instead of edge pulses",
         door[:4] + [(175, 25, 0, 0, 2), (12, 0, 0, 0, 0)]),
        ("door_retreat", "door route followed by a backwards retreat", door + [(70, -25, 0, 0, 0)]),
        ("pickup_then_fire", "picked-up state followed by turning attacks",
         door + [(1, 0, 0, 6656, 0), (100, 0, 0, -256, 1)]),
        ("sprint_combat", "faster approach then moving attack sweep",
         [(55, 50, 0, 0, 0), (1, 0, 0, 6656, 0), (180, 15, -10, -256, 1)]),
        ("legal_extremes", "canonical i8/i16 extrema and full button byte",
         [(8, -128, 127, -32768, 255), (8, 127, -128, 32512, 0)] * 6),
        ("use_blocked_wall", "use edges toward the start wall",
         [(1, 0, 0, -16384, 0)] + [(3, 25, 0, 0, 2), (7, 25, 0, 0, 0)] * 10),
    ]
    cases = [{"name": name, "purpose": purpose, "words": script(parts)}
             for name, purpose, parts in entries]
    rng = random.Random(SEED ^ 0xC0A5)
    cases.append({"name": "seeded_u32", "purpose": "all canonical command fields from seeded u32 words",
                  "words": [rng.getrandbits(32) for _ in range(128)]})
    if len({tuple(c["words"]) for c in cases}) != len(cases):
        raise AssertionError("duplicate replay commands")
    return cases

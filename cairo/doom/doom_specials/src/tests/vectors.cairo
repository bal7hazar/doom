// SPDX-License-Identifier: GPL-2.0-only
//
//! GENERATED -- do not edit (see `scripts/reference.py`).
//!
//! What an independent Python transcription of linuxdoom-1.10's
//! `p_spec.c` / `p_doors.c` / `p_plats.c` / `p_floor.c` / `p_lights.c`
//! computes on Freedoom E1M1. `src/tests.cairo` checks the Cairo thinkers
//! against these numbers; nothing here is read back out of the Cairo
//! implementation, so the two can only agree by both being right.

/// Number of light thinkers `P_SpawnSpecials` creates.
pub const NUM_LIGHTS: u32 = 9;

/// Eight fields per light thinker at spawn: sector, kind (0 flash, 1 strobe), light, maxlight,
/// minlight, hi_time, lo_time, next (= Doom's initial `count - 1`, the absolute tic of the first
/// flip).
pub const SPAWN_LIGHTS: [u32; 72] = [
    32, 0, 176, 176, 144, 64, 7, 0, 33, 0, 176, 176, 140, 64, 7, 64, 48, 0, 140, 140, 120, 64, 7,
    64, 90, 1, 192, 192, 160, 5, 35, 0, 96, 1, 192, 192, 160, 5, 35, 0, 98, 1, 192, 192, 160, 5, 35,
    0, 147, 1, 192, 192, 160, 5, 35, 0, 150, 1, 192, 192, 160, 5, 35, 0, 151, 1, 192, 192, 160, 5,
    35, 0,
];

/// `P_Random` cursor after `P_SpawnSpecials`, from `from_index(1)`.
pub const SPAWN_RNG: u32 = 4;

/// Manual-door lines (specials 1, 26, 117).
pub const NUM_MANUAL_DOORS: u32 = 25;

/// Four fields per manual-door line: linedef, its back sector, that sector's ceiling at spawn and
/// the `topheight` `P_FindLowestCeilingSurrounding(sec) - 4 * FRACUNIT` a door opens to, both in
/// `fixed` encoding.
pub const MANUAL_DOORS: [felt252; 100] = [
    55, 10, 4286578688, 4294705152, 201, 34, 4286578688, 4294705152, 203, 34, 4286578688,
    4294705152, 345, 54, 4304404480, 4308860928, 389, 64, 4286578688, 4291035136, 391, 64,
    4286578688, 4291035136, 421, 71, 4286578688, 4294705152, 423, 71, 4286578688, 4294705152, 442,
    81, 4286578688, 4294705152, 446, 80, 4286578688, 4294705152, 450, 79, 4286578688, 4294705152,
    454, 78, 4286578688, 4294705152, 474, 78, 4286578688, 4294705152, 477, 79, 4286578688,
    4294705152, 480, 80, 4286578688, 4294705152, 483, 81, 4286578688, 4294705152, 520, 51,
    4286578688, 4294705152, 522, 51, 4286578688, 4294705152, 537, 48, 4286578688, 4294180864, 539,
    48, 4286578688, 4294180864, 577, 10, 4286578688, 4294705152, 599, 100, 4294967296, 4303093760,
    602, 100, 4294967296, 4303093760, 698, 54, 4304404480, 4308860928, 1162, 84, 4294967296,
    4298899456,
];

/// (linedef, special, tag, sector) rows for every tagged special.
pub const NUM_TAGGED: u32 = 18;

/// Four fields per row: linedef, special, tag, sector.
pub const TAGGED: [u32; 72] = [
    528, 2, 5, 77, 593, 88, 1, 98, 594, 62, 1, 98, 595, 88, 1, 98, 596, 88, 1, 98, 618, 88, 2, 103,
    620, 62, 2, 103, 753, 23, 3, 76, 753, 23, 3, 126, 753, 23, 3, 129, 997, 2, 6, 145, 998, 2, 6,
    145, 999, 2, 6, 145, 1002, 2, 5, 77, 1006, 2, 5, 77, 1064, 62, 2, 103, 1075, 62, 2, 103, 1078,
    88, 2, 103,
];

/// Sector the scripted run's door moves (linedef 55's back sector).
pub const SEQ_DOOR_SECTOR: u32 = 10;

/// Sector the scripted run's lift moves (linedef 594's tag).
pub const SEQ_LIFT_SECTOR: u32 = 98;

/// Linedefs the scripted run touches, at tics 10, 200 and 400.
pub const SEQ_DOOR_LINE: u32 = 55;
pub const SEQ_LIFT_LINE: u32 = 594;
pub const SEQ_WALK_LIFT_LINE: u32 = 593;

/// Length of the scripted run, and its sampling period.
pub const SEQ_TICS: u32 = 700;
pub const SEQ_SAMPLE_EVERY: u32 = 25;

/// Samples taken by the scripted run.
pub const NUM_SEQ_SAMPLES: u32 = 28;

/// Four fields per sample: tic, the door sector's ceiling and the lift sector's floor in `fixed`
/// encoding, and the sum of the nine light levels.
pub const SEQ_SAMPLES: [felt252; 112] = [
    0, 4286578688, 4295753728, 1420, 25, 4288675840, 4295753728, 1452, 50, 4291952640, 4295753728,
    1452, 75, 4294705152, 4295753728, 1612, 100, 4294705152, 4295753728, 1452, 125, 4294705152,
    4295753728, 1452, 150, 4294705152, 4295753728, 1420, 175, 4294705152, 4295753728, 1452, 200,
    4294705152, 4295491584, 1452, 225, 4294311936, 4288937984, 1384, 250, 4291035136, 4286840832,
    1420, 275, 4287758336, 4286840832, 1644, 300, 4286578688, 4286840832, 1432, 325, 4286578688,
    4286840832, 1452, 350, 4286578688, 4289724416, 1452, 375, 4286578688, 4295753728, 1452, 400,
    4286578688, 4295491584, 1452, 425, 4286578688, 4288937984, 1452, 450, 4286578688, 4286840832,
    1452, 475, 4286578688, 4286840832, 1624, 500, 4286578688, 4286840832, 1452, 525, 4286578688,
    4286840832, 1452, 550, 4286578688, 4289724416, 1420, 575, 4286578688, 4295753728, 1384, 600,
    4286578688, 4295753728, 1420, 625, 4286578688, 4295753728, 1432, 650, 4286578688, 4295753728,
    1452, 675, 4286578688, 4295753728, 1644,
];

/// `sum over tics of (tic + 1) * (ceiling + 5 * floor + 11 * lights)`
/// over the whole 700-tic run -- one number that moves if any tic of
/// any thinker moves.
pub const SEQ_CHECKSUM: felt252 = 6316958217693264;

/// Phase changes of the scripted run's door and lift, as absolute
/// tics: door fully open, door starts closing, door thinker removed;
/// lift reaches the bottom, starts back up, thinker removed.
pub const SEQ_DOOR_OPEN_TIC: u32 = 72;
pub const SEQ_DOOR_CLOSE_TIC: u32 = 222;
pub const SEQ_DOOR_DONE_TIC: u32 = 285;
pub const SEQ_LIFT_BOTTOM_TIC: u32 = 234;
pub const SEQ_LIFT_UP_TIC: u32 = 339;
pub const SEQ_LIFT_DONE_TIC: u32 = 374;

/// The nine light levels every 10 tics for the first 200 tics of a run with no trigger at all, nine
/// values per sample -- the `T_StrobeFlash` and `T_LightFlash` reference.
pub const LIGHT_TIMELINE: [u32; 180] = [
    144, 176, 140, 160, 160, 160, 160, 160, 160, 176, 176, 140, 160, 160, 160, 160, 160, 160, 176,
    176, 140, 160, 160, 160, 160, 160, 160, 176, 176, 140, 160, 160, 160, 160, 160, 160, 176, 176,
    140, 160, 160, 160, 160, 160, 160, 176, 176, 140, 160, 160, 160, 160, 160, 160, 176, 176, 140,
    160, 160, 160, 160, 160, 160, 176, 176, 140, 160, 160, 160, 160, 160, 160, 144, 176, 140, 160,
    160, 160, 160, 160, 160, 176, 176, 140, 160, 160, 160, 160, 160, 160, 176, 176, 140, 160, 160,
    160, 160, 160, 160, 176, 176, 140, 160, 160, 160, 160, 160, 160, 176, 176, 140, 160, 160, 160,
    160, 160, 160, 176, 176, 140, 160, 160, 160, 160, 160, 160, 176, 140, 140, 160, 160, 160, 160,
    160, 160, 144, 176, 140, 160, 160, 160, 160, 160, 160, 176, 176, 140, 160, 160, 160, 160, 160,
    160, 176, 176, 140, 160, 160, 160, 160, 160, 160, 176, 176, 140, 160, 160, 160, 160, 160, 160,
    176, 176, 140, 160, 160, 160, 160, 160, 160,
];

/// Samples in `LIGHT_TIMELINE`, nine values each.
pub const LIGHT_SAMPLES: u32 = 20;

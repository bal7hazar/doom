// SPDX-License-Identifier: GPL-2.0-only
//
//! GENERATED -- do not edit. Regenerate with
//! `python3 cairo/doom/doom_things/scripts/gen_things.py --src <linuxdoom-1.10> \
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

// Action ids. `fsm::advance` returns one of these for the state it
// enters and the caller dispatches on it, because Cairo has no
// function pointers (D15). `generated/actions.md` is the same table
// in prose, for `doom_monsters` and `doom_player`.
/// `A_Chase` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_CHASE: u32 = 1;

/// `A_Explode` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_EXPLODE: u32 = 2;

/// `A_FaceTarget` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_FACETARGET: u32 = 3;

/// `A_Fall` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_FALL: u32 = 4;

/// `A_FireCGun` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_FIRECGUN: u32 = 5;

/// `A_FirePistol` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_FIREPISTOL: u32 = 6;

/// `A_FireShotgun` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_FIRESHOTGUN: u32 = 7;

/// `A_Light0` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_LIGHT0: u32 = 8;

/// `A_Light1` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_LIGHT1: u32 = 9;

/// `A_Light2` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_LIGHT2: u32 = 10;

/// `A_Look` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_LOOK: u32 = 11;

/// `A_Lower` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_LOWER: u32 = 12;

/// `A_Pain` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_PAIN: u32 = 13;

/// `A_PlayerScream` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_PLAYERSCREAM: u32 = 14;

/// `A_PosAttack` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_POSATTACK: u32 = 15;

/// `A_Punch` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_PUNCH: u32 = 16;

/// `A_Raise` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_RAISE: u32 = 17;

/// `A_ReFire` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_REFIRE: u32 = 18;

/// `A_SPosAttack` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_SPOSATTACK: u32 = 19;

/// `A_SargAttack` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_SARGATTACK: u32 = 20;

/// `A_Saw` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_SAW: u32 = 21;

/// `A_Scream` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_SCREAM: u32 = 22;

/// `A_TroopAttack` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_TROOPATTACK: u32 = 23;

/// `A_WeaponReady` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_WEAPONREADY: u32 = 24;

/// `A_XScream` of linuxdoom's `p_enemy.c` / `p_pspr.c`.
pub const A_XSCREAM: u32 = 25;

// Indices into the `MI_*` columns, one per `mobjinfo` entry kept.
/// linuxdoom's `MT_PLAYER` (doomednum none).
pub const KIND_PLAYER: u32 = 0;

/// linuxdoom's `MT_POSSESSED` (doomednum 3004).
pub const KIND_POSSESSED: u32 = 1;

/// linuxdoom's `MT_SHOTGUY` (doomednum 9).
pub const KIND_SHOTGUY: u32 = 2;

/// linuxdoom's `MT_TROOP` (doomednum 3001).
pub const KIND_TROOP: u32 = 3;

/// linuxdoom's `MT_SERGEANT` (doomednum 3002).
pub const KIND_SERGEANT: u32 = 4;

/// linuxdoom's `MT_SHADOWS` (doomednum 58).
pub const KIND_SHADOWS: u32 = 5;

/// linuxdoom's `MT_BARREL` (doomednum 2035).
pub const KIND_BARREL: u32 = 6;

/// linuxdoom's `MT_TROOPSHOT` (doomednum none).
pub const KIND_TROOPSHOT: u32 = 7;

/// linuxdoom's `MT_PUFF` (doomednum none).
pub const KIND_PUFF: u32 = 8;

/// linuxdoom's `MT_BLOOD` (doomednum none).
pub const KIND_BLOOD: u32 = 9;

/// linuxdoom's `MT_MISC0` (doomednum 2018).
pub const KIND_MISC0: u32 = 10;

/// linuxdoom's `MT_MISC1` (doomednum 2019).
pub const KIND_MISC1: u32 = 11;

/// linuxdoom's `MT_MISC2` (doomednum 2014).
pub const KIND_MISC2: u32 = 12;

/// linuxdoom's `MT_MISC3` (doomednum 2015).
pub const KIND_MISC3: u32 = 13;

/// linuxdoom's `MT_MISC4` (doomednum 5).
pub const KIND_MISC4: u32 = 14;

/// linuxdoom's `MT_MISC10` (doomednum 2011).
pub const KIND_MISC10: u32 = 15;

/// linuxdoom's `MT_MISC11` (doomednum 2012).
pub const KIND_MISC11: u32 = 16;

/// linuxdoom's `MT_MISC12` (doomednum 2013).
pub const KIND_MISC12: u32 = 17;

/// linuxdoom's `MT_MISC13` (doomednum 2023).
pub const KIND_MISC13: u32 = 18;

/// linuxdoom's `MT_CLIP` (doomednum 2007).
pub const KIND_CLIP: u32 = 19;

/// linuxdoom's `MT_MISC17` (doomednum 2048).
pub const KIND_MISC17: u32 = 20;

/// linuxdoom's `MT_MISC18` (doomednum 2010).
pub const KIND_MISC18: u32 = 21;

/// linuxdoom's `MT_MISC19` (doomednum 2046).
pub const KIND_MISC19: u32 = 22;

/// linuxdoom's `MT_MISC20` (doomednum 2047).
pub const KIND_MISC20: u32 = 23;

/// linuxdoom's `MT_MISC21` (doomednum 17).
pub const KIND_MISC21: u32 = 24;

/// linuxdoom's `MT_MISC22` (doomednum 2008).
pub const KIND_MISC22: u32 = 25;

/// linuxdoom's `MT_MISC23` (doomednum 2049).
pub const KIND_MISC23: u32 = 26;

/// linuxdoom's `MT_MISC24` (doomednum 8).
pub const KIND_MISC24: u32 = 27;

/// linuxdoom's `MT_CHAINGUN` (doomednum 2002).
pub const KIND_CHAINGUN: u32 = 28;

/// linuxdoom's `MT_MISC26` (doomednum 2005).
pub const KIND_MISC26: u32 = 29;

/// linuxdoom's `MT_MISC27` (doomednum 2003).
pub const KIND_MISC27: u32 = 30;

/// linuxdoom's `MT_MISC28` (doomednum 2004).
pub const KIND_MISC28: u32 = 31;

/// linuxdoom's `MT_SHOTGUN` (doomednum 2001).
pub const KIND_SHOTGUN: u32 = 32;

/// linuxdoom's `MT_MISC31` (doomednum 2028).
pub const KIND_MISC31: u32 = 33;

/// linuxdoom's `MT_MISC40` (doomednum 43).
pub const KIND_MISC40: u32 = 34;

/// linuxdoom's `MT_MISC47` (doomednum 47).
pub const KIND_MISC47: u32 = 35;

/// linuxdoom's `MT_MISC48` (doomednum 48).
pub const KIND_MISC48: u32 = 36;

/// linuxdoom's `MT_MISC57` (doomednum 60).
pub const KIND_MISC57: u32 = 37;

/// linuxdoom's `MT_MISC62` (doomednum 15).
pub const KIND_MISC62: u32 = 38;

/// linuxdoom's `MT_MISC63` (doomednum 18).
pub const KIND_MISC63: u32 = 39;

/// linuxdoom's `MT_MISC64` (doomednum 21).
pub const KIND_MISC64: u32 = 40;

/// linuxdoom's `MT_MISC66` (doomednum 20).
pub const KIND_MISC66: u32 = 41;

/// linuxdoom's `MT_MISC67` (doomednum 19).
pub const KIND_MISC67: u32 = 42;

/// linuxdoom's `MT_MISC68` (doomednum 10).
pub const KIND_MISC68: u32 = 43;

/// linuxdoom's `MT_MISC69` (doomednum 12).
pub const KIND_MISC69: u32 = 44;

/// linuxdoom's `MT_MISC71` (doomednum 24).
pub const KIND_MISC71: u32 = 45;

/// linuxdoom's `MT_MISC75` (doomednum 26).
pub const KIND_MISC75: u32 = 46;

/// linuxdoom's `MT_MISC76` (doomednum 54).
pub const KIND_MISC76: u32 = 47;

/// Number of states in the tables below.
pub const NUM_STATES: u32 = 266;

/// Number of `mobjinfo` entries.
pub const NUM_KINDS: u32 = 48;

/// Number of distinct action ids (0 is `fsm::NO_ACTION`).
pub const NUM_ACTIONS: u32 = 26;

/// `fsm::StateTables::sprite`.
pub const STATE_SPRITE: [u32; 266] = [
    0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 5, 5,
    6, 6, 6, 6, 6, 6, 7, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9, 10, 10, 10, 10, 11, 11, 11, 11, 11, 12, 12,
    12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 13, 13,
    13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
    13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
    14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 16, 16, 17,
    17, 18, 18, 19, 19, 19, 19, 19, 20, 20, 20, 20, 20, 20, 21, 21, 21, 21, 21, 21, 22, 22, 23, 24,
    25, 25, 25, 25, 25, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43,
    43, 44, 45, 46, 47, 48,
];

/// `fsm::StateTables::frame`; bit 15 (32768) is Doom's full-bright flag.
pub const STATE_FRAME: [u32; 266] = [
    0, 4, 0, 0, 0, 1, 2, 3, 2, 1, 0, 0, 0, 0, 1, 2, 1, 32768, 0, 0, 0, 0, 0, 1, 2, 3, 2, 1, 0, 0,
    32768, 32769, 0, 0, 0, 0, 1, 1, 32768, 2, 3, 2, 2, 0, 1, 1, 2, 1, 0, 32768, 1, 2, 3, 32768,
    32769, 32770, 32771, 32772, 0, 0, 1, 2, 3, 4, 6, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
    19, 20, 21, 22, 0, 1, 0, 0, 1, 1, 2, 2, 3, 3, 4, 5, 4, 6, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 10, 9, 8, 7, 0, 1, 0, 0, 1, 1, 2, 2, 3, 3, 4, 32773, 4, 6, 6, 7, 8, 9, 10,
    11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 11, 10, 9, 8, 7, 0, 1, 0, 0, 1, 1, 2, 2, 3, 3, 4, 5, 6,
    7, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 12, 11, 10, 9, 8, 0, 1, 0, 0, 1, 1, 2,
    2, 3, 3, 4, 5, 6, 7, 7, 8, 9, 10, 11, 12, 13, 13, 12, 11, 10, 9, 8, 0, 32769, 0, 32769, 0, 1,
    32768, 32769, 32770, 32771, 32772, 0, 1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1, 0, 32769, 0, 0, 32768,
    32769, 32770, 32771, 32770, 32769, 32768, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32768, 0, 0,
    1, 0, 0, 0, 0, 0,
];

/// `fsm::StateTables::tics`; `fsm::FOREVER` is `-1`.
pub const STATE_TICS: [u32; 266] = [
    4294967295, 0, 1, 1, 1, 4, 4, 5, 4, 5, 1, 1, 1, 4, 6, 4, 5, 7, 1, 1, 1, 3, 7, 5, 5, 4, 5, 5, 3,
    7, 4, 3, 1, 1, 1, 4, 4, 0, 5, 4, 4, 1, 1, 4, 4, 0, 8, 8, 8, 4, 4, 4, 4, 4, 4, 6, 6, 6,
    4294967295, 4, 4, 4, 4, 12, 4, 4, 10, 10, 10, 10, 10, 10, 4294967295, 5, 5, 5, 5, 5, 5, 5, 5,
    4294967295, 10, 10, 4, 4, 4, 4, 4, 4, 4, 4, 10, 8, 8, 3, 3, 5, 5, 5, 5, 4294967295, 5, 5, 5, 5,
    5, 5, 5, 5, 4294967295, 5, 5, 5, 5, 10, 10, 3, 3, 3, 3, 3, 3, 3, 3, 10, 10, 10, 3, 3, 5, 5, 5,
    5, 4294967295, 5, 5, 5, 5, 5, 5, 5, 5, 4294967295, 5, 5, 5, 5, 5, 10, 10, 3, 3, 3, 3, 3, 3, 3,
    3, 8, 8, 6, 2, 2, 8, 8, 6, 6, 4294967295, 5, 5, 5, 5, 5, 5, 5, 4294967295, 8, 8, 6, 6, 6, 10,
    10, 2, 2, 2, 2, 2, 2, 2, 2, 8, 8, 8, 2, 2, 8, 8, 4, 4, 4, 4294967295, 5, 5, 5, 5, 5, 5, 6, 7, 6,
    6, 6, 6, 5, 5, 5, 10, 10, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 10, 10, 4294967295, 4294967295, 6,
    6, 6, 6, 6, 6, 4294967295, 4294967295, 4294967295, 4294967295, 4294967295, 4294967295,
    4294967295, 4294967295, 4294967295, 4294967295, 4294967295, 4294967295, 4294967295, 4294967295,
    4294967295, 4294967295, 4294967295, 6, 8, 4294967295, 4294967295, 4294967295, 4294967295,
    4294967295,
];

/// `fsm::StateTables::action_id`.
pub const STATE_ACTION: [u32; 266] = [
    0, 8, 24, 12, 17, 0, 16, 0, 0, 18, 24, 12, 17, 0, 6, 0, 18, 9, 24, 12, 17, 0, 7, 0, 0, 0, 0, 0,
    0, 18, 9, 10, 24, 12, 17, 5, 5, 18, 9, 24, 24, 12, 17, 21, 21, 18, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 13, 0, 14, 4, 0, 0, 0, 0, 0, 25, 4, 0, 0, 0, 0, 0, 0, 11, 11, 1, 1,
    1, 1, 1, 1, 1, 1, 3, 15, 0, 0, 13, 0, 22, 4, 0, 0, 0, 25, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 11,
    11, 1, 1, 1, 1, 1, 1, 1, 1, 3, 19, 0, 0, 13, 0, 22, 4, 0, 0, 0, 25, 4, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 11, 11, 1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 23, 0, 13, 0, 22, 0, 4, 0, 0, 25, 0, 4, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 11, 11, 1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 20, 0, 13, 0, 22, 0, 4, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 22, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// `fsm::StateTables::next_state`.
pub const STATE_NEXT: [u32; 266] = [
    0, 0, 2, 3, 4, 6, 7, 8, 9, 2, 10, 11, 12, 14, 15, 16, 10, 1, 18, 19, 20, 22, 23, 24, 25, 26, 27,
    28, 29, 18, 31, 1, 32, 33, 34, 36, 37, 32, 1, 40, 39, 41, 42, 44, 45, 39, 47, 48, 0, 50, 51, 52,
    0, 54, 53, 56, 57, 0, 0, 60, 61, 62, 59, 58, 65, 58, 67, 68, 69, 70, 71, 72, 0, 74, 75, 76, 77,
    78, 79, 80, 81, 0, 83, 82, 85, 86, 87, 88, 89, 90, 91, 84, 93, 94, 84, 96, 84, 98, 99, 100, 101,
    0, 103, 104, 105, 106, 107, 108, 109, 110, 0, 112, 113, 114, 84, 116, 115, 118, 119, 120, 121,
    122, 123, 124, 117, 126, 127, 117, 129, 117, 131, 132, 133, 134, 0, 136, 137, 138, 139, 140,
    141, 142, 143, 0, 145, 146, 147, 148, 117, 150, 149, 152, 153, 154, 155, 156, 157, 158, 151,
    160, 161, 151, 163, 151, 165, 166, 167, 168, 0, 170, 171, 172, 173, 174, 175, 176, 0, 178, 179,
    180, 181, 151, 183, 182, 185, 186, 187, 188, 189, 190, 191, 184, 193, 194, 184, 196, 184, 198,
    199, 200, 201, 202, 0, 204, 205, 206, 207, 208, 184, 210, 209, 212, 211, 214, 213, 216, 217,
    218, 219, 0, 221, 222, 223, 224, 225, 220, 227, 228, 229, 230, 231, 226, 233, 232, 0, 0, 237,
    238, 239, 240, 241, 236, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 260, 259, 0, 0, 0,
    0, 0,
];

/// `mobjinfo.doomednum`: THINGS type id, `0xFFFF` when the entry cannot be placed on a map.
pub const MI_DOOMEDNUM: [u32; 48] = [
    65535, 3004, 9, 3001, 3002, 58, 2035, 65535, 65535, 65535, 2018, 2019, 2014, 2015, 5, 2011,
    2012, 2013, 2023, 2007, 2048, 2010, 2046, 2047, 17, 2008, 2049, 8, 2002, 2005, 2003, 2004, 2001,
    2028, 43, 47, 48, 60, 15, 18, 21, 20, 19, 10, 12, 24, 26, 54,
];

/// `mobjinfo.spawnstate`: State a freshly spawned mobj enters.
pub const MI_SPAWNSTATE: [u32; 48] = [
    58, 82, 115, 149, 182, 182, 213, 53, 49, 46, 209, 211, 220, 226, 232, 234, 235, 236, 242, 243,
    244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255, 256, 257, 263, 262, 265, 261, 72,
    101, 202, 168, 134, 81, 81, 258, 259, 264,
];

/// `mobjinfo.spawnhealth`: Starting health.
pub const MI_SPAWNHEALTH: [u32; 48] = [
    100, 20, 30, 60, 150, 150, 20, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000,
    1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000,
    1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000,
];

/// `mobjinfo.seestate`: State entered when `A_Look` finds a target.
pub const MI_SEESTATE: [u32; 48] = [
    59, 84, 117, 151, 184, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// `mobjinfo.reactiontime`: Tics a monster waits before its first attack.
pub const MI_REACTIONTIME: [u32; 48] = [
    0, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
];

/// `mobjinfo.painstate`: State entered when the pain roll succeeds.
pub const MI_PAINSTATE: [u32; 48] = [
    64, 95, 128, 162, 195, 195, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// `mobjinfo.painchance`: `P_Random () < painchance` triggers `painstate`.
pub const MI_PAINCHANCE: [u32; 48] = [
    255, 200, 170, 200, 180, 180, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// `mobjinfo.meleestate`: Close-range attack chain, `0` when there is none.
pub const MI_MELEESTATE: [u32; 48] = [
    0, 0, 0, 159, 192, 192, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// `mobjinfo.missilestate`: Ranged attack chain, `0` when there is none.
pub const MI_MISSILESTATE: [u32; 48] = [
    63, 92, 125, 159, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// `mobjinfo.deathstate`: Normal death chain.
pub const MI_DEATHSTATE: [u32; 48] = [
    66, 97, 130, 164, 197, 197, 215, 55, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// `mobjinfo.xdeathstate`: Gib death chain, `0` when there is none.
pub const MI_XDEATHSTATE: [u32; 48] = [
    73, 102, 135, 169, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// `mobjinfo.raisestate`: Resurrection chain (archvile); `0` on this roster.
pub const MI_RAISESTATE: [u32; 48] = [
    0, 111, 144, 177, 203, 203, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// `mobjinfo.speed`: Map units per move for a walker, 16.16 for a projectile.
pub const MI_SPEED: [u32; 48] = [
    0, 8, 8, 8, 10, 10, 0, 655360, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// `mobjinfo.radius`: Collision radius, `fixed` offset encoding.
pub const MI_RADIUS: [felt252; 48] = [
    4296015872, 4296278016, 4296278016, 4296278016, 4296933376, 4296933376, 4295622656, 4295360512,
    4296278016, 4296278016, 4296278016, 4296278016, 4296278016, 4296278016, 4296278016, 4296278016,
    4296278016, 4296278016, 4296278016, 4296278016, 4296278016, 4296278016, 4296278016, 4296278016,
    4296278016, 4296278016, 4296278016, 4296278016, 4296278016, 4296278016, 4296278016, 4296278016,
    4296278016, 4296015872, 4296015872, 4296015872, 4296015872, 4296278016, 4296278016, 4296278016,
    4296278016, 4296278016, 4296278016, 4296278016, 4296278016, 4296278016, 4296015872, 4297064448,
];

/// `mobjinfo.height`: Collision height, `fixed` offset encoding.
pub const MI_HEIGHT: [felt252; 48] = [
    4298637312, 4298637312, 4298637312, 4298637312, 4298637312, 4298637312, 4297719808, 4295491584,
    4296015872, 4296015872, 4296015872, 4296015872, 4296015872, 4296015872, 4296015872, 4296015872,
    4296015872, 4296015872, 4296015872, 4296015872, 4296015872, 4296015872, 4296015872, 4296015872,
    4296015872, 4296015872, 4296015872, 4296015872, 4296015872, 4296015872, 4296015872, 4296015872,
    4296015872, 4296015872, 4296015872, 4296015872, 4296015872, 4299423744, 4296015872, 4296015872,
    4296015872, 4296015872, 4296015872, 4296015872, 4296015872, 4296015872, 4296015872, 4296015872,
];

/// `mobjinfo.mass`: Used by `P_DamageMobj`'s thrust.
pub const MI_MASS: [u32; 48] = [
    100, 100, 100, 100, 400, 400, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100,
    100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100,
    100, 100, 100, 100, 100, 100, 100, 100, 100, 100,
];

/// `mobjinfo.damage`: Projectile damage multiplier.
pub const MI_DAMAGE: [u32; 48] = [
    0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// `mobjinfo.flags`: Raw `MF_*` word.
pub const MI_FLAGS: [u32; 48] = [
    33557510, 4194310, 4194310, 4194310, 4194310, 4456454, 524294, 67088, 528, 16, 1, 1, 8388609,
    8388609, 33554433, 1, 1, 8388609, 8388609, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2,
    768, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2,
];

/// Sorted `doomednum`s, the search key of `kind_of_doomednum`.
pub const DOOMEDNUM_KEYS: [u32; 44] = [
    5, 8, 9, 10, 12, 15, 17, 18, 19, 20, 21, 24, 26, 43, 47, 48, 54, 58, 60, 2001, 2002, 2003, 2004,
    2005, 2007, 2008, 2010, 2011, 2012, 2013, 2014, 2015, 2018, 2019, 2023, 2028, 2035, 2046, 2047,
    2048, 2049, 3001, 3002, 3004,
];

/// The kind index each `DOOMEDNUM_KEYS` entry maps to.
pub const DOOMEDNUM_KINDS: [u32; 44] = [
    14, 27, 2, 43, 44, 38, 24, 39, 42, 41, 40, 45, 46, 34, 35, 36, 47, 5, 37, 32, 28, 30, 31, 29,
    19, 25, 21, 15, 16, 17, 12, 13, 10, 11, 18, 33, 6, 22, 23, 20, 26, 3, 4, 1,
];

/// Doom's `rndtable` (`m_random.c`), the 256 bytes `prng` indexes.
pub const RNDTABLE: [u8; 256] = [
    0, 8, 109, 220, 222, 241, 149, 107, 75, 248, 254, 140, 16, 66, 74, 21, 211, 47, 80, 242, 154,
    27, 205, 128, 161, 89, 77, 36, 95, 110, 85, 48, 212, 140, 211, 249, 22, 79, 200, 50, 28, 188,
    52, 140, 202, 120, 68, 145, 62, 70, 184, 190, 91, 197, 152, 224, 149, 104, 25, 178, 252, 182,
    202, 182, 141, 197, 4, 81, 181, 242, 145, 42, 39, 227, 156, 198, 225, 193, 219, 93, 122, 175,
    249, 0, 175, 143, 70, 239, 46, 246, 163, 53, 163, 109, 168, 135, 2, 235, 25, 92, 20, 145, 138,
    77, 69, 166, 78, 176, 173, 212, 166, 113, 94, 161, 41, 50, 239, 49, 111, 164, 70, 60, 2, 37,
    171, 75, 136, 156, 11, 56, 42, 146, 138, 229, 73, 146, 77, 61, 98, 196, 135, 106, 63, 197, 195,
    86, 96, 203, 113, 101, 170, 247, 181, 113, 80, 250, 108, 7, 255, 237, 129, 226, 79, 107, 112,
    166, 103, 241, 24, 223, 239, 120, 198, 58, 60, 82, 128, 3, 184, 66, 143, 224, 145, 224, 81, 206,
    163, 45, 63, 90, 168, 114, 59, 33, 159, 95, 28, 139, 123, 98, 125, 196, 15, 70, 194, 253, 54,
    14, 109, 226, 71, 17, 161, 93, 186, 87, 244, 138, 20, 52, 123, 251, 26, 36, 17, 46, 52, 231,
    232, 76, 31, 221, 84, 37, 216, 165, 212, 106, 197, 242, 98, 43, 39, 175, 254, 145, 190, 84, 118,
    222, 187, 136, 120, 163, 236, 249,
];

/// `weaponinfo[fist]`: up, down, ready, attack, flash.
pub const WEAPON_FIST: [u32; 5] = [4, 3, 2, 5, 0];

/// `weaponinfo[pistol]`: up, down, ready, attack, flash.
pub const WEAPON_PISTOL: [u32; 5] = [12, 11, 10, 13, 17];

/// `weaponinfo[shotgun]`: up, down, ready, attack, flash.
pub const WEAPON_SHOTGUN: [u32; 5] = [20, 19, 18, 21, 30];

/// `weaponinfo[chaingun]`: up, down, ready, attack, flash.
pub const WEAPON_CHAINGUN: [u32; 5] = [34, 33, 32, 35, 38];

/// `weaponinfo[chainsaw]`: up, down, ready, attack, flash.
pub const WEAPON_CHAINSAW: [u32; 5] = [42, 41, 39, 43, 0];


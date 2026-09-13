// SPDX-License-Identifier: GPL-2.0-only
//! The planar `const` tables of `p_enemy.c`: the eight walk directions and
//! the per-kind sound roster.
//!
//! Every table is a flat `const` array read with one `Span` access (S1 §5.9:
//! a felt of a `const` array costs **1 word** of bytecode against **18** for
//! the same value in an `if`-tree, and 10 steps against 24). Nothing here is
//! generated: the direction tables are nine, eight and four numbers of
//! linuxdoom-1.10's `p_enemy.c`, and the sound roster is five columns of
//! `info.c`'s `mobjinfo` that `doom_things` deliberately drops (it carries
//! no sounds).

// ---------------------------------------------------------------------------
// Directions (`dirtype_t`)
// ---------------------------------------------------------------------------

pub const DI_EAST: u32 = 0;
pub const DI_NORTHEAST: u32 = 1;
pub const DI_NORTH: u32 = 2;
pub const DI_NORTHWEST: u32 = 3;
pub const DI_WEST: u32 = 4;
pub const DI_SOUTHWEST: u32 = 5;
pub const DI_SOUTH: u32 = 6;
pub const DI_SOUTHEAST: u32 = 7;
/// `DI_NODIR`: "not moving". Also the length of the eight-way tables, so
/// `dir < DI_NODIR` is both "is a direction" and "is in range".
pub const DI_NODIR: u32 = 8;

/// `opposite[]`: the turnaround of each direction (`DI_NODIR` maps to
/// itself).
pub const OPPOSITE: [u32; 9] = [4, 5, 6, 7, 0, 1, 2, 3, 8];

/// `diags[]`, indexed by `((deltay < 0) << 1) + (deltax > 0)`.
pub const DIAGS: [u32; 4] = [3, 1, 5, 7];

/// `xspeed[]` as raw 16.16 values. `47000` is Doom's own rounding of
/// `FRACUNIT / sqrt(2)` (46341); the discrepancy is vanilla and is kept.
pub const XSPEED: [felt252; 8] = [65536, 47000, 0, -47000, -65536, -47000, 0, 47000];

/// `yspeed[]` as raw 16.16 values.
pub const YSPEED: [felt252; 8] = [0, 47000, 65536, 47000, 0, -47000, -65536, -47000];

// ---------------------------------------------------------------------------
// Sounds
// ---------------------------------------------------------------------------

/// Sound ids. **This crate's own compact numbering**, not `sfxenum_t`'s:
/// `doom_things` carries no sounds (nothing in the proven core branches on
/// one), so the ids exist only to be reported to the renderer in a
/// [`super::MonsterEvent::Sound`]. What *is* vanilla is the grouping —
/// `posit1..3`, `bgsit1..2`, `podth1..3` and `bgdth1..2` stay contiguous,
/// because `A_Look` and `A_Scream` pick inside those runs with a `P_Random`
/// draw, and that draw is part of the replayable RNG stream.
pub const SFX_NONE: u32 = 0;
pub const SFX_POSIT1: u32 = 1;
pub const SFX_POSIT2: u32 = 2;
pub const SFX_POSIT3: u32 = 3;
pub const SFX_BGSIT1: u32 = 4;
pub const SFX_BGSIT2: u32 = 5;
pub const SFX_SGTSIT: u32 = 6;
pub const SFX_PODTH1: u32 = 7;
pub const SFX_PODTH2: u32 = 8;
pub const SFX_PODTH3: u32 = 9;
pub const SFX_BGDTH1: u32 = 10;
pub const SFX_BGDTH2: u32 = 11;
pub const SFX_SGTDTH: u32 = 12;
pub const SFX_BAREXP: u32 = 13;
pub const SFX_POPAIN: u32 = 14;
pub const SFX_DMPAIN: u32 = 15;
pub const SFX_POSACT: u32 = 16;
pub const SFX_BGACT: u32 = 17;
pub const SFX_DMACT: u32 = 18;
pub const SFX_PISTOL: u32 = 19;
pub const SFX_SHOTGN: u32 = 20;
pub const SFX_CLAW: u32 = 21;
pub const SFX_SGTATK: u32 = 22;
pub const SFX_BGATK: u32 = 23;
pub const SFX_FIRSHT: u32 = 24;
pub const SFX_SLOP: u32 = 25;

/// Number of rows in the sound columns below: `doom_things`' kinds 0..6,
/// i.e. player, zombieman, shotgun guy, imp, demon, spectre, barrel — every
/// kind that can scream on E1M1. A kind at or above this index has no
/// sounds (`SFX_NONE`), which is exactly what `mobjinfo` says of the items
/// and the puff.
pub const SOUND_KINDS: u32 = 7;

/// `mobjinfo[].seesound`.
pub const MI_SEESOUND: [u32; 7] = [0, 1, 2, 4, 6, 6, 0];

/// `mobjinfo[].attacksound`. Only `A_Chase`'s melee branch reads it (the
/// two hitscan zombies start their own sound in the attack action), so only
/// the imp's `bgatk` and the demon's `sgtatk` ever come out of it.
pub const MI_ATTACKSOUND: [u32; 7] = [0, 19, 20, 23, 22, 22, 0];

/// `mobjinfo[].painsound`. The player's `plpain` is `doom_player`'s.
pub const MI_PAINSOUND: [u32; 7] = [0, 14, 14, 14, 15, 15, 0];

/// `mobjinfo[].deathsound`.
pub const MI_DEATHSOUND: [u32; 7] = [0, 7, 8, 10, 12, 12, 13];

/// `mobjinfo[].activesound`.
pub const MI_ACTIVESOUND: [u32; 7] = [0, 16, 16, 17, 18, 18, 0];

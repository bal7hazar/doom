// SPDX-License-Identifier: GPL-2.0-only
//! Tests that need no map: the `p_enemy.c` tables, the sound roster, the
//! event record, and the pieces of the scheduler that are pure arithmetic.

use doom_physics::NO_MOBJ;
use doom_things::tables::{
    KIND_BARREL, KIND_PLAYER, KIND_POSSESSED, KIND_SERGEANT, KIND_SHADOWS, KIND_SHOTGUY, KIND_TROOP,
};
use crate::event::{
    EV_BLOOD, EV_CROSS, EV_DROP, EV_KILLED, EV_PUFF, EV_SOUND, EV_USE, EV_WAKE, event, sound,
};
use crate::tables::{
    DIAGS, DI_EAST, DI_NODIR, DI_NORTH, DI_NORTHEAST, DI_NORTHWEST, DI_SOUTH, DI_SOUTHEAST,
    DI_SOUTHWEST, DI_WEST, MI_ACTIVESOUND, MI_ATTACKSOUND, MI_DEATHSOUND, MI_PAINSOUND, MI_SEESOUND,
    OPPOSITE, SFX_BGDTH1, SFX_BGSIT1, SFX_DMACT, SFX_DMPAIN, SFX_NONE, SFX_PODTH1, SFX_PODTH2,
    SFX_POSACT, SFX_POSIT1, SFX_POSIT2, SFX_SGTDTH, SFX_SGTSIT, SOUND_KINDS, XSPEED, YSPEED,
};
use crate::think::{MAX_ACTION_CHAIN, in_window};
use crate::{LOOK_CADENCE, Noise, SIGHT_TTL, WINDOW, silence};

const FRACUNIT: felt252 = 65536;

/// `opposite[]` is an involution on the eight directions and fixes
/// `DI_NODIR`.
#[test]
fn test_opposite_is_an_involution() {
    let o = OPPOSITE.span();
    assert(o.len() == 9, 'nine entries');
    let mut d: u32 = 0;
    while d != 9 {
        let back = *o.at(*o.at(d));
        assert(back == d, 'opposite twice is identity');
        d += 1;
    }
    assert(*o.at(DI_NODIR) == DI_NODIR, 'nodir has no opposite');
    assert(*o.at(DI_EAST) == DI_WEST, 'east faces west');
    assert(*o.at(DI_NORTH) == DI_SOUTH, 'north faces south');
    assert(*o.at(DI_NORTHEAST) == DI_SOUTHWEST, 'ne faces sw');
    assert(*o.at(DI_NORTHWEST) == DI_SOUTHEAST, 'nw faces se');
}

/// `xspeed[]`/`yspeed[]` are the unit vector of each direction, with Doom's
/// own `47000` for the diagonals.
#[test]
fn test_speed_tables_match_the_directions() {
    let x = XSPEED.span();
    let y = YSPEED.span();
    assert(x.len() == 8 && y.len() == 8, 'eight directions');
    assert(*x.at(DI_EAST) == FRACUNIT && *y.at(DI_EAST) == 0, 'east');
    assert(*x.at(DI_WEST) == -FRACUNIT && *y.at(DI_WEST) == 0, 'west');
    assert(*x.at(DI_NORTH) == 0 && *y.at(DI_NORTH) == FRACUNIT, 'north');
    assert(*x.at(DI_SOUTH) == 0 && *y.at(DI_SOUTH) == -FRACUNIT, 'south');
    assert(*x.at(DI_NORTHEAST) == 47000 && *y.at(DI_NORTHEAST) == 47000, 'ne');
    assert(*x.at(DI_SOUTHWEST) == -47000 && *y.at(DI_SOUTHWEST) == -47000, 'sw');
    assert(*x.at(DI_NORTHWEST) == -47000 && *y.at(DI_NORTHWEST) == 47000, 'nw');
    assert(*x.at(DI_SOUTHEAST) == 47000 && *y.at(DI_SOUTHEAST) == -47000, 'se');
}

/// `diags[]` is indexed by `((deltay < 0) << 1) + (deltax > 0)`.
#[test]
fn test_diags_table() {
    let d = DIAGS.span();
    assert(d.len() == 4, 'four diagonals');
    assert(*d.at(0) == DI_NORTHWEST, 'north and west');
    assert(*d.at(1) == DI_NORTHEAST, 'north and east');
    assert(*d.at(2) == DI_SOUTHWEST, 'south and west');
    assert(*d.at(3) == DI_SOUTHEAST, 'south and east');
}

/// The sound roster is indexed by `doom_things`' kind, so the five monster
/// kinds must stay contiguous at 1..5 and the barrel at 6.
#[test]
fn test_sound_roster_lines_up_with_the_kinds() {
    assert(KIND_PLAYER == 0, 'player is kind 0');
    assert(KIND_POSSESSED == 1, 'zombieman is kind 1');
    assert(KIND_SHOTGUY == 2, 'shotgun guy is kind 2');
    assert(KIND_TROOP == 3, 'imp is kind 3');
    assert(KIND_SERGEANT == 4, 'demon is kind 4');
    assert(KIND_SHADOWS == 5, 'spectre is kind 5');
    assert(KIND_BARREL == 6, 'barrel is kind 6');
    assert(SOUND_KINDS == 7, 'seven rows');
    assert(MI_SEESOUND.span().len() == SOUND_KINDS, 'see column');
    assert(MI_ATTACKSOUND.span().len() == SOUND_KINDS, 'attack column');
    assert(MI_PAINSOUND.span().len() == SOUND_KINDS, 'pain column');
    assert(MI_DEATHSOUND.span().len() == SOUND_KINDS, 'death column');
    assert(MI_ACTIVESOUND.span().len() == SOUND_KINDS, 'active column');
}

/// The `mobjinfo` sounds of the five kinds, and which of them make `A_Look`
/// and `A_Scream` draw a `P_Random` (the contiguous families).
#[test]
fn test_sound_values_match_info_c() {
    let see = MI_SEESOUND.span();
    let death = MI_DEATHSOUND.span();
    let pain = MI_PAINSOUND.span();
    let active = MI_ACTIVESOUND.span();
    assert(*see.at(KIND_POSSESSED) == SFX_POSIT1, 'zombieman sees');
    assert(*see.at(KIND_SHOTGUY) == SFX_POSIT2, 'shotgun guy sees');
    assert(*see.at(KIND_TROOP) == SFX_BGSIT1, 'imp sees');
    assert(*see.at(KIND_SERGEANT) == SFX_SGTSIT, 'demon sees');
    assert(*see.at(KIND_SHADOWS) == SFX_SGTSIT, 'spectre sees like a demon');
    assert(*death.at(KIND_POSSESSED) == SFX_PODTH1, 'zombieman dies');
    assert(*death.at(KIND_SHOTGUY) == SFX_PODTH2, 'shotgun guy dies');
    assert(*death.at(KIND_TROOP) == SFX_BGDTH1, 'imp dies');
    assert(*death.at(KIND_SERGEANT) == SFX_SGTDTH, 'demon dies');
    assert(*pain.at(KIND_SERGEANT) == SFX_DMPAIN, 'demon pain');
    assert(*active.at(KIND_POSSESSED) == SFX_POSACT, 'zombieman idles');
    assert(*active.at(KIND_SERGEANT) == SFX_DMACT, 'demon idles');
    assert(*see.at(KIND_PLAYER) == SFX_NONE, 'the player has no see sound');
    assert(*pain.at(KIND_BARREL) == SFX_NONE, 'a barrel feels nothing');
}

/// The `EV_*` ids are distinct and the helpers fill the record.
#[test]
fn test_event_record() {
    let e = event(EV_CROSS, 3, 17, 1);
    assert(e.kind == EV_CROSS && e.who == 3 && e.a == 17 && e.b == 1, 'fields');
    assert(e.at.x == fixed::ZERO && e.at.y == fixed::ZERO, 'no point');
    let s = sound(4, 9);
    assert(s.kind == EV_SOUND && s.who == 4 && s.a == 9, 'sound');
    // Distinct, and none of them is zero (which would collide with a default).
    let ids = array![EV_SOUND, EV_PUFF, EV_BLOOD, EV_CROSS, EV_USE, EV_KILLED, EV_DROP, EV_WAKE]
        .span();
    let mut i: u32 = 0;
    while i != ids.len() {
        assert(*ids.at(i) == i + 1, 'ids are 1..8');
        i += 1;
    }
}

/// Silence is what a run starts from, and it is what `A_Look` must ignore.
#[test]
fn test_silence() {
    let n = silence();
    assert(n.source == NO_MOBJ, 'no noise maker');
    assert(n.sector == 0, 'no sector');
    let d: Noise = Default::default();
    assert(d.source == 0, 'the default is not silence');
}

/// The D3 constants, and the window's degenerate cases.
#[test]
fn test_scheduler_constants() {
    assert(WINDOW == 8, 'D3 processes 8 per tic');
    assert(LOOK_CADENCE == 4, 'A_Look one tic in four');
    assert(SIGHT_TTL == 8, 'the R2-A3 cache lives 8 tics');
    assert(MAX_ACTION_CHAIN == 4, 'four actions may chain');
    // An empty awake set is not divided by.
    assert(in_window(0, 0, 0), 'no one to schedule');
    // Nine monsters: the window slides by eight and wraps.
    assert(in_window(0, 0, 9), 'rank 0 on tic 0');
    assert(!in_window(8, 0, 9), 'rank 8 waits');
    assert(in_window(8, 1, 9), 'rank 8 on tic 1');
    assert(!in_window(7, 1, 9), 'rank 7 has just been served');
}

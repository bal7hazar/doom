// SPDX-License-Identifier: GPL-2.0-only
//! The render snapshot: what the real-time Worker publishes into the
//! `SharedArrayBuffer` of `client/src/sim/snapshot.ts` after every tic —
//! the player's view and HUD, every live mobj, the sectors that can differ
//! from the level JSON, and the level tally. Nothing here is hashed.
//!
//! ## Layout (version [`SNAPSHOT_VERSION`])
//!
//! Every value is a non-negative felt; `Fixed` fields are their `enc`
//! (`raw fixed_t = enc − 2^32`), angles are BAM `u32`, everything else a
//! `u32`. Word offsets:
//!
//! ```text
//!  0  version                    1  tic (leveltime after the tic)
//!  2  status                     3  n_mobjs        4  n_sectors
//!  5.. player (PLAYER_WORDS = 24):
//!     x, y, z, viewz, angle, sector, health, armor_points, armor_type,
//!     ammo[clip, shell, cell, misl], max_ammo[clip, shell, cell, misl],
//!     ready_weapon, pending_weapon, cards, damagecount, bonuscount,
//!     attackdown, playerstate
//! 29.. stats (STATS_WORDS = 7): kills, items, secrets, total_kills,
//!     total_items, total_secrets, leveltime
//! 36.. mobjs, MOBJ_WORDS = 11 each, removed slots skipped:
//!     id (list index), doomednum, state, sprite, frame, flags, x, y, z,
//!     angle, sector
//!     flags: 1 FULLBRIGHT (FF_FULLBRIGHT of the state), 2 SHADOW
//!     (MF_SHADOW), 4 CEILING (MF_SPAWNCEILING), 8 CORPSE (MF_CORPSE),
//!     16 MISSILE
//! ..   sectors, SECTOR_WORDS = 4 each: sector, floor, ceiling, light — one
//!     entry per dynamic slot of `doom_specials` (ceilings, floors, lights;
//!     a sector in two groups appears twice with identical values)
//! ```
//!
//! `frame` has the `FF_FULLBRIGHT` bit (0x8000) stripped; `sprite` is the
//! `doom_things` sprite id (`generated/sprites.json` names it), so the
//! renderer needs no state table of its own.

use doom_map::LevelMap;
use doom_physics::{MF_CORPSE, MF_MISSILE, MF_SHADOW, MF_SPAWNCEILING, Mobj, has, is_removed};
use doom_player::{AM_CELL, AM_CLIP, AM_MISL, AM_SHELL, Player, ammo_of, max_ammo};
use doom_specials::{SpecialsMap, SpecialsState, ceiling_of, floor_of, heights_of, sector_light};
use doom_things::tables::MI_DOOMEDNUM;
use segment::status_felt;
use super::level::{TOTAL_ITEMS, TOTAL_KILLS, TOTAL_SECRETS};
use super::state::GameState;

pub const SNAPSHOT_VERSION: felt252 = 1;
pub const SNAPSHOT_HEADER: u32 = 5;
pub const PLAYER_WORDS: u32 = 24;
pub const STATS_WORDS: u32 = 7;
pub const MOBJ_WORDS: u32 = 11;
pub const SECTOR_WORDS: u32 = 4;

pub const SNAP_FULLBRIGHT: u32 = 1;
pub const SNAP_SHADOW: u32 = 2;
pub const SNAP_CEILING: u32 = 4;
pub const SNAP_CORPSE: u32 = 8;
pub const SNAP_MISSILE: u32 = 16;

/// `FF_FULLBRIGHT`.
const FULLBRIGHT_BIT: u32 = 0x8000;

fn bit(b: bool) -> felt252 {
    if b {
        1
    } else {
        0
    }
}

fn push_player(ref out: Array<felt252>, p: @Player, mo: @Mobj) {
    out.append(*mo.x.enc);
    out.append(*mo.y.enc);
    out.append(*mo.z.enc);
    out.append(*p.viewz.enc);
    out.append((*mo.angle).into());
    out.append((*mo.sector).into());
    out.append((*p.health).into());
    out.append((*p.armor_points).into());
    out.append((*p.armor_type).into());
    out.append(ammo_of(p, AM_CLIP).into());
    out.append(ammo_of(p, AM_SHELL).into());
    out.append(ammo_of(p, AM_CELL).into());
    out.append(ammo_of(p, AM_MISL).into());
    out.append(max_ammo(p, AM_CLIP).into());
    out.append(max_ammo(p, AM_SHELL).into());
    out.append(max_ammo(p, AM_CELL).into());
    out.append(max_ammo(p, AM_MISL).into());
    out.append((*p.ready_weapon).into());
    out.append((*p.pending_weapon).into());
    out.append((*p.cards).into());
    out.append((*p.damagecount).into());
    out.append((*p.bonuscount).into());
    out.append(bit(*p.attackdown));
    out.append((*p.playerstate).into());
}

fn push_mobjs(
    ref out: Array<felt252>, mut mobjs: Span<Box<Mobj>>, states: fsm::StateTables,
) -> u32 {
    let sprites = states.sprite;
    let frames = states.frame;
    let doomednums = MI_DOOMEDNUM.span();
    let mut n: u32 = 0;
    let mut i: u32 = 0;
    while let Option::Some(m) = mobjs.pop_front() {
        let m = m.as_snapshot().unbox();
        if !is_removed(m) {
            let st = *m.state;
            let frame = match frames.get(st) {
                Option::Some(b) => *b.unbox(),
                Option::None => 0,
            };
            let sprite = match sprites.get(st) {
                Option::Some(b) => *b.unbox(),
                Option::None => 0,
            };
            let doomednum = match doomednums.get(*m.kind) {
                Option::Some(b) => *b.unbox(),
                Option::None => 0,
            };
            let f = *m.flags;
            let mut bits: u32 = 0;
            let mut fr = frame;
            if frame >= FULLBRIGHT_BIT {
                bits = bits + SNAP_FULLBRIGHT;
                fr = frame - FULLBRIGHT_BIT;
            }
            if has(f, MF_SHADOW) {
                bits = bits + SNAP_SHADOW;
            }
            if has(f, MF_SPAWNCEILING) {
                bits = bits + SNAP_CEILING;
            }
            if has(f, MF_CORPSE) {
                bits = bits + SNAP_CORPSE;
            }
            if has(f, MF_MISSILE) {
                bits = bits + SNAP_MISSILE;
            }
            out.append(i.into());
            out.append(doomednum.into());
            out.append(st.into());
            out.append(sprite.into());
            out.append(fr.into());
            out.append(bits.into());
            out.append(*m.x.enc);
            out.append(*m.y.enc);
            out.append(*m.z.enc);
            out.append((*m.angle).into());
            out.append((*m.sector).into());
            n = n + 1;
        }
        i = i + 1;
    }
    n
}

fn push_sectors(ref out: Array<felt252>, s: @SpecialsState, m: @LevelMap, lm: @SpecialsMap) -> u32 {
    let view = heights_of(s, m, lm);
    let mut n: u32 = 0;
    let mut groups: Array<Span<u32>> = array![
        *lm.ceil_sectors, *lm.floor_sectors, *lm.light_sectors,
    ];
    let mut gs = groups.span();
    while let Option::Some(group) = gs.pop_front() {
        let mut sectors = *group;
        while let Option::Some(sec) = sectors.pop_front() {
            let id = *sec;
            out.append(id.into());
            out.append(floor_of(@view, id).enc);
            out.append(ceiling_of(@view, id).enc);
            out.append(sector_light(s, m, lm, id).into());
            n = n + 1;
        }
    }
    n
}

/// The snapshot of `s`, as the felts of the layout above.
pub fn snapshot(s: @GameState) -> Array<felt252> {
    let m = doom_map::load(*s.level);
    let lm = doom_specials::load(*s.level);
    let mobjs = *s.mobjs;
    let p = s.player;
    let mo = match mobjs.get(*p.mo) {
        Option::Some(b) => b.unbox().unbox(),
        Option::None => doom_physics::removed_mobj(),
    };
    // The header counts need only a narrow roster scan and three lengths.
    // Write the final array directly; copying the entire body cost 24k
    // steps on E1M1's 210 slots.
    let n_mobjs = count_live(mobjs);
    let n_sectors = lm.ceil_sectors.len() + lm.floor_sectors.len() + lm.light_sectors.len();
    let mut out: Array<felt252> = array![
        SNAPSHOT_VERSION, (*s.leveltime).into(), status_felt(*s.status), n_mobjs.into(),
        n_sectors.into(),
    ];
    push_player(ref out, p, @mo);
    out.append((*p.killcount).into());
    out.append((*p.itemcount).into());
    out.append((*p.secretcount).into());
    out.append(TOTAL_KILLS.into());
    out.append(TOTAL_ITEMS.into());
    out.append(TOTAL_SECRETS.into());
    out.append((*s.leveltime).into());
    push_mobjs(ref out, mobjs, doom_things::states());
    push_sectors(ref out, s.specials, @m, @lm);
    out
}

fn count_live(mut mobjs: Span<Box<Mobj>>) -> u32 {
    let mut n = 0;
    while let Option::Some(m) = mobjs.pop_front() {
        let m = m.as_snapshot().unbox();
        if !is_removed(m) {
            n += 1;
        }
    }
    n
}

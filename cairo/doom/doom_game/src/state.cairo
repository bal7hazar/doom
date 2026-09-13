// SPDX-License-Identifier: GPL-2.0-only
//! `GameState`: the record of a run at a tic boundary, its canonical felt
//! serialization and Poseidon hash (D16), and the panic-free reader that
//! `doom_run` rebuilds a state from (R4-A2: an unreadable state is
//! `None`, never a trap).
//!
//! ## Schema (version [`VERSION`])
//!
//! `H(TAG, VERSION, n) = poseidon(TAG ‖ VERSION ‖ n ‖ fields)` with the `n`
//! fields, in this order:
//!
//! ```text
//!  0  level id                  ('E1M1')
//!  1  leveltime                 (u32, the tic about to run)
//!  2  status                    (0 RUNNING, 1 DEAD, 2 EXIT, 3 ABORT)
//!  3  noise.source              (mobj index of the last P_NoiseAlert, or NO_MOBJ)
//!  4  noise.sector
//!  5  prng.index                (P_Random cursor)
//!  6  mrng.index                (M_Random cursor — reserved, cosmetic draws)
//!  7  player                    (36 felts, `doom_player::push_felts`)
//! 43  n_mobjs
//! 44  mobjs                     (27 felts each, `doom_physics::push_felts`)
//!     n_specials                (how many felts follow)
//!     specials                  (`doom_specials::append_to`: secrets, exit,
//!                                next_light, ceilings[15], floors[5],
//!                                specials[13], n_lights, lights×8,
//!                                n_movers, movers×7, n_used, used)
//! ```
//!
//! Every felt is non-negative and below 2^72 (A7): `Fixed` fields are their
//! `enc` (< 2^33), a mobj's health is biased by 2^31, everything else is a
//! `u32`, a bit or a count. The thing grid and the materialised sector
//! heights are **derived** from the fields above and are not hashed; they
//! are rebuilt by [`from_felts`].

use doom_map::{LevelId, LevelMap, genesis as level_genesis};
use doom_monsters::Noise;
use doom_physics::{
    HEALTH_BIAS, MOBJ_FELTS, Mobj, NO_MOBJ, ThingGrid, push_felts as push_mobj, rebuild,
};
use doom_player::{PLAYER_FELTS, Player, push_felts as push_player};
use doom_specials::state::append_to as append_specials;
use doom_specials::{
    Light, LightKind, Mover, MoverKind, Phase, SpecialsMap, SpecialsState,
    fields as specials_fields,
};
use fixed::Fixed;
use prng::{Prng, from_index};
use segment::{Status, status_felt, status_from_felt};
use state_hash::{open, seal};
use super::level::materialise_heights;

/// Domain tag: the state stack's own tag for "a serialized `GameState`".
pub const TAG: felt252 = state_hash::tag::STATE;
/// Schema version. Bump it whenever a field is added, removed or reordered.
pub const VERSION: felt252 = 1;
/// Scalar fields ahead of the player record.
pub const SCALARS: u32 = 7;
/// `2^33`: the exclusive bound of a well-formed `Fixed::enc`.
const FIXED_BOUND: u64 = 0x200000000;

/// The whole game at a tic boundary.
///
/// `Destruct`, not `Copy`: the thing grid is a `Felt252Dict`. Everything
/// else is a value or a `Span`, so a state moves through `step_tic` for one
/// felt per field.
#[derive(Destruct)]
pub struct GameState {
    pub level: LevelId,
    /// The tic about to run (`leveltime`).
    pub leveltime: u32,
    /// Terminal status reached, or `Running`.
    pub status: Status,
    /// The last `P_NoiseAlert`.
    pub noise: Noise,
    /// `P_Random`.
    pub prng: Prng,
    /// `M_Random`: reserved for cosmetic draws; nothing draws from it yet.
    pub mrng: Prng,
    pub player: Player,
    pub mobjs: Span<Mobj>,
    pub specials: SpecialsState,
    /// Derived: current floor height of every sector (`Fixed::enc`).
    pub floor: Span<felt252>,
    /// Derived: current ceiling height of every sector.
    pub ceil: Span<felt252>,
    /// Derived: the blockmap's thing lists.
    pub grid: ThingGrid,
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

/// The level's id felt.
pub fn level_id(level: LevelId) -> felt252 {
    level_genesis(level).id
}

/// How many felts [`append_to`] writes.
pub fn fields(s: @GameState) -> u32 {
    SCALARS + PLAYER_FELTS + 1 + (*s.mobjs).len() * MOBJ_FELTS + 1 + specials_fields(s.specials)
}

/// Append the fields — not the header — in schema order.
pub fn append_to(s: @GameState, ref out: Array<felt252>) {
    out.append(level_id(*s.level));
    out.append((*s.leveltime).into());
    out.append(status_felt(*s.status));
    out.append((*s.noise.source).into());
    out.append((*s.noise.sector).into());
    out.append((*s.prng.index).into());
    out.append((*s.mrng.index).into());
    push_player(ref out, s.player);
    let mut mobjs = *s.mobjs;
    out.append(mobjs.len().into());
    while let Option::Some(m) = mobjs.pop_front() {
        push_mobj(ref out, m);
    }
    out.append(specials_fields(s.specials).into());
    append_specials(s.specials, ref out);
}

/// The whole record, header included.
pub fn serialize(s: @GameState) -> Array<felt252> {
    let mut out = open(TAG, VERSION, fields(s));
    append_to(s, ref out);
    out
}

/// The canonical hash: `open` + [`append_to`] + `seal`, nothing copied.
pub fn hash(s: @GameState) -> felt252 {
    seal(serialize(s).span())
}

// ---------------------------------------------------------------------------
// Deserialization (panic-free)
// ---------------------------------------------------------------------------

#[derive(Copy, Drop)]
struct Reader {
    data: Span<felt252>,
    pos: u32,
}

fn next(ref r: Reader) -> Option<felt252> {
    match r.data.get(r.pos) {
        Option::Some(b) => {
            r.pos = r.pos + 1;
            Option::Some(*b.unbox())
        },
        Option::None => Option::None,
    }
}

fn next_u32(ref r: Reader) -> Option<u32> {
    let f = next(ref r)?;
    f.try_into()
}

fn next_bool(ref r: Reader) -> Option<bool> {
    let f = next(ref r)?;
    if f == 0 {
        Option::Some(false)
    } else if f == 1 {
        Option::Some(true)
    } else {
        Option::None
    }
}

fn next_fixed(ref r: Reader) -> Option<Fixed> {
    let f = next(ref r)?;
    let u: u64 = f.try_into()?;
    if u >= FIXED_BOUND {
        return Option::None;
    }
    Option::Some(Fixed { enc: f })
}

fn read_player(ref r: Reader) -> Option<Player> {
    Option::Some(
        Player {
            mo: next_u32(ref r)?,
            playerstate: next_u32(ref r)?,
            health: next_u32(ref r)?,
            armor_points: next_u32(ref r)?,
            armor_type: next_u32(ref r)?,
            ammo_clip: next_u32(ref r)?,
            ammo_shell: next_u32(ref r)?,
            ammo_cell: next_u32(ref r)?,
            ammo_misl: next_u32(ref r)?,
            backpack: next_bool(ref r)?,
            weapons: next_u32(ref r)?,
            ready_weapon: next_u32(ref r)?,
            pending_weapon: next_u32(ref r)?,
            cards: next_u32(ref r)?,
            strength: next_u32(ref r)?,
            viewz: next_fixed(ref r)?,
            viewheight: next_fixed(ref r)?,
            deltaviewheight: next_fixed(ref r)?,
            bob: next_fixed(ref r)?,
            psp_state: next_u32(ref r)?,
            psp_tics: next_u32(ref r)?,
            psp_sx: next_fixed(ref r)?,
            psp_sy: next_fixed(ref r)?,
            flash_state: next_u32(ref r)?,
            flash_tics: next_u32(ref r)?,
            extralight: next_u32(ref r)?,
            damagecount: next_u32(ref r)?,
            bonuscount: next_u32(ref r)?,
            attacker: next_u32(ref r)?,
            attackdown: next_bool(ref r)?,
            usedown: next_bool(ref r)?,
            refire: next_u32(ref r)?,
            cheats: next_u32(ref r)?,
            killcount: next_u32(ref r)?,
            itemcount: next_u32(ref r)?,
            secretcount: next_u32(ref r)?,
        },
    )
}

fn read_mobj(ref r: Reader) -> Option<Mobj> {
    let kind = next_u32(ref r)?;
    let x = next_fixed(ref r)?;
    let y = next_fixed(ref r)?;
    let z = next_fixed(ref r)?;
    let angle = next_u32(ref r)?;
    let momx = next_fixed(ref r)?;
    let momy = next_fixed(ref r)?;
    let momz = next_fixed(ref r)?;
    let radius = next_fixed(ref r)?;
    let height = next_fixed(ref r)?;
    let flags = next_u32(ref r)?;
    let biased = next(ref r)?;
    let health: i32 = (biased - HEALTH_BIAS).try_into()?;
    Option::Some(
        Mobj {
            kind,
            x,
            y,
            z,
            angle,
            momx,
            momy,
            momz,
            radius,
            height,
            flags,
            health,
            state: next_u32(ref r)?,
            tics: next_u32(ref r)?,
            target: next_u32(ref r)?,
            reaction_time: next_u32(ref r)?,
            threshold: next_u32(ref r)?,
            move_dir: next_u32(ref r)?,
            move_count: next_u32(ref r)?,
            cell: next_u32(ref r)?,
            subsector: next_u32(ref r)?,
            sector: next_u32(ref r)?,
            floorz: next_fixed(ref r)?,
            ceilingz: next_fixed(ref r)?,
            sight_expires: next_u32(ref r)?,
            sight_sector: next_u32(ref r)?,
            sight_ok: next_bool(ref r)?,
        },
    )
}

fn read_felts(ref r: Reader, n: u32) -> Option<Span<felt252>> {
    let mut out: Array<felt252> = array![];
    let mut k: u32 = 0;
    while k != n {
        let f = next(ref r)?;
        let u: u64 = f.try_into()?;
        if u >= FIXED_BOUND {
            return Option::None;
        }
        out.append(f);
        k = k + 1;
    }
    Option::Some(out.span())
}

fn read_u32s(ref r: Reader, n: u32) -> Option<Span<u32>> {
    let mut out: Array<u32> = array![];
    let mut k: u32 = 0;
    while k != n {
        out.append(next_u32(ref r)?);
        k = k + 1;
    }
    Option::Some(out.span())
}

fn light_kind(id: felt252) -> Option<LightKind> {
    if id == 0 {
        Option::Some(LightKind::Flash)
    } else if id == 1 {
        Option::Some(LightKind::Strobe)
    } else {
        Option::None
    }
}

fn mover_kind(id: felt252) -> Option<MoverKind> {
    if id == 0 {
        Option::Some(MoverKind::DoorNormal)
    } else if id == 1 {
        Option::Some(MoverKind::DoorOpen)
    } else if id == 2 {
        Option::Some(MoverKind::DoorBlazeRaise)
    } else if id == 3 {
        Option::Some(MoverKind::PlatDownWaitUpStay)
    } else if id == 4 {
        Option::Some(MoverKind::FloorLowerToLowest)
    } else {
        Option::None
    }
}

fn phase(id: felt252) -> Option<Phase> {
    if id == 0 {
        Option::Some(Phase::Up)
    } else if id == 1 {
        Option::Some(Phase::Waiting)
    } else if id == 2 {
        Option::Some(Phase::Down)
    } else {
        Option::None
    }
}

/// The inverse of `doom_specials::append_to`, over the slot counts of `lm`.
fn read_specials(ref r: Reader, lm: @SpecialsMap) -> Option<SpecialsState> {
    let secrets = next_u32(ref r)?;
    let exit = next_bool(ref r)?;
    let next_light = next_u32(ref r)?;
    let ceilings = read_felts(ref r, (*lm.ceil_sectors).len())?;
    let floors = read_felts(ref r, (*lm.floor_sectors).len())?;
    let specials = read_u32s(ref r, (*lm.special_sectors).len())?;
    let n_lights = next_u32(ref r)?;
    if n_lights != (*lm.light_sectors).len() {
        return Option::None;
    }
    let mut lights: Array<Light> = array![];
    let mut k: u32 = 0;
    while k != n_lights {
        let kind = light_kind(next(ref r)?)?;
        lights
            .append(
                Light {
                    kind,
                    sector: next_u32(ref r)?,
                    light: next_u32(ref r)?,
                    maxlight: next_u32(ref r)?,
                    minlight: next_u32(ref r)?,
                    hi_time: next_u32(ref r)?,
                    lo_time: next_u32(ref r)?,
                    next: next_u32(ref r)?,
                },
            );
        k = k + 1;
    }
    let n_movers = next_u32(ref r)?;
    let mut movers: Array<Mover> = array![];
    k = 0;
    while k != n_movers {
        let kind = mover_kind(next(ref r)?)?;
        let ph = phase(next(ref r)?)?;
        movers
            .append(
                Mover {
                    kind,
                    phase: ph,
                    sector: next_u32(ref r)?,
                    height: next_fixed(ref r)?,
                    top: next_fixed(ref r)?,
                    bottom: next_fixed(ref r)?,
                    count: next_u32(ref r)?,
                },
            );
        k = k + 1;
    }
    let n_used = next_u32(ref r)?;
    let used = read_u32s(ref r, n_used)?;
    Option::Some(
        SpecialsState {
            ceilings,
            floors,
            specials,
            lights: lights.span(),
            next_light,
            movers: movers.span(),
            used,
            secrets,
            exit,
        },
    )
}

/// Rebuild a state from its serialization (header included), or `None` if
/// anything is malformed: wrong tag, version or length, a field out of its
/// domain, an unknown level, a player index past the list. The derived
/// fields (grid, heights) are recomputed.
pub fn from_felts(data: Span<felt252>) -> Option<GameState> {
    let mut r = Reader { data, pos: 0 };
    if next(ref r)? != TAG {
        return Option::None;
    }
    if next(ref r)? != VERSION {
        return Option::None;
    }
    let n = next_u32(ref r)?;
    if n + 3 != data.len() {
        return Option::None;
    }
    let id = next(ref r)?;
    let level = if id == level_id(LevelId::E1M1) {
        LevelId::E1M1
    } else {
        return Option::None;
    };
    let leveltime = next_u32(ref r)?;
    let status = status_from_felt(next(ref r)?)?;
    let noise = Noise { source: next_u32(ref r)?, sector: next_u32(ref r)? };
    let prng = from_index(next_u32(ref r)?);
    let mrng = from_index(next_u32(ref r)?);
    let player = read_player(ref r)?;
    let n_mobjs = next_u32(ref r)?;
    let mut mobjs: Array<Mobj> = array![];
    let mut k: u32 = 0;
    while k != n_mobjs {
        mobjs.append(read_mobj(ref r)?);
        k = k + 1;
    }
    if player.mo >= n_mobjs {
        return Option::None;
    }
    let n_specials = next_u32(ref r)?;
    let before = r.pos;
    let m: LevelMap = doom_map::load(level);
    let lm: SpecialsMap = doom_specials::load(level);
    let specials = read_specials(ref r, @lm)?;
    if r.pos - before != n_specials || r.pos != data.len() {
        return Option::None;
    }
    let (floor, ceil) = materialise_heights(@m, @lm, @specials);
    Option::Some(
        GameState {
            level,
            leveltime,
            status,
            noise,
            prng,
            mrng,
            player,
            mobjs: mobjs.span(),
            specials,
            floor,
            ceil,
            grid: rebuild(mobjs.span()),
        },
    )
}

/// `NO_MOBJ`, re-exported for the tests.
pub fn nobody() -> u32 {
    NO_MOBJ
}

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
//!     grid order                n_cells, (cell, n_members, indices...)×n_cells
//! ```
//!
//! Every felt is non-negative and below 2^72 (A7): `Fixed` fields are their
//! `enc` (< 2^33), a mobj's health is biased by 2^31, everything else is a
//! `u32`, a bit or a count. Materialised heights are derived. Cell membership
//! order is consensus state: movement changes it and pickup/trace visitation
//! observes it. Schema 2 hashes that order and restores it exactly; the
//! append-only grid journal itself is not serialized.

use core::dict::{Felt252Dict, Felt252DictEntryTrait};
use doom_map::{LevelId, LevelMap, genesis as level_genesis};
use doom_monsters::Noise;
use doom_physics::{HEALTH_BIAS, MOBJ_FELTS, Mobj, NO_MOBJ, ThingGrid, push_felts as push_mobj};
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
pub const VERSION: felt252 = 2;
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
    /// The blockmap thing lists; visitation order is committed in schema 2.
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
fn base_fields(s: @GameState) -> u32 {
    SCALARS + PLAYER_FELTS + 1 + (*s.mobjs).len() * MOBJ_FELTS + 1 + specials_fields(s.specials)
}

pub fn fields(s: @GameState) -> u32 {
    base_fields(s) + doom_physics::grid::canonical_order(s.grid, *s.mobjs).len()
}

/// Append the fields — not the header — in schema order.
pub fn append_to(s: @GameState, ref out: Array<felt252>) {
    append_base(s, ref out);
    out.append_span(doom_physics::grid::canonical_order(s.grid, *s.mobjs).span());
}

fn append_base(s: @GameState, ref out: Array<felt252>) {
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
    let order = doom_physics::grid::canonical_order(s.grid, *s.mobjs);
    let mut out = open(TAG, VERSION, base_fields(s) + order.len());
    append_base(s, ref out);
    out.append_span(order.span());
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
    if n_movers > 256 {
        return Option::None;
    }
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
    if n_used > 65535 {
        return Option::None;
    }
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
    if data.len() < 3 || n != data.len() - 3 {
        return Option::None;
    }
    let id = next(ref r)?;
    let level = if id == level_id(LevelId::E1M1) {
        LevelId::E1M1
    } else {
        return Option::None;
    };
    let leveltime = next_u32(ref r)?;
    if leveltime > segment::MAX_TIC {
        return Option::None;
    }
    let status = status_from_felt(next(ref r)?)?;
    let noise = Noise { source: next_u32(ref r)?, sector: next_u32(ref r)? };
    let pi = next_u32(ref r)?;
    let mi = next_u32(ref r)?;
    if pi > 255 || mi > 255 {
        return Option::None;
    }
    let prng = from_index(pi);
    let mrng = from_index(mi);
    let player = read_player(ref r)?;
    let n_mobjs = next_u32(ref r)?;
    if n_mobjs == 0 || n_mobjs > doom_physics::MAX_MOBJS {
        return Option::None;
    }
    let m: LevelMap = doom_map::load(level);
    if !valid_player(player, n_mobjs) {
        return Option::None;
    }
    if !valid_index(noise.source, n_mobjs)
        || (noise.source != NO_MOBJ && noise.sector >= m.s_floor.len()) {
        return Option::None;
    }
    let mut mobjs: Array<Mobj> = array![];
    let mut k: u32 = 0;
    while k != n_mobjs {
        let mo = read_mobj(ref r)?;
        if !valid_mobj(mo, m, n_mobjs) {
            return Option::None;
        }
        mobjs.append(mo);
        k = k + 1;
    }
    if player.mo >= n_mobjs {
        return Option::None;
    }
    let n_specials = next_u32(ref r)?;
    let before = r.pos;
    let lm: SpecialsMap = doom_specials::load(level);
    let specials = read_specials(ref r, @lm)?;
    if !valid_specials(specials, m, lm) {
        return Option::None;
    }
    if r.pos - before != n_specials {
        return Option::None;
    }
    let grid = read_grid(ref r, mobjs.span(), m.cell_node.len())?;
    if r.pos != data.len() {
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
            grid,
        },
    )
}

/// `NO_MOBJ`, re-exported for the tests.
pub fn nobody() -> u32 {
    NO_MOBJ
}

// Bounds used by table reads and integer arithmetic in the assembled rules.
// They are deliberately checked before rebuilding heights or running a tic.
fn valid_index(i: u32, n: u32) -> bool {
    i == NO_MOBJ || i < n
}

fn valid_player(p: Player, n: u32) -> bool {
    p.mo < n
        && p.playerstate <= 1
        && p.health <= 200
        && p.armor_points <= 200
        && p.armor_type <= 2
        && p.ammo_clip <= 400
        && p.ammo_shell <= 100
        && p.ammo_cell <= 600
        && p.ammo_misl <= 100
        && p.weapons < 32
        && p.ready_weapon < doom_player::state::NUM_WEAPONS
        && p.pending_weapon <= doom_player::WP_NOCHANGE
        && p.cards <= 1
        && p.psp_state < doom_things::num_states()
        && p.flash_state < doom_things::num_states()
        && p.damagecount <= 100
        && p.bonuscount <= 0x10000
        && valid_index(p.attacker, n)
        && p.strength <= segment::MAX_TIC
        && p.refire <= segment::MAX_TIC
        && p.killcount <= segment::MAX_TIC
        && p.itemcount <= segment::MAX_TIC
        && p.secretcount <= segment::MAX_TIC
        && p.cheats == 0
}

fn valid_mobj(mo: Mobj, m: LevelMap, n: u32) -> bool {
    if doom_physics::is_removed(@mo) {
        return mo == doom_physics::removed_mobj();
    }
    mo.kind < doom_things::num_kinds()
        && mo.state < doom_things::num_states()
        && valid_index(mo.target, n)
        && mo.sector < m.s_floor.len()
        && mo.subsector < m.ss_sector.len()
        && (mo.cell == doom_physics::NO_CELL || mo.cell < m.cell_node.len())
        && mo.move_dir <= 8
        && mo.health > -0x100000
        && mo.health < 0x100000
}

fn valid_specials(s: SpecialsState, m: LevelMap, lm: SpecialsMap) -> bool {
    let mut ls = s.lights;
    while let Option::Some(l) = ls.pop_front() {
        if *l.sector >= m.s_floor.len()
            || *l.light > 255
            || *l.maxlight > 255
            || *l.minlight > *l.maxlight
            || *l.hi_time > 0x10000
            || *l.lo_time > 0x10000
            || *l.next > segment::MAX_TIC
            + 0x10000 {
            return false;
        }
    }
    let mut ms = s.movers;
    while let Option::Some(mv) = ms.pop_front() {
        let slots = if doom_specials::state::moves_ceiling(*mv.kind) {
            lm.ceil_slot
        } else {
            lm.floor_slot
        };
        let slot = match slots.get(*mv.sector) {
            Option::Some(v) => *v.unbox(),
            Option::None => { return false; },
        };
        if slot == doom_specials::level::NO_SLOT {
            return false;
        }
    }
    s.secrets <= segment::MAX_TIC && s.next_light <= segment::MAX_TIC + 0x10000
}

/// An external order must cover each linked mobj exactly once, in its
/// declared cell; no duplicate cells, duplicate indices or omitted members.
fn read_grid(ref r: Reader, mobjs: Span<Mobj>, cells: u32) -> Option<ThingGrid> {
    let n = next_u32(ref r)?;
    if n > mobjs.len() {
        return Option::None;
    }
    let mut seen_cells: Felt252Dict<bool> = Default::default();
    let mut seen_members: Felt252Dict<bool> = Default::default();
    let mut grid = doom_physics::new_grid();
    let mut i: u32 = 0;
    let mut linked: u32 = 0;
    while i < n {
        let cell = next_u32(ref r)?;
        if cell >= cells {
            return Option::None;
        }
        let (entry, duplicate) = seen_cells.entry(cell.into());
        seen_cells = entry.finalize(true);
        if duplicate {
            return Option::None;
        }
        let count = next_u32(ref r)?;
        if count == 0 || count > mobjs.len() - linked {
            return Option::None;
        }
        let mut j: u32 = 0;
        while j < count {
            let idx = next_u32(ref r)?;
            let mo = mobjs.get(idx)?.unbox();
            if !doom_physics::in_blockmap(mo) || *mo.cell != cell {
                return Option::None;
            }
            let (entry, duplicate) = seen_members.entry(idx.into());
            seen_members = entry.finalize(true);
            if duplicate {
                return Option::None;
            }
            doom_physics::link(ref grid, cell, idx);
            linked += 1;
            j += 1;
        }
        i += 1;
    }
    let mut expected: u32 = 0;
    let mut ms = mobjs;
    while let Option::Some(m) = ms.pop_front() {
        if doom_physics::in_blockmap(m) {
            expected += 1;
        }
    }
    if linked != expected {
        return Option::None;
    }
    Option::Some(grid)
}

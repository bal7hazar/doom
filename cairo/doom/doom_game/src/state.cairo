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
}

fn next(ref r: Reader) -> Option<felt252> {
    Option::Some(*r.data.pop_front()?)
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


#[inline(never)]
fn read_player(ref r: Reader) -> Option<Box<Player>> {
    let raw = r.data.multi_pop_front::<36>()?;
    let [
        mo,
        playerstate,
        health,
        armor_points,
        armor_type,
        ammo_clip,
        ammo_shell,
        ammo_cell,
        ammo_misl,
        backpack,
        weapons,
        ready_weapon,
        pending_weapon,
        cards,
        strength,
        viewz,
        viewheight,
        deltaviewheight,
        bob,
        psp_state,
        psp_tics,
        psp_sx,
        psp_sy,
        flash_state,
        flash_tics,
        extralight,
        damagecount,
        bonuscount,
        attacker,
        attackdown,
        usedown,
        refire,
        cheats,
        killcount,
        itemcount,
        secretcount,
    ] =
        raw
        .unbox();
    Option::Some(
        BoxTrait::new(
            Player {
                mo: mo.try_into()?,
                playerstate: playerstate.try_into()?,
                health: health.try_into()?,
                armor_points: armor_points.try_into()?,
                armor_type: armor_type.try_into()?,
                ammo_clip: ammo_clip.try_into()?,
                ammo_shell: ammo_shell.try_into()?,
                ammo_cell: ammo_cell.try_into()?,
                ammo_misl: ammo_misl.try_into()?,
                backpack: bool_of(backpack)?,
                weapons: weapons.try_into()?,
                ready_weapon: ready_weapon.try_into()?,
                pending_weapon: pending_weapon.try_into()?,
                cards: cards.try_into()?,
                strength: strength.try_into()?,
                viewz: fixed_of(viewz)?,
                viewheight: fixed_of(viewheight)?,
                deltaviewheight: fixed_of(deltaviewheight)?,
                bob: fixed_of(bob)?,
                psp_state: psp_state.try_into()?,
                psp_tics: psp_tics.try_into()?,
                psp_sx: fixed_of(psp_sx)?,
                psp_sy: fixed_of(psp_sy)?,
                flash_state: flash_state.try_into()?,
                flash_tics: flash_tics.try_into()?,
                extralight: extralight.try_into()?,
                damagecount: damagecount.try_into()?,
                bonuscount: bonuscount.try_into()?,
                attacker: attacker.try_into()?,
                attackdown: bool_of(attackdown)?,
                usedown: bool_of(usedown)?,
                refire: refire.try_into()?,
                cheats: cheats.try_into()?,
                killcount: killcount.try_into()?,
                itemcount: itemcount.try_into()?,
                secretcount: secretcount.try_into()?,
            },
        ),
    )
}

/// A fixed-width record is bounds-checked once before reading its fields.
/// Field-domain checks remain identical to the scalar reader.
#[inline(never)]
fn read_mobj(ref r: Reader) -> Option<Box<Mobj>> {
    let raw = r.data.multi_pop_front::<27>()?;
    let [
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
        biased_health,
        state,
        tics,
        target,
        reaction_time,
        threshold,
        move_dir,
        move_count,
        cell,
        subsector,
        sector,
        floorz,
        ceilingz,
        sight_expires,
        sight_sector,
        sight_ok,
    ] =
        raw
        .unbox();
    Option::Some(
        BoxTrait::new(
            Mobj {
                kind: kind.try_into()?,
                x: fixed_of(x)?,
                y: fixed_of(y)?,
                z: fixed_of(z)?,
                angle: angle.try_into()?,
                momx: fixed_of(momx)?,
                momy: fixed_of(momy)?,
                momz: fixed_of(momz)?,
                radius: fixed_of(radius)?,
                height: fixed_of(height)?,
                flags: flags.try_into()?,
                health: (biased_health - HEALTH_BIAS).try_into()?,
                state: state.try_into()?,
                tics: tics.try_into()?,
                target: target.try_into()?,
                reaction_time: reaction_time.try_into()?,
                threshold: threshold.try_into()?,
                move_dir: move_dir.try_into()?,
                move_count: move_count.try_into()?,
                cell: cell.try_into()?,
                subsector: subsector.try_into()?,
                sector: sector.try_into()?,
                floorz: fixed_of(floorz)?,
                ceilingz: fixed_of(ceilingz)?,
                sight_expires: sight_expires.try_into()?,
                sight_sector: sight_sector.try_into()?,
                sight_ok: bool_of(sight_ok)?,
            },
        ),
    )
}

#[inline(always)]
fn fixed_of(f: felt252) -> Option<Fixed> {
    let u: u64 = f.try_into()?;
    if u < FIXED_BOUND {
        Option::Some(Fixed { enc: f })
    } else {
        Option::None
    }
}

#[inline(always)]
fn bool_of(f: felt252) -> Option<bool> {
    if f == 0 {
        Option::Some(false)
    } else if f == 1 {
        Option::Some(true)
    } else {
        Option::None
    }
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
#[inline(never)]
fn read_specials(ref r: Reader, lm: @SpecialsMap) -> Option<Box<SpecialsState>> {
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
        let raw = r.data.multi_pop_front::<8>()?;
        let [kind, sector, light, maxlight, minlight, hi_time, lo_time, next] = raw.unbox();
        let kind = light_kind(kind)?;
        lights
            .append(
                Light {
                    kind,
                    sector: sector.try_into()?,
                    light: light.try_into()?,
                    maxlight: maxlight.try_into()?,
                    minlight: minlight.try_into()?,
                    hi_time: hi_time.try_into()?,
                    lo_time: lo_time.try_into()?,
                    next: next.try_into()?,
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
        let raw = r.data.multi_pop_front::<7>()?;
        let [kind, ph, sector, height, top, bottom, count] = raw.unbox();
        let kind = mover_kind(kind)?;
        let ph = phase(ph)?;
        movers
            .append(
                Mover {
                    kind,
                    phase: ph,
                    sector: sector.try_into()?,
                    height: fixed_of(height)?,
                    top: fixed_of(top)?,
                    bottom: fixed_of(bottom)?,
                    count: count.try_into()?,
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
        BoxTrait::new(
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
        ),
    )
}

/// Rebuild a state from its serialization (header included), or `None` if
/// anything is malformed: wrong tag, version or length, a field out of its
/// domain, an unknown level, a player index past the list. The derived
/// heights are recomputed; the committed grid lists are restored exactly.
pub fn from_felts(data: Span<felt252>) -> Option<GameState> {
    Option::Some(read_state(data)?.unbox())
}

#[inline(never)]
fn read_state(data: Span<felt252>) -> Option<Box<GameState>> {
    let mut r = Reader { data };
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
    let player = read_player(ref r)?.unbox();
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
    let mobjs = read_mobjs(
        ref r,
        n_mobjs,
        MapBounds {
            sectors: m.s_floor.len(), subsectors: m.ss_sector.len(), cells: m.cell_node.len(),
        },
    )?;
    if player.mo >= n_mobjs {
        return Option::None;
    }
    let n_specials = next_u32(ref r)?;
    let before = r.data.len();
    let lm: SpecialsMap = doom_specials::load(level);
    let specials = read_specials(ref r, @lm)?.unbox();
    if !valid_specials(specials, m.s_floor.len(), lm.ceil_slot, lm.floor_slot) {
        return Option::None;
    }
    if before - r.data.len() != n_specials {
        return Option::None;
    }
    let grid = read_grid(ref r, mobjs, m.cell_node.len())?;
    if !r.data.is_empty() {
        return Option::None;
    }
    let (floor, ceil) = materialise_heights(@m, @lm, @specials);
    Option::Some(
        BoxTrait::new(
            GameState {
                level,
                leveltime,
                status,
                noise,
                prng,
                mrng,
                player,
                mobjs,
                specials,
                floor,
                ceil,
                grid,
            },
        ),
    )
}

/// Decode and validate the roster outside `from_felts`' wide player/level
/// live set. The helper returns only the roster and remaining input (S7 §8).
#[inline(never)]
fn read_mobjs(ref r: Reader, n_mobjs: u32, bounds: MapBounds) -> Option<Span<Mobj>> {
    let mut mobjs: Array<Mobj> = array![];
    let mut k: u32 = 0;
    while k != n_mobjs {
        let mo = read_mobj(ref r)?.unbox();
        if !valid_mobj(mo, bounds, n_mobjs) {
            return Option::None;
        }
        mobjs.append(mo);
        k = k + 1;
    }
    Option::Some(mobjs.span())
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

#[derive(Copy, Drop)]
struct MapBounds {
    sectors: u32,
    subsectors: u32,
    cells: u32,
}

fn valid_mobj(mo: Mobj, bounds: MapBounds, n: u32) -> bool {
    if doom_physics::is_removed(@mo) {
        return mo == doom_physics::removed_mobj();
    }
    mo.kind < doom_things::num_kinds()
        && mo.state < doom_things::num_states()
        && valid_index(mo.target, n)
        && mo.sector < bounds.sectors
        && mo.subsector < bounds.subsectors
        && (mo.cell == doom_physics::NO_CELL || mo.cell < bounds.cells)
        && mo.move_dir <= 8
        && mo.health > -0x100000
        && mo.health < 0x100000
}

fn valid_specials(
    s: SpecialsState, sectors: u32, ceil_slot: Span<u32>, floor_slot: Span<u32>,
) -> bool {
    let mut ls = s.lights;
    while let Option::Some(l) = ls.pop_front() {
        if *l.sector >= sectors
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
            ceil_slot
        } else {
            floor_slot
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
    let mut seen_members = (0_u64, 0_u64, 0_u64, 0_u64);
    let mut grid = doom_physics::new_grid();
    let mut i: u32 = 0;
    let mut linked: u32 = 0;
    while i < n {
        let cell = next_u32(ref r)?;
        if cell >= cells {
            return Option::None;
        }
        let count = next_u32(ref r)?;
        if count == 0 || count > mobjs.len() - linked {
            return Option::None;
        }
        let members = read_members(ref r, mobjs, cell, count, ref seen_members)?;
        if !doom_physics::grid::restore_cell(ref grid, cell, members) {
            return Option::None;
        }
        linked += count;
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

/// Validate one cell outside the outer dict/grid live set. Four 64-bit
/// words cover all MAX_MOBJS=256 indices without a second dict and squash.
fn read_members(
    ref r: Reader, mobjs: Span<Mobj>, cell: u32, count: u32, ref seen: (u64, u64, u64, u64),
) -> Option<Span<u32>> {
    let mut members = array![];
    let mut left = count;
    while left != 0 {
        let idx = next_u32(ref r)?;
        let mo = mobjs.get(idx)?.unbox();
        if !doom_physics::in_blockmap(mo) || *mo.cell != cell || mark_member(ref seen, idx) {
            return Option::None;
        }
        members.append(idx);
        left -= 1;
    }
    Option::Some(members.span())
}

const MEMBER_BITS: [u64; 64] = [
    1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072,
    262144, 524288, 1048576, 2097152, 4194304, 8388608, 16777216, 33554432, 67108864, 134217728,
    268435456, 536870912, 1073741824, 2147483648, 4294967296, 8589934592, 17179869184, 34359738368,
    68719476736, 137438953472, 274877906944, 549755813888, 1099511627776, 2199023255552,
    4398046511104, 8796093022208, 17592186044416, 35184372088832, 70368744177664, 140737488355328,
    281474976710656, 562949953421312, 1125899906842624, 2251799813685248, 4503599627370496,
    9007199254740992, 18014398509481984, 36028797018963968, 72057594037927936, 144115188075855872,
    288230376151711744, 576460752303423488, 1152921504606846976, 2305843009213693952,
    4611686018427387904, 9223372036854775808,
];

fn mark_member(ref seen: (u64, u64, u64, u64), idx: u32) -> bool {
    // `mobjs.get(idx)` succeeded and the roster is bounded by MAX_MOBJS.
    let size: NonZero<u32> = 64;
    let (group, bit) = DivRem::div_rem(idx, size);
    let mask = match MEMBER_BITS.span().get(bit) {
        Option::Some(v) => *v.unbox(),
        Option::None => { return true; },
    };
    let (a, b, c, d) = seen;
    let before = if group == 0 {
        a
    } else if group == 1 {
        b
    } else if group == 2 {
        c
    } else {
        d
    };
    let after = before | mask;
    seen =
        if group == 0 {
            (after, b, c, d)
        } else if group == 1 {
            (a, after, c, d)
        } else if group == 2 {
            (a, b, after, d)
        } else {
            (a, b, c, after)
        };
    (before & mask) != 0
}

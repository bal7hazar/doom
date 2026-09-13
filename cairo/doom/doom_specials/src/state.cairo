// SPDX-License-Identifier: GPL-2.0-only
//! The dynamic half of a level: what the specials change, and nothing else.
//!
//! # The representation, and why it is not a full array
//!
//! Doom keeps the mutable sector fields *in* `sectors[]` and hangs the
//! running thinker off `sec->specialdata`. Cairo has no in-place array
//! write, so a full 182-sector array would have to be rebuilt on every tic
//! a door moves — 182 appends, ~1 500 steps — and hashed in full every time
//! the state is sealed (D16).
//!
//! Two observations make that unnecessary:
//!
//! 1. **Which sectors can ever change is static.** It is derived from the
//!    map by `scripts/gen_specials.py`: the back sector of every manual-door
//!    line, the tagged sectors of every remote door / lift / floor line, the
//!    light-special sectors, and the secret sectors. On E1M1 that is 15
//!    ceilings, 5 floors, 9 lights and 13 clearable specials — not 182. So
//!    the dynamic state is **one small array per kind of change, indexed by
//!    a generated slot** ([`super::level`]), and a sector without a slot
//!    always reads `doom_map`. A write copies 15 felts, not 182; the whole
//!    dynamic sector state is 33 felts, ~4.5 steps each to serialize.
//! 2. **A plane that is moving right now lives in its thinker.** While a
//!    door is opening, its ceiling changes every tic; writing the slot array
//!    every tic would put the copy back in the hot path. Instead the
//!    [`Mover`] carries the live height — exactly what `sec->specialdata`
//!    points at in Doom — and the slot array is written **once**, when the
//!    thinker finishes and latches its final height. [`ceiling_of`] and
//!    [`floor_of`] therefore look at the (short, usually empty) mover list
//!    first, then the slot array, then `doom_map`.
//!
//! # The contract with `doom_physics` and `doom_game`
//!
//! **Sector heights are read from here, never from `doom_map`.**
//! `doom_map::sector_floor` / `sector_ceiling` return the level's *initial*
//! heights and are correct only for a sector no special can touch; a lift
//! parked at the bottom or a door standing open would be invisible to a
//! caller that read them directly. `P_LineOpening`, gravity, `P_CheckSight`
//! and the renderer all go through [`heights`] + [`floor_of`] /
//! [`ceiling_of`].
//!
//! [`heights`] is the hoisted form (7 spans, ~15 steps to snapshot): take it
//! **once per tic** and index it in the inner loops, the way `doom_map`'s
//! README asks for `LevelMap`.

use doom_map::LevelMap;
use fixed::Fixed;
use super::level::{NO_SLOT, SpecialsMap};

// ---------------------------------------------------------------------------
// Thinkers
// ---------------------------------------------------------------------------

/// Which of `p_doors.c` / `p_plats.c` / `p_floor.c` a [`Mover`] runs, and
/// therefore which plane it moves and how its phases chain.
///
/// The five variants are exactly the linedef specials E1M1 carries
/// (`tools/wad/REPORT-e1m1.md`); Doom keeps three separate thinker types
/// only because C dispatches through a function pointer.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub enum MoverKind {
    /// `vldoor_e::normal`: open, wait `VDOORWAIT`, close, remove.
    /// Linedef specials 1 (DR) and 26 (DR, blue key).
    DoorNormal,
    /// `vldoor_e::open`: open and stay. Linedef special 2 (W1).
    DoorOpen,
    /// `vldoor_e::blazeRaise`: same as `normal` at 4× speed, with the
    /// blazing sounds. Linedef special 117 (DR).
    DoorBlazeRaise,
    /// `plattype_e::downWaitUpStay`: lower, wait `PLATWAIT`, raise, stop.
    /// Linedef specials 62 (SR) and 88 (WR, monsters may trigger).
    PlatDownWaitUpStay,
    /// `floor_e::lowerFloorToLowest`. Linedef special 23 (S1).
    FloorLowerToLowest,
}

/// `door->direction` / `plat->status`, the three phases a plane mover can be
/// in. Doom spells them `1 / 0 / -1` and `up / waiting / down`.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub enum Phase {
    Up,
    Waiting,
    Down,
}

/// One running plane thinker — Doom's `vldoor_t`, `plat_t` and
/// `floormove_t`, which differ only in which fields they leave unused.
///
/// It *is* `sec->specialdata`: a sector with a `Mover` in
/// [`SpecialsState::movers`] is a sector `EV_DoDoor` / `EV_DoPlat` /
/// `EV_DoFloor` will refuse to start a second thinker on.
/// Doom's `vldoor_t` also carries `speed`, `topwait` and a back-pointer to
/// the sector's slot. All three are constants of the `kind` or one table
/// lookup away ([`super::thinkers::speed_of`],
/// [`super::thinkers::wait_of`], [`super::thinkers::slot_of`]), so they are
/// derived rather than stored: three felts less in the hashed state, and no
/// second place for them to be wrong. (It buys no steps — measured, the
/// per-tic cost of carrying a thinker is the array rebuild, not the field
/// count — it buys a smaller record and one source of truth.)
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Mover {
    pub kind: MoverKind,
    pub phase: Phase,
    /// The sector whose plane moves.
    pub sector: u32,
    /// The live height of the moving plane (`sec->ceilingheight` for a door,
    /// `sec->floorheight` for a lift or a floor).
    pub height: Fixed,
    /// `door->topheight` / `plat->high`: where an upward move stops.
    pub top: Fixed,
    /// `plat->low` / `floor->floordestheight`: where a downward move stops.
    /// A door closes onto its sector's *current* floor instead, read live,
    /// as `T_VerticalDoor` does.
    pub bottom: Fixed,
    /// `door->topcountdown` / `plat->count`, the running countdown.
    pub count: u32,
}

/// Which light thinker of `p_lights.c` a [`Light`] runs.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub enum LightKind {
    /// `T_LightFlash`, sector special 1: random on/off, `P_Random`-timed.
    Flash,
    /// `T_StrobeFlash`, sector special 12: `SLOWDARK` off, `STROBEBRIGHT`
    /// on, started in sync (`P_SpawnStrobeFlash(sec, SLOWDARK, 1)`).
    Strobe,
}

/// One light thinker — `lightflash_t` and `strobe_t` merged, since both are
/// "count down, then swap between two levels and reload the counter".
///
/// Spawned once by `P_SpawnSpecials` and never removed, so the list is
/// fixed-length and in slot order: `lights[light_slot[sector]]` is the
/// thinker of `sector`, and the light level it holds *is* the sector's.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Light {
    pub kind: LightKind,
    /// The sector this thinker drives.
    pub sector: u32,
    /// `sector->lightlevel`, the live value.
    pub light: u32,
    /// `flash->maxlight`, the sector's own level at spawn.
    pub maxlight: u32,
    /// `flash->minlight`, `P_FindMinSurroundingLight` at spawn (0 for a
    /// strobe whose neighbours are no darker than itself).
    pub minlight: u32,
    /// `strobe->brighttime` / `flash->maxtime`: the bright phase's reload.
    pub hi_time: u32,
    /// `strobe->darktime` / `flash->mintime`: the dark phase's reload.
    pub lo_time: u32,
    /// The **absolute tic** of the next swap. Doom counts down in
    /// `flash->count`; the two hold the same information (`count = next -
    /// tic`), and the absolute form is what lets [`super::specials_ticker`]
    /// skip all nine of E1M1's light thinkers with one comparison against
    /// [`SpecialsState::next_light`] on the tics where none is due.
    pub next: u32,
}

// ---------------------------------------------------------------------------
// The state
// ---------------------------------------------------------------------------

/// Everything the level's specials have changed since `P_SpawnSpecials`.
///
/// `Copy`, so carrying it from tic to tic when nothing moved is free: the
/// ticker returns the value it was given unchanged, and no array is rebuilt.
#[derive(Copy, Drop)]
pub struct SpecialsState {
    /// Latched `sector->ceilingheight` of the sectors a door can move, one
    /// `Fixed::enc` per `ceil_slot` slot, seeded from `doom_map`.
    pub ceilings: Span<felt252>,
    /// Latched `sector->floorheight` of the sectors a lift or a floor can
    /// move, one `Fixed::enc` per `floor_slot` slot.
    pub floors: Span<felt252>,
    /// Live `sector->special` of the sectors whose special can be cleared —
    /// the light sectors (cleared by `P_Spawn*Flash`) and the secret sectors
    /// (cleared by `P_PlayerInSpecialSector`), one per `special_slot` slot.
    pub specials: Span<u32>,
    /// The light thinkers, in `light_slot` order, never added to or removed.
    pub lights: Span<Light>,
    /// `min(lights.next)`, cached so the ticker can skip the light pass with
    /// one comparison. Derived state: `next_light == next_light_tic(lights)`
    /// is an invariant, asserted by the crate's tests.
    pub next_light: u32,
    /// The running plane thinkers — Doom's `thinkercap` list restricted to
    /// `T_VerticalDoor` / `T_PlatRaise` / `T_MoveFloor`, and the
    /// `sec->specialdata` back-pointer at the same time.
    pub movers: Span<Mover>,
    /// Linedefs whose `special` has been set to 0 because their once-only
    /// trigger has fired (W1 and S1 lines).
    pub used: Span<u32>,
    /// `player->secretcount`, incremented by `P_PlayerInSpecialSector`.
    pub secrets: u32,
    /// `G_ExitLevel` has been called: `doom_game` turns this into D14's
    /// `status = 2 (EXIT)` at the end of the tic.
    pub exit: bool,
}

// ---------------------------------------------------------------------------
// Height accessors — the contract with `doom_physics`
// ---------------------------------------------------------------------------

/// Everything [`floor_of`] and [`ceiling_of`] read, hoisted out of the
/// three snapshots so an inner loop pays one 7-field copy instead of three
/// (`doom_map::LevelMap` alone costs ~51 steps per `@` call).
#[derive(Copy, Drop)]
pub struct Heights {
    pub movers: Span<Mover>,
    pub ceil_slot: Span<u32>,
    pub floor_slot: Span<u32>,
    pub dyn_ceiling: Span<felt252>,
    pub dyn_floor: Span<felt252>,
    pub map_ceiling: Span<felt252>,
    pub map_floor: Span<felt252>,
}

/// The four level spans a [`Heights`] view needs, hoisted out of
/// `doom_map::LevelMap` (24 fields, ~51 steps a snapshot) and
/// [`SpecialsMap`] (14 fields) **once per segment**.
///
/// Passing these four instead of the two bundles is what keeps
/// [`super::specials_ticker`]'s per-tic argument shuffling at a handful of
/// steps rather than ~80: the ticker never reads anything else of the level.
#[derive(Copy, Drop)]
pub struct SectorTables {
    pub map_floor: Span<felt252>,
    pub map_ceiling: Span<felt252>,
    pub floor_slot: Span<u32>,
    pub ceil_slot: Span<u32>,
}

/// Hoist the level side of the height view. Call once per segment.
pub fn sector_tables(m: @LevelMap, lm: @SpecialsMap) -> SectorTables {
    SectorTables {
        map_floor: *m.s_floor,
        map_ceiling: *m.s_ceil,
        floor_slot: *lm.floor_slot,
        ceil_slot: *lm.ceil_slot,
    }
}

/// Take the height view once per tic; index it with [`floor_of`] /
/// [`ceiling_of`] afterwards.
pub fn heights(s: @SpecialsState, t: SectorTables) -> Heights {
    Heights {
        movers: *s.movers,
        ceil_slot: t.ceil_slot,
        floor_slot: t.floor_slot,
        dyn_ceiling: *s.ceilings,
        dyn_floor: *s.floors,
        map_ceiling: t.map_ceiling,
        map_floor: t.map_floor,
    }
}

/// [`heights`] straight from the two level bundles — the cold-path form,
/// for callers that do not already hold a [`SectorTables`].
pub fn heights_of(s: @SpecialsState, m: @LevelMap, lm: @SpecialsMap) -> Heights {
    heights(s, sector_tables(m, lm))
}

/// `true` when `kind` moves a ceiling rather than a floor.
pub fn moves_ceiling(kind: MoverKind) -> bool {
    kind == MoverKind::DoorNormal
        || kind == MoverKind::DoorOpen
        || kind == MoverKind::DoorBlazeRaise
}

/// The live height of the plane a thinker is moving in `sector`, if one is.
fn moving(movers: Span<Mover>, sector: u32, ceiling: bool) -> Option<Fixed> {
    let mut i: u32 = 0;
    let mut found: Option<Fixed> = Option::None;
    while i != movers.len() {
        let mover = *movers.at(i);
        if mover.sector == sector && moves_ceiling(mover.kind) == ceiling {
            found = Option::Some(mover.height);
            break;
        }
        i += 1;
    }
    found
}

/// `sector->floorheight`, dynamic. **This, not `doom_map::sector_floor`,
/// is what physics reads.**
pub fn floor_of(h: @Heights, sector: u32) -> Fixed {
    match moving(*h.movers, sector, false) {
        Option::Some(height) => height,
        Option::None => {
            let slot = *(*h.floor_slot).at(sector);
            if slot == NO_SLOT {
                Fixed { enc: *(*h.map_floor).at(sector) }
            } else {
                Fixed { enc: *(*h.dyn_floor).at(slot) }
            }
        },
    }
}

/// `sector->ceilingheight`, dynamic.
pub fn ceiling_of(h: @Heights, sector: u32) -> Fixed {
    match moving(*h.movers, sector, true) {
        Option::Some(height) => height,
        Option::None => {
            let slot = *(*h.ceil_slot).at(sector);
            if slot == NO_SLOT {
                Fixed { enc: *(*h.map_ceiling).at(sector) }
            } else {
                Fixed { enc: *(*h.dyn_ceiling).at(slot) }
            }
        },
    }
}

/// [`floor_of`] without the hoist — for cold paths and tests.
pub fn sector_floor(s: @SpecialsState, m: @LevelMap, lm: @SpecialsMap, sector: u32) -> Fixed {
    floor_of(@heights_of(s, m, lm), sector)
}

/// [`ceiling_of`] without the hoist — for cold paths and tests.
pub fn sector_ceiling(s: @SpecialsState, m: @LevelMap, lm: @SpecialsMap, sector: u32) -> Fixed {
    ceiling_of(@heights_of(s, m, lm), sector)
}

/// `sector->lightlevel`, dynamic: the light thinker's live value where one
/// drives the sector, `doom_map`'s otherwise.
pub fn sector_light(s: @SpecialsState, m: @LevelMap, lm: @SpecialsMap, id: u32) -> u32 {
    let slot = *(*lm.light_slot).at(id);
    if slot == NO_SLOT {
        doom_map::sector(m, id).light
    } else {
        let l = *(*s.lights).at(slot);
        l.light
    }
}

/// `sector->special`, dynamic: 0 once `P_Spawn*Flash` or a counted secret
/// has cleared it.
pub fn sector_special(s: @SpecialsState, m: @LevelMap, lm: @SpecialsMap, id: u32) -> u32 {
    let slot = *(*lm.special_slot).at(id);
    if slot == NO_SLOT {
        doom_map::sector(m, id).special
    } else {
        *(*s.specials).at(slot)
    }
}

/// `line->special`, dynamic: 0 once a once-only trigger has fired on it.
pub fn line_special(s: @SpecialsState, m: @LevelMap, line: u32) -> (u32, u32) {
    let used = *s.used;
    let mut i: u32 = 0;
    let mut spent = false;
    while i != used.len() {
        if *used.at(i) == line {
            spent = true;
            break;
        }
        i += 1;
    }
    if spent {
        (0, 0)
    } else {
        doom_map::linedef_special(m, line)
    }
}

/// `sec->specialdata != NULL`: a plane thinker already owns this sector, so
/// `EV_Do*` must skip it.
pub fn has_mover(s: @SpecialsState, sector: u32) -> bool {
    let movers = *s.movers;
    let mut i: u32 = 0;
    let mut found = false;
    while i != movers.len() {
        if (*movers.at(i)).sector == sector {
            found = true;
            break;
        }
        i += 1;
    }
    found
}

/// The index of `sector`'s thinker in [`SpecialsState::movers`], if any —
/// `EV_VerticalDoor`'s re-trigger path needs to *modify* it, not just know
/// that it exists.
pub fn mover_index(s: @SpecialsState, sector: u32) -> Option<u32> {
    let movers = *s.movers;
    let mut i: u32 = 0;
    let mut found: Option<u32> = Option::None;
    while i != movers.len() {
        if (*movers.at(i)).sector == sector {
            found = Option::Some(i);
            break;
        }
        i += 1;
    }
    found
}

// ---------------------------------------------------------------------------
// Small persistent-array writes
// ---------------------------------------------------------------------------

/// `values` with `values[index] = value`, copied in original order.
/// Two spans keep the copying loops narrow and avoid per-element indexed
/// bounds checks. Besides the small slot arrays, doom_game uses this for
/// the 182-sector derived height arrays (bench_refresh/README.md).
pub fn set_felt(values: Span<felt252>, index: u32, value: felt252) -> Span<felt252> {
    let mut out: Array<felt252> = array![];
    out.append_span(values.slice(0, index));
    out.append(value);
    let after = index + 1;
    out.append_span(values.slice(after, values.len() - after));
    out.span()
}

/// [`set_felt`] for the `u32` columns.
pub fn set_u32(values: Span<u32>, index: u32, value: u32) -> Span<u32> {
    let mut out: Array<u32> = array![];
    let mut i: u32 = 0;
    while i != index {
        out.append(*values.at(i));
        i += 1;
    }
    out.append(value);
    i += 1;
    while i != values.len() {
        out.append(*values.at(i));
        i += 1;
    }
    out.span()
}

/// `movers` with entry `index` replaced.
pub fn set_mover(movers: Span<Mover>, index: u32, value: Mover) -> Span<Mover> {
    let mut out: Array<Mover> = array![];
    let mut i: u32 = 0;
    while i != movers.len() {
        out.append(if i == index {
            value
        } else {
            *movers.at(i)
        });
        i += 1;
    }
    out.span()
}

// ---------------------------------------------------------------------------
// Serialization (D16)
// ---------------------------------------------------------------------------

/// Domain tag of the specials record. Distinct from `state_hash::tag`'s
/// three reserved values, as the state stack requires.
pub const TAG: felt252 = 'HP.SPECS';

/// Schema version of [`append_to`]. Bump it whenever a field is added,
/// removed or reordered: every hash then moves, which is the point.
pub const VERSION: felt252 = 1;

/// Felts per serialized [`Light`] and [`Mover`].
pub const LIGHT_FELTS: u32 = 8;
pub const MOVER_FELTS: u32 = 7;

/// How many felts [`append_to`] writes — declared up front so `doom_game`
/// can `state_hash::open` a buffer of the right size and never copy (D16).
pub fn fields(s: @SpecialsState) -> u32 {
    (*s.ceilings).len()
        + (*s.floors).len()
        + (*s.specials).len()
        + (*s.lights).len() * LIGHT_FELTS
        + (*s.movers).len() * MOVER_FELTS
        + (*s.used).len()
        + 6
}

fn mover_kind_id(kind: MoverKind) -> felt252 {
    match kind {
        MoverKind::DoorNormal => 0,
        MoverKind::DoorOpen => 1,
        MoverKind::DoorBlazeRaise => 2,
        MoverKind::PlatDownWaitUpStay => 3,
        MoverKind::FloorLowerToLowest => 4,
    }
}

fn phase_id(phase: Phase) -> felt252 {
    match phase {
        Phase::Up => 0,
        Phase::Waiting => 1,
        Phase::Down => 2,
    }
}

/// Append the specials' fields — not their header — to `out`, in the fixed
/// order this crate's schema pins.
///
/// Every felt is non-negative and far below 2^72 (A7): heights are
/// `Fixed::enc` (< 2^33), everything else is a small count. The three
/// variable-length lists are length-prefixed so that a reader can walk the
/// record and so that a short list followed by other fields can never be
/// confused with a longer one.
pub fn append_to(s: @SpecialsState, ref out: Array<felt252>) {
    out.append((*s.secrets).into());
    out.append(if *s.exit {
        1
    } else {
        0
    });
    out.append((*s.next_light).into());

    let ceilings = *s.ceilings;
    let mut i: u32 = 0;
    while i != ceilings.len() {
        out.append(*ceilings.at(i));
        i += 1;
    }
    let floors = *s.floors;
    i = 0;
    while i != floors.len() {
        out.append(*floors.at(i));
        i += 1;
    }
    let specials = *s.specials;
    i = 0;
    while i != specials.len() {
        out.append((*specials.at(i)).into());
        i += 1;
    }

    let lights = *s.lights;
    out.append(lights.len().into());
    i = 0;
    while i != lights.len() {
        let l = *lights.at(i);
        out.append(match l.kind {
            LightKind::Flash => 0,
            LightKind::Strobe => 1,
        });
        out.append(l.sector.into());
        out.append(l.light.into());
        out.append(l.maxlight.into());
        out.append(l.minlight.into());
        out.append(l.hi_time.into());
        out.append(l.lo_time.into());
        out.append(l.next.into());
        i += 1;
    }

    let movers = *s.movers;
    out.append(movers.len().into());
    i = 0;
    while i != movers.len() {
        let mv = *movers.at(i);
        out.append(mover_kind_id(mv.kind));
        out.append(phase_id(mv.phase));
        out.append(mv.sector.into());
        out.append(mv.height.enc);
        out.append(mv.top.enc);
        out.append(mv.bottom.enc);
        out.append(mv.count.into());
        i += 1;
    }

    let used = *s.used;
    out.append(used.len().into());
    i = 0;
    while i != used.len() {
        out.append((*used.at(i)).into());
        i += 1;
    }
}

/// The canonical hash of the dynamic specials state: `H(TAG, VERSION,
/// fields)`, built with `state_hash::open` + [`append_to`] + `seal` so that
/// nothing is ever copied (D16, 14.5 steps per felt).
pub fn hash(s: @SpecialsState) -> felt252 {
    let mut buf = state_hash::open(TAG, VERSION, fields(s));
    append_to(s, ref buf);
    state_hash::seal(buf.span())
}

/// The whole record as felts, header included — for `doom_game`, which
/// splices it into the larger `GameState` buffer.
pub fn serialize(s: @SpecialsState) -> Array<felt252> {
    let mut out = state_hash::open(TAG, VERSION, fields(s));
    append_to(s, ref out);
    out
}

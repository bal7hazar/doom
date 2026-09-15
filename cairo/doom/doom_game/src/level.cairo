// SPDX-License-Identifier: GPL-2.0-only
//! The per-tic view of the level: the two constant bundles, `doom_physics`'
//! `World` over the **current** sector heights, and the height arrays the
//! physics reads, kept in sync with `doom_specials`' thinkers.
//!
//! `doom_physics` wants flat `floor`/`ceil` spans (one `Fixed::enc` per
//! sector); `doom_specials` keeps only what moved. Rebuilding the 182-felt
//! arrays from `doom_specials::floor_of` every tic would cost ~18 000 steps,
//! so the arrays are **derived state**: while a plane moves, its sector is
//! patched with `set_felt` (one O(182) rewrite per mover per tic); when a
//! mover finishes and latches, or when a state is loaded from felts, the
//! arrays are rebuilt in full. `test_heights_track_the_specials` checks the
//! two representations agree on every tic of the scripted door run.

use doom_map::{LevelId, LevelMap, load, num_sectors};
use doom_physics::{MF_SHOOTABLE, Mobj, World, has, with_heights, world_of};
use doom_specials::state::{moves_ceiling, set_felt};
use doom_specials::{
    SectorBlocking, SectorTables, SpecialsMap, SpecialsState, ceiling_of, floor_of, heights,
    sector_tables,
};
use fixed::Fixed;

/// Level totals for the HUD (`RenderSnapshot.stats`), pinned by
/// `test_totals_match_genesis`: `MF_COUNTKILL` and `MF_COUNTITEM` things
/// spawned at skill 2, and sectors with special 9.
pub const TOTAL_KILLS: u32 = 29;
pub const TOTAL_ITEMS: u32 = 49;
pub const TOTAL_SECRETS: u32 = 4;

/// What every rule of a tic reads and never writes. Built once per tic.
#[derive(Copy, Drop)]
pub struct Ctx {
    pub m: LevelMap,
    pub lm: SpecialsMap,
    /// `doom_physics`' world over the current heights.
    pub w: World,
    pub tables: SectorTables,
}

/// The context of `level` with the given current heights.
pub fn ctx_of(level: LevelId, floor: Span<felt252>, ceil: Span<felt252>) -> Ctx {
    let m = load(level);
    let lm = doom_specials::load(level);
    let w = with_heights(world_of(@m), floor, ceil);
    Ctx { m, lm, w, tables: sector_tables(@m, @lm) }
}

/// The full floor/ceiling arrays of a specials state: `floor_of` /
/// `ceiling_of` on every sector. ~18 000 steps on E1M1 — called at genesis,
/// on load, and when a thinker finishes.
pub fn materialise_heights(
    m: @LevelMap, lm: @SpecialsMap, s: @SpecialsState,
) -> (Span<felt252>, Span<felt252>) {
    let view = heights(s, sector_tables(m, lm));
    let n = num_sectors(m);
    let mut floor: Array<felt252> = array![];
    let mut ceil: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i != n {
        floor.append(floor_of(@view, i).enc);
        ceil.append(ceiling_of(@view, i).enc);
        i = i + 1;
    }
    (floor.span(), ceil.span())
}

/// Bring the derived arrays up to date after one `specials_ticker`:
/// `movers_before` is the mover count when the ticker started. A mover that
/// disappeared latched its height into a slot, so the arrays are rebuilt;
/// otherwise every live mover's changed height is written into its sector.
/// Waiting movers usually already match the derived array. Check the current
/// value, not the phase: changed heights are applied in original mover order.
pub fn refresh_heights(
    ctx: Ctx, floor: Span<felt252>, ceil: Span<felt252>, movers_before: u32, s: @SpecialsState,
) -> (Span<felt252>, Span<felt252>) {
    let mut movers = *s.movers;
    if movers.len() < movers_before {
        return materialise_heights(@ctx.m, @ctx.lm, s);
    }
    let mut f = floor;
    let mut c = ceil;
    while let Option::Some(mv) = movers.pop_front() {
        if moves_ceiling(*mv.kind) {
            if *c.at(*mv.sector) != *mv.height.enc {
                c = set_felt(c, *mv.sector, *mv.height.enc);
            }
        } else {
            if *f.at(*mv.sector) != *mv.height.enc {
                f = set_felt(f, *mv.sector, *mv.height.enc);
            }
        }
    }
    (f, c)
}

/// The sectors whose plane is moving: the things standing in them are
/// height-clipped at the start of the next tic (`P_ChangeSector`'s
/// `P_ThingHeightClip`, see `tic.cairo`).
pub fn moving_sectors(s: @SpecialsState) -> Span<u32> {
    let mut movers = *s.movers;
    let mut out: Array<u32> = array![];
    while let Option::Some(mv) = movers.pop_front() {
        out.append(*mv.sector);
    }
    out.span()
}

/// `true` when `sector` is one of `sectors` (a span of at most a handful).
pub fn contains(mut sectors: Span<u32>, sector: u32) -> bool {
    let mut found = false;
    while let Option::Some(s) = sectors.pop_front() {
        if *s == sector {
            found = true;
            break;
        }
    }
    found
}

// ---------------------------------------------------------------------------
// P_ChangeSector's question
// ---------------------------------------------------------------------------

/// The `SectorBlocking` the specials ticker asks: is a shootable thing in
/// `sector` too tall for the planes as they would be? (`PIT_ChangeSector`:
/// corpses gib and items are crunched, neither blocks; only a live
/// `MF_SHOOTABLE` thing makes a door go back up.) One scan of the list per
/// moving plane per tic; a thing is "in" the sector when its centre is.
#[derive(Copy, Drop)]
pub struct Occupancy {
    pub mobjs: Span<Box<Mobj>>,
}

pub impl OccupancyBlocking of SectorBlocking<Occupancy> {
    fn nofit(self: @Occupancy, sector: u32, floor: Fixed, ceiling: Fixed) -> bool {
        let room = fixed::sub(ceiling, floor);
        let mut mobjs = *self.mobjs;
        let mut blocked = false;
        while let Option::Some(m) = mobjs.pop_front() {
            let m = m.as_snapshot().unbox();
            if *m.sector == sector
                && has(*m.flags, MF_SHOOTABLE)
                && *m.health > 0
                && fixed::lt(room, *m.height) {
                blocked = true;
                break;
            }
        }
        blocked
    }
}

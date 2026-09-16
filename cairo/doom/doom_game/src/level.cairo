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

use blockmap::Grid;
use doom_map::{LevelId, LevelMap, load, num_sectors, unpack_cells};
use doom_physics::maputl::{cell_at, inc, rd};
use doom_physics::{MF_SHOOTABLE, Mobj, ThingGrid, World, has, things_in, with_heights, world_of};
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
    // `get`, not `Span::at`: no panic site on the hot path (S7 section 8.1).
    // A mover's sector is always in range; the (unreachable) out-of-range
    // read yields the mover's own height, so no write follows either.
    while let Option::Some(mv) = movers.pop_front() {
        let sector = *mv.sector;
        let height = *mv.height.enc;
        let ceiling = moves_ceiling(*mv.kind);
        let heights = if ceiling {
            c
        } else {
            f
        };
        if current(heights, sector, height) != height {
            let updated = set_felt(heights, sector, height);
            if ceiling {
                c = updated;
            } else {
                f = updated;
            }
        }
    }
    (f, c)
}

/// `heights[sector]`, or `fallback` when the index is out of range.
#[inline(always)]
fn current(heights: Span<felt252>, sector: u32, fallback: felt252) -> felt252 {
    match heights.get(sector) {
        Option::Some(b) => *b.unbox(),
        Option::None => fallback,
    }
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
// P_ChangeSector's things, by blockmap cells (O3)
// ---------------------------------------------------------------------------

/// What finds the things standing in a sector without reading the roster
/// (docs/design/d2-profile.md §5.3, optimisation O3): the sector → cell
/// table of the level and the live slots the grid cannot find. Four felts,
/// built once per tic; the thing grid itself travels by `ref`.
///
/// **The set it yields is the roster's.** A linked thing whose `sector` is
/// `s` is linked in a cell of `S_CELLS[s]` (`gen_level.py`'s
/// `sector_cell_ranges` proves it for both ways the engine attributes a
/// sector, the BSP descent and the cached short step, on every state the
/// engine produces from genesis; `from_felts` also requires every linked
/// thing to be in the grid under its own cell); an unlinked live thing is
/// in `off_grid` (`Actors::off_grid`, rebuilt whenever a write may change
/// a slot's membership). The player is the one exception to the cached-step
/// argument and is tested by index wherever it matters.
#[derive(Copy, Drop)]
pub struct SectorIndex {
    /// `LevelMap::s_cells`.
    pub cells: Span<felt252>,
    /// The live slots not linked in the blockmap, ascending (on E1M1: the
    /// missiles in flight, `MF_NOBLOCKMAP` in Doom).
    pub off_grid: Span<u32>,
}

/// An index that finds nothing: for callers that clip no sector.
pub fn no_index() -> SectorIndex {
    SectorIndex { cells: array![].span(), off_grid: array![].span() }
}

/// The slots linked in the cells of `sector`'s range, cell by cell in
/// row-major order, each cell's list in its committed order. Unfiltered: a
/// thing of a neighbouring sector whose cell overlaps the range is in it
/// too, so every consumer tests `sector` again. One loop over the range
/// with two counters (S7 §8 rule 4); an empty range runs it zero times.
pub fn things_of_sector(
    ref g: ThingGrid, cells: Span<felt252>, grid: Grid, sector: u32,
) -> Span<u32> {
    let r = unpack_cells(rd(cells, sector));
    let mut out: Array<u32> = array![];
    let mut cx = r.x0;
    let mut cy = r.y0;
    while cx <= r.x1 && cy <= r.y1 {
        out.append_span(things_in(ref g, cell_at(grid, cx, cy)));
        if cx == r.x1 {
            cx = r.x0;
            cy = inc(cy);
        } else {
            cx = inc(cx);
        }
    }
    out.span()
}

// ---------------------------------------------------------------------------
// P_ChangeSector's question
// ---------------------------------------------------------------------------

/// The candidate slots of one mover's sector, gathered from the grid
/// before the specials run (a `SectorBlocking` is a snapshot and cannot
/// read the grid itself).
#[derive(Copy, Drop)]
pub struct SectorThings {
    pub sector: u32,
    pub things: Span<u32>,
}

/// The `SectorBlocking` the specials ticker asks: is a shootable thing in
/// `sector` too tall for the planes as they would be? (`PIT_ChangeSector`:
/// corpses gib and items are crunched, neither blocks; only a live
/// `MF_SHOOTABLE` thing makes a door go back up.) A thing is "in" the
/// sector when its centre is. The answer used to be one scan of the list
/// per moving plane per tic; it is now read off the blockmap cells of the
/// sector (O3, [`SectorIndex`]): the player, the slots linked in those
/// cells, and the slots off the grid — the same set, so the same answer.
///
/// The ticker asks for the sectors of the movers of the state it is given,
/// and [`occupancy_of`] gathers one list per mover of that same state, in
/// order: every sector asked is listed. (An unlisted sector holds nothing;
/// `test_occupancy_lists_every_mover_the_ticker_asks_for` pins the shape.)
#[derive(Copy, Drop)]
pub struct Occupancy {
    pub mobjs: Span<Box<Mobj>>,
    /// The player's slot, always tested (`SectorIndex`).
    pub me: u32,
    /// `SectorIndex::off_grid` of `mobjs`.
    pub off_grid: Span<u32>,
    /// One entry per mover, in mover order.
    pub sectors: Span<SectorThings>,
}

/// The occupancy of `mobjs` for the sectors of `movers`: one grid walk per
/// mover, nothing when no plane moves.
pub fn occupancy_of(
    ref g: ThingGrid,
    mobjs: Span<Box<Mobj>>,
    me: u32,
    grid: Grid,
    index: SectorIndex,
    s: @SpecialsState,
) -> Occupancy {
    let mut movers = *s.movers;
    let mut sectors: Array<SectorThings> = array![];
    while let Option::Some(mv) = movers.pop_front() {
        let sector = *mv.sector;
        sectors
            .append(
                SectorThings { sector, things: things_of_sector(ref g, index.cells, grid, sector) },
            );
    }
    Occupancy { mobjs, me, off_grid: index.off_grid, sectors: sectors.span() }
}

/// An occupancy over every slot of `mobjs` for any sector, with no grid at
/// hand: the shape of the scan, as one list of every slot. For the bench
/// and the tests.
pub fn occupancy_scan(mobjs: Span<Box<Mobj>>) -> Occupancy {
    let mut all: Array<u32> = array![];
    let mut k: u32 = 0;
    while k != mobjs.len() {
        all.append(k);
        k += 1;
    }
    Occupancy { mobjs, me: doom_physics::NO_MOBJ, off_grid: all.span(), sectors: array![].span() }
}

pub impl OccupancyBlocking of SectorBlocking<Occupancy> {
    fn nofit(self: @Occupancy, sector: u32, floor: Fixed, ceiling: Fixed) -> bool {
        let room = fixed::sub(ceiling, floor);
        let mut lists = *self.sectors;
        let mut things: Span<u32> = array![].span();
        while let Option::Some(st) = lists.pop_front() {
            if *st.sector == sector {
                things = *st.things;
                break;
            }
        }
        blocks(*self.mobjs, *self.me, sector, room)
            || blocks_among(*self.mobjs, things, sector, room)
            || blocks_among(*self.mobjs, *self.off_grid, sector, room)
    }
}

/// `PIT_ChangeSector`'s test on slot `i`; `false` past the list.
#[inline(never)]
fn blocks(mobjs: Span<Box<Mobj>>, i: u32, sector: u32, room: Fixed) -> bool {
    match mobjs.get(i) {
        Option::Some(b) => {
            let m = b.unbox();
            m.sector == sector
                && has(m.flags, MF_SHOOTABLE)
                && m.health > 0
                && fixed::lt(room, m.height)
        },
        Option::None => false,
    }
}

/// Whether any slot of `slots` blocks.
fn blocks_among(mobjs: Span<Box<Mobj>>, mut slots: Span<u32>, sector: u32, room: Fixed) -> bool {
    let mut blocked = false;
    while let Option::Some(i) = slots.pop_front() {
        if blocks(mobjs, *i, sector, room) {
            blocked = true;
            break;
        }
    }
    blocked
}

/// The scan the answer used to be: every slot of the list, in order, until
/// one blocks. The oracle the cell walk is compared with.
#[cfg(test)]
pub(crate) fn nofit_scan(mut mobjs: Span<Box<Mobj>>, sector: u32, room: Fixed) -> bool {
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

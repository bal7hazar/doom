// SPDX-License-Identifier: Apache-2.0
//! The 128-unit spatial grid Doom iterates over instead of scanning every
//! line: cell lookup, the cells covering a bounding box, a division-free
//! walk along a segment, and allocation-free iteration over a cell's packed
//! list.
//!
//! # What the crate is given
//!
//! A [`Grid`] (origin, columns, rows) and, separately, [`PackedLists`]: two
//! spans, `start` (one offset per cell, plus a final sentinel) and `items`
//! (all the cells' entries concatenated). That shape serves **both** lists
//! the engine needs:
//!
//! * the blockmap's own line lists (Doom's `blockmaplump`), and
//! * R2-A9's accelerator, "the subsectors that overlap this cell", which the
//!   WAD tool generates and `bsp` consumers use to avoid a 105-step-per-level
//!   descent.
//!
//! # Allocation-free iteration (R2-A10)
//!
//! S1 §7 measured the prototype paying "11 steps per `append` then 11 per
//! re-read, ~180 steps of pure plumbing per `P_TryMove`" for materializing a
//! cell's line list in an `Array`. This crate never builds one:
//! [`list_range`] hands back the `[from, to)` offsets so the caller can loop
//! in place, and [`for_each_in_cell`] does the same through a visitor for
//! callers that prefer the abstraction.
//!
//! **Cross-cell deduplication (R2-A5) is deliberately not implemented**: S1
//! §5.6 measured it as a pessimisation (a hitscan went from 8 781 to 40 308
//! steps, an O(n²) scan of the accumulated list). A line that belongs to two
//! visited cells is simply tested twice; if a consumer ever needs
//! once-only semantics (counting damage, say), the fix is Doom's
//! `validcount` — an epoch array indexed by line — not a search.
//!
//! # No divisions in the walk
//!
//! [`walk_next`] advances cell by cell with two cross products
//! (`|dy| * distance_to_next_vertical` against `|dx| * distance_to_next_
//! horizontal`), never a division: S1 §7 recommends visiting cells from near
//! to far and stopping at the first blocking line, which removes the need
//! for intersection fractions entirely, at the price of not ordering hits
//! *within* a cell (documented divergence from `P_PathTraverse`, which sorts
//! intercepts).

use fixed::{Fixed, felt_ge};
use geom2d::{Box, Point};

/// Side of a blockmap cell in map units (Doom's `MAPBLOCKUNITS`).
pub const CELL_UNITS: felt252 = 128;
/// Side of a cell in raw 16.16 units: `128 * 65536 = 2^23`
/// (Doom's `MAPBLOCKSIZE`, and `MAPBLOCKSHIFT = FRACBITS + 7 = 23`).
pub const CELL_RAW: felt252 = 0x800000;
const CELL_RAW_U128: u128 = 0x800000;

/// A sentinel larger than any real distance product, used by [`walk_next`]
/// for an axis the segment never crosses. Stays below `felt_ge`'s 2^71
/// domain.
const NEVER: felt252 = 0x400000000000000000;

/// The grid's geometry. `origin` is Doom's `bmaporgx`/`bmaporgy`, the
/// bottom-left corner of cell `(0, 0)`.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Grid {
    pub origin_x: Fixed,
    pub origin_y: Fixed,
    pub columns: u32,
    pub rows: u32,
}

/// An inclusive rectangle of cells.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct CellRange {
    pub x0: u32,
    pub y0: u32,
    pub x1: u32,
    pub y1: u32,
}

/// Two spans describing one list per cell: `start[c] .. start[c + 1]` are
/// the entries of cell `c` inside `items`. `start` therefore has
/// `columns * rows + 1` entries.
#[derive(Copy, Drop)]
pub struct PackedLists {
    pub start: Span<u32>,
    pub items: Span<u32>,
}

/// State of a walk along a segment. Created by [`walk_start`], advanced by
/// [`walk_next`].
#[derive(Copy, Drop)]
pub struct Walk {
    /// Current cell.
    pub cx: u32,
    pub cy: u32,
    /// Cell the segment ends in.
    pub ex: u32,
    pub ey: u32,
    /// `true` when the next horizontal step increases `cx`.
    pub east: bool,
    /// `true` when the next vertical step increases `cy`.
    pub north: bool,
    /// `|dy| * (distance to the next vertical boundary)`, and its increment.
    pub tx: felt252,
    pub dtx: felt252,
    /// `|dx| * (distance to the next horizontal boundary)`, and its increment.
    pub ty: felt252,
    pub dty: felt252,
    /// Grid extent, so that a step off the border ends the walk instead of
    /// underflowing a `u32`.
    pub columns: u32,
    pub rows: u32,
    /// Cells left to yield, the walk's hard bound.
    pub budget: u32,
    /// `false` once the walk is finished.
    pub live: bool,
}

// ---------------------------------------------------------------------------
// Cell geometry
// ---------------------------------------------------------------------------

/// Position of `v` along one axis: `(clamped cell index, 0 inside / 1 below
/// the grid / 2 above it)`.
fn axis_cell(origin: Fixed, v: Fixed, count: u32) -> (u32, u8) {
    if !felt_ge(v.enc, origin.enc) {
        return (0, 1);
    }
    let d: u128 = (v.enc - origin.enc).try_into().unwrap();
    let c: u32 = (d / CELL_RAW_U128).try_into().unwrap();
    if c >= count {
        (count - 1, 2)
    } else {
        (c, 0)
    }
}

/// The cell containing `p`, or `None` when `p` is outside the grid.
///
/// Doom computes `(x - bmaporgx) >> MAPBLOCKSHIFT` and checks the bounds at
/// every call site; this returns the bound check with the index.
///
/// **Measured: 92 steps, 18 range checks** (two comparisons, two `u128`
/// conversions and two divisions). S1 §5.6 measured ~60 steps per axis,
/// i.e. ~120 for both, and warned that these lookups are ~5 % of a tic:
/// compute the cell **once** per move and keep it in the mobj's state,
/// updating it incrementally (R2-A11) -- a mobj moves less than 30 units per
/// tic in a 128-unit cell.
pub fn cell_of(g: Grid, p: Point) -> Option<(u32, u32)> {
    let (cx, ox) = axis_cell(g.origin_x, p.x, g.columns);
    if ox != 0 {
        return Option::None;
    }
    let (cy, oy) = axis_cell(g.origin_y, p.y, g.rows);
    if oy != 0 {
        return Option::None;
    }
    Option::Some((cx, cy))
}

/// Row-major index of a cell, the index into `PackedLists::start`.
///
/// **Measured: 7 steps, 2 range checks.**
pub fn cell_index(g: Grid, cx: u32, cy: u32) -> u32 {
    cy * g.columns + cx
}

/// The (clamped) rectangle of cells a bounding box overlaps, or `None` when
/// the box misses the grid entirely.
///
/// This is the range `P_BlockLinesIterator` is called over in `P_TryMove`;
/// S1 §7 insists it be computed **once** per move and passed down, because
/// the four cell lookups it contains cost ~5 % of a tic.
///
/// **Measured: 199 steps, 36 range checks** (four `axis_cell`); with the
/// enumeration of the cells it covers, the whole `P_TryMove` preamble is
/// **272 steps**.
pub fn cells_of_box(g: Grid, b: Box) -> Option<CellRange> {
    let (x0, ox0) = axis_cell(g.origin_x, b.left, g.columns);
    let (x1, ox1) = axis_cell(g.origin_x, b.right, g.columns);
    // Entirely left of the grid, or entirely right of it.
    if ox1 == 1 || ox0 == 2 {
        return Option::None;
    }
    let (y0, oy0) = axis_cell(g.origin_y, b.bottom, g.rows);
    let (y1, oy1) = axis_cell(g.origin_y, b.top, g.rows);
    if oy1 == 1 || oy0 == 2 {
        return Option::None;
    }
    Option::Some(CellRange { x0, y0, x1, y1 })
}

/// Number of cells in a range.
///
/// **Measured: ~10 steps** (inside the 272-step preamble above).
pub fn range_len(r: CellRange) -> u32 {
    (r.x1 - r.x0 + 1) * (r.y1 - r.y0 + 1)
}

/// The `k`-th cell of a range, in row-major order: the shape a caller loops
/// over without building an array.
///
/// **Measured: ~25 steps** (one `u32` division and one modulo, inside the
/// 272-step preamble above).
pub fn range_cell(r: CellRange, k: u32) -> (u32, u32) {
    let width = r.x1 - r.x0 + 1;
    (r.x0 + k % width, r.y0 + k / width)
}

// ---------------------------------------------------------------------------
// Packed lists
// ---------------------------------------------------------------------------

/// The `[from, to)` slice of `items` holding cell `cell`'s entries.
///
/// The caller then loops `from .. to` reading [`list_item`] -- **no array is
/// ever built** (R2-A10).
///
/// **Measured: ~28 steps** (two `Span` reads).
pub fn list_range(lists: @PackedLists, cell: u32) -> (u32, u32) {
    (*(*lists.start).at(cell), *(*lists.start).at(cell + 1))
}

/// One entry of the concatenated item array.
///
/// **Measured: ~14 steps** (one `Span` read).
pub fn list_item(lists: @PackedLists, i: u32) -> u32 {
    *(*lists.items).at(i)
}

/// What [`for_each_in_cell`] does with each entry; returning `false` stops
/// the iteration (`PIT_CheckLine` returning "blocked", for instance).
pub trait ItemVisitor<T> {
    fn visit(ref self: T, item: u32) -> bool;
}

/// Show `visitor` every entry of cell `cell`, in order, stopping early if a
/// visit returns `false`. Returns `false` if it stopped early -- Doom's
/// `P_BlockLinesIterator` convention.
///
/// **Measured: 132 steps for a cell of 4 entries, against 121 for the
/// open-coded loop** over [`list_range`] / [`list_item`] -- about 3 steps
/// per entry for the abstraction. Both are provided; a hot `P_TryMove`
/// should use the open-coded form, and neither allocates (R2-A10: the
/// prototype's `Array` round trip cost ~180 steps of plumbing per move).
pub fn for_each_in_cell<T, impl V: ItemVisitor<T>, +Drop<T>>(
    lists: @PackedLists, cell: u32, ref visitor: T,
) -> bool {
    let (from, to) = list_range(lists, cell);
    let mut i = from;
    let mut ok = true;
    while i != to {
        if !visitor.visit(*(*lists.items).at(i)) {
            ok = false;
            break;
        }
        i += 1;
    }
    ok
}

// ---------------------------------------------------------------------------
// Walking a segment
// ---------------------------------------------------------------------------

/// Absolute difference of two encoded coordinates, and which way it points.
fn delta(from: Fixed, to: Fixed) -> (bool, felt252) {
    if felt_ge(to.enc, from.enc) {
        (true, to.enc - from.enc)
    } else {
        (false, from.enc - to.enc)
    }
}

/// Start a walk over the cells the segment `p1 -> p2` crosses, from `p1`.
///
/// Returns `None` when `p1` is outside the grid: like Doom, the traversal is
/// only defined for a ray leaving a point that is inside the map. `p2` is
/// clamped to the grid, so a ray aimed outside stops at the border.
///
/// **Measured: 272 steps, 45 range checks.**
pub fn walk_start(g: Grid, p1: Point, p2: Point) -> Option<Walk> {
    let (cx, cy) = match cell_of(g, p1) {
        Option::Some(c) => c,
        Option::None => { return Option::None; },
    };
    let (ex, _) = axis_cell(g.origin_x, p2.x, g.columns);
    let (ey, _) = axis_cell(g.origin_y, p2.y, g.rows);

    let (east, adx) = delta(p1.x, p2.x);
    let (north, ady) = delta(p1.y, p2.y);

    // Distance from p1 to the next vertical boundary it would cross.
    let cell_start_x = g.origin_x.enc + cx.into() * CELL_RAW;
    let to_x = if east {
        cell_start_x + CELL_RAW - p1.x.enc
    } else {
        p1.x.enc - cell_start_x
    };
    let cell_start_y = g.origin_y.enc + cy.into() * CELL_RAW;
    let to_y = if north {
        cell_start_y + CELL_RAW - p1.y.enc
    } else {
        p1.y.enc - cell_start_y
    };

    // Cross products: comparing `|dy| * to_x` with `|dx| * to_y` decides
    // which boundary comes first, without dividing.
    let (tx, dtx) = if adx == 0 {
        (NEVER, 0)
    } else {
        (ady * to_x, ady * CELL_RAW)
    };
    let (ty, dty) = if ady == 0 {
        (NEVER, 0)
    } else {
        (adx * to_y, adx * CELL_RAW)
    };

    let span_x = if ex >= cx {
        ex - cx
    } else {
        cx - ex
    };
    let span_y = if ey >= cy {
        ey - cy
    } else {
        cy - ey
    };
    Option::Some(
        Walk {
            cx,
            cy,
            ex,
            ey,
            east,
            north,
            tx,
            dtx,
            ty,
            dty,
            columns: g.columns,
            rows: g.rows,
            budget: span_x + span_y + 1,
            live: true,
        },
    )
}

/// The next cell of the walk, nearest first, or `None` when the segment's
/// last cell has been yielded.
///
/// **Measured: ~84 steps per cell yielded**, the marginal cost between a
/// 22-cell walk (2 168 steps including `walk_start`) and a 4-cell one
/// (662); the caller's `loop` and `match` are inside that figure, so the
/// function itself is ~60. A hitscan over 16 cells therefore costs ~1 600
/// steps of traversal, against the 8 781 S1 §5.6 measured for the
/// prototype's `path_traverse` -- which computed intersection fractions.
pub fn walk_next(ref w: Walk) -> Option<(u32, u32)> {
    if !w.live {
        return Option::None;
    }
    let cell = (w.cx, w.cy);
    if w.budget == 1 || (w.cx == w.ex && w.cy == w.ey) {
        w.live = false;
        return Option::Some(cell);
    }
    w.budget -= 1;
    // Step across whichever boundary is closer. A tie steps horizontally,
    // which matches the order `P_PathTraverse` produces for a diagonal ray.
    // A step that would leave the grid ends the walk: a ray aimed outside
    // stops at the border rather than walking off it (Doom instead lets
    // `P_BlockLinesIterator` reject out-of-range cells one by one).
    if felt_ge(w.ty, w.tx) {
        if w.east {
            if w.cx + 1 == w.columns {
                w.live = false;
            } else {
                w.cx += 1;
                w.tx += w.dtx;
            }
        } else {
            if w.cx == 0 {
                w.live = false;
            } else {
                w.cx -= 1;
                w.tx += w.dtx;
            }
        }
    } else {
        if w.north {
            if w.cy + 1 == w.rows {
                w.live = false;
            } else {
                w.cy += 1;
                w.ty += w.dty;
            }
        } else {
            if w.cy == 0 {
                w.live = false;
            } else {
                w.cy -= 1;
                w.ty += w.dty;
            }
        }
    }
    Option::Some(cell)
}

#[cfg(test)]
mod tests;

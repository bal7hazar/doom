// SPDX-License-Identifier: GPL-2.0-only
//! The blockmap ray: `P_PathTraverse`'s cell walk (`p_maputl.c`) and the
//! line-crossing tests every traversal shares — `P_CheckSight`, the slide
//! move's `PTR_SlideTraverse` and the hitscan's `PIT_AddLineIntercepts`.
//!
//! The walk is Doom's DDA in **trace fractions**: `fx`/`fy` are the fractions
//! (16.16, `FRACUNIT` = the whole trace) at which the ray next crosses a
//! vertical/horizontal cell boundary, incremented by a constant per cell.
//! Four `fixed::div` up front (one per axis for the first boundary, one for
//! the per-cell increment) and no division afterwards — and, unlike
//! `blockmap::walk_next`, the fraction at which each cell is *entered* comes
//! for free, which is what lets a hitscan stop walking once the nearest
//! blocking crossing found so far is closer than the next cell.
//!
//! The state is split in two (S7): the immutable [`Trace`] — endpoints,
//! hoisted terms and divline, what every line test reads — lives in a `Box`
//! and costs one felt per call and per loop iteration; the mutable
//! [`Cursor`] is the eleven felts of the DDA.

use blockmap::{CELL_RAW, Grid, cell_of};
use fixed::{BIAS, FRACUNIT_RAW, Fixed, felt_ge_narrow};
use geom2d::{
    Box as BBox, DivLine, HalfPlane, Point, SIDE_BACK, SIDE_CROSS, SIDE_FRONT, divline_side, hoist,
    intercept_fraction, point_side,
};
use super::maputl::{TraceBox, cell_at, dec, delta_signs, inc, line_box, line_divline, trace_box};

/// `2^62`: the offset that turns the sign test of a signed felt product into
/// one `felt_ge_narrow` (the product of two raw deltas is below 2^62 in
/// magnitude for any Doom map: coordinates are below 2^15 units, i.e. 2^31
/// raw, and E1M1's are far smaller).
const SIGN_BIAS: felt252 = 0x4000000000000000;

/// Doom's `count < 64` bound on the cells a traversal visits.
const MAX_CELLS: u32 = 64;
/// `MAXINT` as a `Fixed` raw: "this axis is never crossed".
const NEVER: felt252 = 0x7FFFFFFF;

/// The trace itself: its endpoints, their hoisted predicate terms and its
/// divline. Immutable for the whole walk, hence boxed.
#[derive(Copy, Drop)]
pub struct Trace {
    pub p1: Point,
    pub p2: Point,
    /// `geom2d::hoist` of both endpoints, for the side tests against lines.
    pub rhs1: felt252,
    pub rhs2: felt252,
    /// The trace as a divline: the side tests of line endpoints
    /// ([`trace_side`]) and `intercept_fraction`.
    pub dl: DivLine,
    /// Its unit-rounded bounding box, for the early reject of every line
    /// ([`maputl::line_box_misses`]).
    pub tb: TraceBox,
}

/// The DDA cursor of a walk.
#[derive(Copy, Drop)]
pub struct Cursor {
    /// Current cell.
    pub cx: u32,
    pub cy: u32,
    /// Direction, per axis: 0 none, 1 increasing, 2 decreasing.
    pub stepx: u8,
    pub stepy: u8,
    /// Fraction of the next boundary crossing per axis and its increment.
    pub fx: Fixed,
    pub fy: Fixed,
    pub dfx: Fixed,
    pub dfy: Fixed,
    /// Fraction at which the current cell was entered (0 for the first).
    pub entry: Fixed,
    pub budget: u32,
    pub live: bool,
}

/// The boxed trace `p1 -> p2`.
#[inline(never)]
pub fn trace_of(p1: Point, p2: Point) -> Box<Trace> {
    BoxTrait::new(
        Trace {
            p1,
            p2,
            rhs1: hoist(p1),
            rhs2: hoist(p2),
            dl: DivLine {
                x: p1.x, y: p1.y, dx: fixed::sub(p2.x, p1.x), dy: fixed::sub(p2.y, p1.y),
            },
            tb: trace_box(p1, p2),
        },
    )
}

/// Per-axis DDA setup: `(step, first boundary fraction, per-cell increment)`.
fn axis(origin: Fixed, cell: u32, from: Fixed, to: Fixed) -> (u8, Fixed, Fixed) {
    let d = fixed::sub(to, from);
    if d.enc == BIAS {
        return (0, Fixed { enc: NEVER + BIAS }, fixed::ZERO);
    }
    let cell_start: felt252 = origin.enc + cell.into() * CELL_RAW;
    let (step, dist, ad) = if fixed::is_neg(d) {
        (2, Fixed { enc: from.enc - cell_start + BIAS }, fixed::neg(d))
    } else {
        (1, Fixed { enc: cell_start + CELL_RAW - from.enc + BIAS }, d)
    };
    (step, fixed::div(dist, ad), fixed::div(Fixed { enc: CELL_RAW + BIAS }, ad))
}

/// Start a walk from `p1` toward `p2`. `None` when `p1` is off the blockmap
/// (Doom would walk empty cells until the ray enters; nothing on E1M1 can
/// trace from the void).
///
/// **Measured ~450 steps**: `cell_of`, four divisions.
pub fn ray_start(g: Grid, p1: Point, p2: Point) -> Option<Cursor> {
    let (cx, cy) = match cell_of(g, p1) {
        Option::Some(c) => c,
        Option::None => { return Option::None; },
    };
    let (stepx, fx, dfx) = axis(g.origin_x, cx, p1.x, p2.x);
    let (stepy, fy, dfy) = axis(g.origin_y, cy, p1.y, p2.y);
    Option::Some(
        Cursor {
            cx,
            cy,
            stepx,
            stepy,
            fx,
            fy,
            dfx,
            dfy,
            entry: fixed::ZERO,
            budget: MAX_CELLS,
            live: true,
        },
    )
}

/// The current cell's index, or `None` once the walk is over.
#[inline(always)]
pub fn ray_cell(c: Cursor, g: Grid) -> Option<u32> {
    if c.live {
        Option::Some(cell_at(g, c.cx, c.cy))
    } else {
        Option::None
    }
}

/// Fraction at which the walk would enter the *next* cell (the smaller of
/// the two boundary fractions).
#[inline(always)]
pub fn ray_next_entry(c: Cursor) -> Fixed {
    if felt_ge_narrow(c.fy.enc, c.fx.enc) {
        c.fx
    } else {
        c.fy
    }
}

/// Step to the next cell. The walk ends when the next boundary lies past the
/// end of the trace (`entry >= FRACUNIT`), when the step would leave the
/// grid, or after [`MAX_CELLS`].
pub fn ray_advance(ref r: Cursor, columns: u32, rows: u32) {
    if !r.live {
        return;
    }
    r.budget = dec(r.budget);
    if r.budget == 0 || (r.stepx == 0 && r.stepy == 0) {
        r.live = false;
        return;
    }
    if felt_ge_narrow(r.fy.enc, r.fx.enc) {
        // Cross a vertical boundary (ties step in x, like P_PathTraverse).
        r.entry = r.fx;
        r.fx = fixed::add(r.fx, r.dfx);
        if r.stepx == 1 {
            if inc(r.cx) == columns {
                r.live = false;
                return;
            }
            r.cx = inc(r.cx);
        } else {
            if r.cx == 0 {
                r.live = false;
                return;
            }
            r.cx = dec(r.cx);
        }
    } else {
        r.entry = r.fy;
        r.fy = fixed::add(r.fy, r.dfy);
        if r.stepy == 1 {
            if inc(r.cy) == rows {
                r.live = false;
                return;
            }
            r.cy = inc(r.cy);
        } else {
            if r.cy == 0 {
                r.live = false;
                return;
            }
            r.cy = dec(r.cy);
        }
    }
    if felt_ge_narrow(r.entry.enc, BIAS + FRACUNIT_RAW) {
        r.live = false;
    }
}

/// `P_PointOnDivlineSide` on the trace, **exact** on the raw deltas (a
/// runtime trace has fractional endpoints, so `geom2d::half_plane`'s
/// integer-unit deltas would bend a short trace): the sign of
/// `dx * (py - y1) - dy * (px - x1)` as a felt, read off one comparison
/// against [`SIGN_BIAS`]. Returns the signed cross product's sign as
/// `SIDE_FRONT` (negative), `SIDE_BACK` (positive) or `SIDE_CROSS` (zero).
pub fn trace_side3(dl: DivLine, p: Point) -> u8 {
    let cross = (dl.dx.enc - BIAS) * (p.y.enc - dl.y.enc)
        - (dl.dy.enc - BIAS) * (p.x.enc - dl.x.enc);
    if cross == 0 {
        SIDE_CROSS
    } else if felt_ge_narrow(cross + SIGN_BIAS, SIGN_BIAS) {
        SIDE_BACK
    } else {
        SIDE_FRONT
    }
}

/// The two-valued form (a point on the trace is on the back side, as in
/// `P_PointOnLineSide`).
#[inline(always)]
pub fn trace_side(dl: DivLine, p: Point) -> u8 {
    let cross = (dl.dx.enc - BIAS) * (p.y.enc - dl.y.enc)
        - (dl.dy.enc - BIAS) * (p.x.enc - dl.x.enc);
    if felt_ge_narrow(cross + SIGN_BIAS, SIGN_BIAS) {
        SIDE_BACK
    } else {
        SIDE_FRONT
    }
}

/// The two endpoints of a line from its predicate and its box (`line_v1`
/// and its opposite corner).
pub fn line_ends(hp: HalfPlane, b: BBox) -> (Point, Point) {
    let (neg_x, neg_y) = delta_signs(hp);
    let (x1, x2) = if neg_x {
        (b.right, b.left)
    } else {
        (b.left, b.right)
    };
    let (y1, y2) = if neg_y {
        (b.top, b.bottom)
    } else {
        (b.bottom, b.top)
    };
    (Point { x: x1, y: y1 }, Point { x: x2, y: y2 })
}

/// Does the trace cross the *segment* of line `hp` (`PIT_AddLineIntercepts`
/// and `PTR_SlideTraverse`'s test)?
///
/// Two tests, cheapest first (S1 §7's rule about average rejection cost):
/// the trace's endpoints must lie on different sides of the line
/// (`P_PointOnLineSide` twice, on the hoisted terms), then the line's two
/// endpoints must lie on different sides of the trace ([`trace_side`]
/// twice). The line's `L_BOX` felt is decoded only when the first test
/// passes, and the decoded box is returned for the intercept computation.
pub fn crosses(tr: Box<Trace>, hp: HalfPlane, packed_box: felt252) -> Option<BBox> {
    let t = tr.unbox();
    if point_side(hp, t.p1, t.rhs1) == point_side(hp, t.p2, t.rhs2) {
        return Option::None;
    }
    let lbox = line_box(packed_box);
    let (v1, v2) = line_ends(hp, lbox);
    if trace_side(t.dl, v1) == trace_side(t.dl, v2) {
        return Option::None;
    }
    Option::Some(lbox)
}

/// The same test with `P_DivlineSide`'s three-valued sides, as
/// `P_CrossSubsector` does it for `P_CheckSight`: a point exactly on a line
/// counts as crossed when the other one is off it.
pub fn crosses_sight(tr: Box<Trace>, hp: HalfPlane, packed_box: felt252) -> Option<BBox> {
    let t = tr.unbox();
    if divline_side(hp, t.p1, t.rhs1) == divline_side(hp, t.p2, t.rhs2) {
        return Option::None;
    }
    let lbox = line_box(packed_box);
    let (v1, v2) = line_ends(hp, lbox);
    if trace_side3(t.dl, v1) == trace_side3(t.dl, v2) {
        return Option::None;
    }
    Option::Some(lbox)
}

/// `P_InterceptVector`: the fraction along the trace of its crossing with
/// the line (one `fixed::div`).
pub fn crossing_fraction(tr: Box<Trace>, hp: HalfPlane, lbox: BBox) -> Fixed {
    intercept_fraction(tr.unbox().dl, line_divline(hp, lbox))
}

/// The point at `frac` along the trace.
pub fn point_at(tr: Box<Trace>, frac: Fixed) -> Point {
    let t = tr.unbox();
    Point {
        x: fixed::add(t.p1.x, fixed::mul(t.dl.dx, frac)),
        y: fixed::add(t.p1.y, fixed::mul(t.dl.dy, frac)),
    }
}

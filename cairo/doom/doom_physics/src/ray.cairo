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

use blockmap::{CELL_RAW, Grid, cell_index, cell_of};
use fixed::{BIAS, FRACUNIT_RAW, Fixed, felt_ge};
use geom2d::{
    Box, DivLine, HalfPlane, Point, SIDE_BACK, SIDE_CROSS, SIDE_FRONT, divline_side, hoist,
    intercept_fraction, point_side,
};
use super::maputl::{delta_signs, line_divline};

/// `2^70`: the offset that turns the sign test of a signed felt product into
/// one `felt_ge` (the product of two raw deltas is below 2^56 in magnitude).
const SIGN_BIAS: felt252 = 0x400000000000000000;

/// Doom's `count < 64` bound on the cells a traversal visits.
const MAX_CELLS: u32 = 64;
/// `MAXINT` as a `Fixed` raw: "this axis is never crossed".
const NEVER: felt252 = 0x7FFFFFFF;

/// The state of a ray walk: the trace, its stored predicate and divline
/// (hoisted once for every line test), and the DDA cursor.
#[derive(Copy, Drop)]
pub struct Ray {
    pub p1: Point,
    pub p2: Point,
    /// `geom2d::hoist` of both endpoints, for the side tests against lines.
    pub rhs1: felt252,
    pub rhs2: felt252,
    /// The trace as a divline: the side tests of line endpoints
    /// ([`trace_side`]) and `intercept_fraction`.
    pub dl: DivLine,
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
    pub columns: u32,
    pub rows: u32,
    pub budget: u32,
    pub live: bool,
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
/// **Measured ~450 steps**: `cell_of`, two hoists, four divisions.
pub fn ray_start(g: Grid, p1: Point, p2: Point) -> Option<Ray> {
    let (cx, cy) = match cell_of(g, p1) {
        Option::Some(c) => c,
        Option::None => { return Option::None; },
    };
    let (stepx, fx, dfx) = axis(g.origin_x, cx, p1.x, p2.x);
    let (stepy, fy, dfy) = axis(g.origin_y, cy, p1.y, p2.y);
    Option::Some(
        Ray {
            p1,
            p2,
            rhs1: hoist(p1),
            rhs2: hoist(p2),
            dl: DivLine {
                x: p1.x, y: p1.y, dx: fixed::sub(p2.x, p1.x), dy: fixed::sub(p2.y, p1.y),
            },
            cx,
            cy,
            stepx,
            stepy,
            fx,
            fy,
            dfx,
            dfy,
            entry: fixed::ZERO,
            columns: g.columns,
            rows: g.rows,
            budget: MAX_CELLS,
            live: true,
        },
    )
}

/// The current cell's index, or `None` once the walk is over.
#[inline(always)]
pub fn ray_cell(r: @Ray, g: Grid) -> Option<u32> {
    if *r.live {
        Option::Some(cell_index(g, *r.cx, *r.cy))
    } else {
        Option::None
    }
}

/// Fraction at which the walk would enter the *next* cell (the smaller of
/// the two boundary fractions).
#[inline(always)]
pub fn ray_next_entry(r: @Ray) -> Fixed {
    if felt_ge(*r.fy.enc, *r.fx.enc) {
        *r.fx
    } else {
        *r.fy
    }
}

/// Step to the next cell. The walk ends when the next boundary lies past the
/// end of the trace (`entry >= FRACUNIT`), when the step would leave the
/// grid, or after [`MAX_CELLS`].
pub fn ray_advance(ref r: Ray) {
    if !r.live {
        return;
    }
    r.budget -= 1;
    if r.budget == 0 || (r.stepx == 0 && r.stepy == 0) {
        r.live = false;
        return;
    }
    if felt_ge(r.fy.enc, r.fx.enc) {
        // Cross a vertical boundary (ties step in x, like P_PathTraverse).
        r.entry = r.fx;
        r.fx = fixed::add(r.fx, r.dfx);
        if r.stepx == 1 {
            if r.cx + 1 == r.columns {
                r.live = false;
                return;
            }
            r.cx += 1;
        } else {
            if r.cx == 0 {
                r.live = false;
                return;
            }
            r.cx -= 1;
        }
    } else {
        r.entry = r.fy;
        r.fy = fixed::add(r.fy, r.dfy);
        if r.stepy == 1 {
            if r.cy + 1 == r.rows {
                r.live = false;
                return;
            }
            r.cy += 1;
        } else {
            if r.cy == 0 {
                r.live = false;
                return;
            }
            r.cy -= 1;
        }
    }
    if felt_ge(r.entry.enc, BIAS + FRACUNIT_RAW) {
        r.live = false;
    }
}

/// `P_PointOnDivlineSide` on the trace, **exact** on the raw deltas (a
/// runtime trace has fractional endpoints, so `geom2d::half_plane`'s
/// integer-unit deltas would bend a short trace): the sign of
/// `dx * (py - y1) - dy * (px - x1)` as a felt, read off one `felt_ge`
/// against [`SIGN_BIAS`]. Returns the signed cross product's sign as
/// `SIDE_FRONT` (negative), `SIDE_BACK` (positive) or `SIDE_CROSS` (zero).
pub fn trace_side3(dl: @DivLine, p: Point) -> u8 {
    let cross = (*dl.dx.enc - BIAS) * (p.y.enc - *dl.y.enc)
        - (*dl.dy.enc - BIAS) * (p.x.enc - *dl.x.enc);
    if cross == 0 {
        SIDE_CROSS
    } else if felt_ge(cross + SIGN_BIAS, SIGN_BIAS) {
        SIDE_BACK
    } else {
        SIDE_FRONT
    }
}

/// The two-valued form (a point on the trace is on the back side, as in
/// `P_PointOnLineSide`).
#[inline(always)]
pub fn trace_side(dl: @DivLine, p: Point) -> u8 {
    let cross = (*dl.dx.enc - BIAS) * (p.y.enc - *dl.y.enc)
        - (*dl.dy.enc - BIAS) * (p.x.enc - *dl.x.enc);
    if felt_ge(cross + SIGN_BIAS, SIGN_BIAS) {
        SIDE_BACK
    } else {
        SIDE_FRONT
    }
}

/// The two endpoints of a line from its predicate and its box (`line_v1`
/// and its opposite corner).
pub fn line_ends(hp: HalfPlane, b: Box) -> (Point, Point) {
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
/// twice). The line's `L_BOX` felt is read and decoded only when the first
/// test passes, and the decoded box is returned for the intercept
/// computation.
pub fn crosses(r: @Ray, hp: HalfPlane, l_box: Span<felt252>, line: u32) -> Option<Box> {
    if point_side(hp, *r.p1, *r.rhs1) == point_side(hp, *r.p2, *r.rhs2) {
        return Option::None;
    }
    let lbox = doom_map::unpack_box(*l_box.at(line));
    let (v1, v2) = line_ends(hp, lbox);
    if trace_side(r.dl, v1) == trace_side(r.dl, v2) {
        return Option::None;
    }
    Option::Some(lbox)
}

/// The same test with `P_DivlineSide`'s three-valued sides, as
/// `P_CrossSubsector` does it for `P_CheckSight`: a point exactly on a line
/// counts as crossed when the other one is off it.
pub fn crosses_sight(r: @Ray, hp: HalfPlane, l_box: Span<felt252>, line: u32) -> Option<Box> {
    if divline_side(hp, *r.p1, *r.rhs1) == divline_side(hp, *r.p2, *r.rhs2) {
        return Option::None;
    }
    let lbox = doom_map::unpack_box(*l_box.at(line));
    let (v1, v2) = line_ends(hp, lbox);
    if trace_side3(r.dl, v1) == trace_side3(r.dl, v2) {
        return Option::None;
    }
    Option::Some(lbox)
}

/// `P_InterceptVector`: the fraction along the trace of its crossing with
/// the line (one `fixed::div`).
pub fn crossing_fraction(r: @Ray, hp: HalfPlane, lbox: Box) -> Fixed {
    intercept_fraction(*r.dl, line_divline(hp, lbox))
}

/// The point at `frac` along the trace.
pub fn point_at(r: @Ray, frac: Fixed) -> Point {
    Point {
        x: fixed::add(*r.p1.x, fixed::mul(*r.dl.dx, frac)),
        y: fixed::add(*r.p1.y, fixed::mul(*r.dl.dy, frac)),
    }
}

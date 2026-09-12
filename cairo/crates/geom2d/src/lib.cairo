// SPDX-License-Identifier: Apache-2.0
//! 2D geometry for a Doom-like: vertices, **stored half-plane predicates**,
//! bounding boxes, box-against-line classification, segment intersection
//! fractions and Doom's `P_AproxDistance`.
//!
//! # The data is the predicate, not the line
//!
//! S1 §5.5 measured that the winning representation is neither "one packed
//! record per line" nor "one array per field", but **the predicate itself**.
//! For each line the offline tool (`tools/wad`, later `doom_map`) stores three
//! biased coefficients such that, for a point `(x, y)` whose *encoded*
//! coordinates are `X = x + 2^32`, `Y = y + 2^32`:
//!
//! ```text
//! cross(x, y) = A*y + B*x + C  >=  0
//!    <=>   Ab*Y + Bb*X + Cb  >=  K*(X + Y) + M
//!          └─ 3 reads, 2 muls, 2 adds ─┘   └── independent of the line ──┘
//! ```
//!
//! with `Ab = A + K`, `Bb = B + K`, `Cb = C' + M` all non-negative
//! ([`COEF_BIAS`], [`CONST_BIAS`]). The right-hand side does not depend on
//! the line, so it is **hoisted out of the loop over lines** ([`hoist`]) and
//! computed once per point -- the arrangement S1 measured at 92 steps per
//! `box_on_line_side` against 210 for the "A, B, C split into positive and
//! negative parts" form.
//!
//! `A` and `B` are line deltas in **integer map units** (like Doom, which
//! uses `line->dx >> FRACBITS`), `C` is in raw 16.16 units. With Doom's
//! `int16` vertex range every intermediate stays below **2^53**, i.e. well
//! under the 2^72 threshold of S0.
//!
//! # Sign convention
//!
//! `cross < 0` is the **front** side ([`SIDE_FRONT`] = 0) and `cross >= 0`
//! the **back** side ([`SIDE_BACK`] = 1), which is exactly what
//! `P_PointOnLineSide` returns (`right < left` -> 0). A point exactly on the
//! line is on the back side, again like Doom.
//!
//! The predicate here is the *exact* cross product, where Doom truncates
//! both sides of its comparison to 16.16 before comparing
//! (`FixedMul(ldy >> 16, dx)` against `FixedMul(dy, ldx >> 16)`). The two
//! disagree only for points within one ulp of the line -- documented
//! divergence, in the spirit of decision D10 ("faithful Doom-like, not
//! bit-exact"); [`point_on_side_truncated`] reproduces Doom's rounding for
//! callers that care.
//!
//! # Order of the two rejections
//!
//! S1 §5.7 confirmed Doom's order: **bbox first, half-plane second**
//! ([`bbox_reject`] then [`box_on_line_side`]). Measured here on a line the
//! mobj is nowhere near -- the common case inside a blockmap cell --
//! Doom's order costs **29 steps** and the inverted one **71**, because
//! `bbox_reject` short-circuits on its first failing comparison (26 steps)
//! while `box_on_line_side` always evaluates both of its corners (66). The bbox test is also a
//! *correctness*
//! requirement, not an optimization: the half-plane predicate is about the
//! infinite line, so the box test is what bounds it to the segment.

use bam::Angle;
use fixed::{BIAS, Fixed, felt_ge};

/// Point on the map, in the `fixed` offset encoding.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Point {
    pub x: Fixed,
    pub y: Fixed,
}

/// The three biased coefficients of one line's half-plane predicate.
///
/// Produced offline (or by [`half_plane`]) and stored by the level data as
/// three parallel `const` arrays -- S1 §5.3: one array per field, never a
/// packed record, for data read tens of times per tic.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct HalfPlane {
    pub ab: felt252,
    pub bb: felt252,
    pub cb: felt252,
}

/// Axis-aligned bounding box (Doom's `BOXTOP`/`BOXBOTTOM`/`BOXLEFT`/`BOXRIGHT`).
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Box {
    pub left: Fixed,
    pub bottom: Fixed,
    pub right: Fixed,
    pub top: Fixed,
}

/// A point and a direction, Doom's `divline_t`.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct DivLine {
    pub x: Fixed,
    pub y: Fixed,
    pub dx: Fixed,
    pub dy: Fixed,
}

/// Bias added to the two linear coefficients (`2^17`): line deltas are
/// integer map units, so `|A|, |B| < 2^16`.
pub const COEF_BIAS: felt252 = 0x20000;
/// Bias added to the constant coefficient (`2^50`), which bounds
/// `|C - (A + B) * 2^32| < 2^50`.
pub const CONST_BIAS: felt252 = 0x4000000000000;

/// `cross < 0`: the side `P_PointOnLineSide` numbers 0.
pub const SIDE_FRONT: u8 = 0;
/// `cross >= 0`: the side `P_PointOnLineSide` numbers 1.
pub const SIDE_BACK: u8 = 1;
/// Returned by [`box_on_line_side`] when the box straddles the line, and by
/// [`divline_side`] when the point is exactly on it (Doom's `2`).
pub const SIDE_CROSS: u8 = 2;

// ---------------------------------------------------------------------------
// Half-plane predicate
// ---------------------------------------------------------------------------

/// The line-independent term of the predicate, `K * (X + Y) + M`.
///
/// Compute it **once per point** and pass it to every [`point_side`] of the
/// loop over lines; that is the whole point of the representation.
///
/// **Measured: 3 steps.**
pub fn hoist(p: Point) -> felt252 {
    COEF_BIAS * (p.x.enc + p.y.enc) + CONST_BIAS
}

/// Side of `p` relative to the line whose predicate is `hp`, given the
/// hoisted term `rhs` of that same point ([`hoist`]).
///
/// Returns [`SIDE_FRONT`] or [`SIDE_BACK`].
///
/// **Measured: 18 steps, 2 range checks** -- exactly S1 §5.5's figure and
/// its floor: 2 multiplications, 2 additions and one `felt_ge`.
pub fn point_side(hp: HalfPlane, p: Point, rhs: felt252) -> u8 {
    if felt_ge(hp.ab * p.y.enc + hp.bb * p.x.enc + hp.cb, rhs) {
        SIDE_BACK
    } else {
        SIDE_FRONT
    }
}

/// Same as [`point_side`], hoisting the point term itself. Convenience for
/// call sites that test a single line; inside a loop, hoist once instead.
///
/// **Measured: 21 steps, 2 range checks** (the 18 above plus the 3 of
/// [`hoist`]).
pub fn point_side_alone(hp: HalfPlane, p: Point) -> u8 {
    point_side(hp, p, hoist(p))
}

/// Three-valued side test, Doom's `P_DivlineSide`: [`SIDE_FRONT`],
/// [`SIDE_BACK`], or [`SIDE_CROSS`] when the point is **exactly** on the
/// line. Used by the BSP ray traversal of `P_CheckSight`.
///
/// **Measured: 20 steps, 2 range checks** (2 more than the two-valued
/// form: the equality test is a single field comparison).
pub fn divline_side(hp: HalfPlane, p: Point, rhs: felt252) -> u8 {
    let lhs = hp.ab * p.y.enc + hp.bb * p.x.enc + hp.cb;
    if lhs == rhs {
        SIDE_CROSS
    } else if felt_ge(lhs, rhs) {
        SIDE_BACK
    } else {
        SIDE_FRONT
    }
}

/// Read one line's predicate out of three parallel coefficient arrays and
/// test a point against it -- the shape `doom_physics` uses when iterating
/// over a blockmap cell's line list.
///
/// **Measured: 60 steps, 5 range checks**: the 18 of the predicate plus 42
/// for the three `Span` indexes -- 14 each, against S1 §5.1's 11, the
/// difference being the bounds check Cairo inserts on a `u32` index.
pub fn point_side_at(
    ab: Span<felt252>, bb: Span<felt252>, cb: Span<felt252>, line: u32, p: Point, rhs: felt252,
) -> u8 {
    let hp = HalfPlane { ab: *ab.at(line), bb: *bb.at(line), cb: *cb.at(line) };
    point_side(hp, p, rhs)
}

/// Build the half-plane predicate of the line `v1 -> v2`.
///
/// **Cold path** (the WAD tool precomputes these arrays offline); it is
/// public so that consumers can build a predicate for a line that only
/// exists at run time, and so that the generated tables can be checked
/// against it. Not benchmarked.
pub fn half_plane(v1: Point, v2: Point) -> HalfPlane {
    // Deltas in integer map units, like Doom's `line->dx >> FRACBITS`.
    let ldx = fixed::to_units(fixed::sub(v2.x, v1.x));
    let ldy = fixed::to_units(fixed::sub(v2.y, v1.y));
    let a = ldx;
    let b = -ldy;
    // C = ldy * v1.x - ldx * v1.y, in raw 16.16 units.
    let c = ldy * fixed::to_raw(v1.x) - ldx * fixed::to_raw(v1.y);
    HalfPlane { ab: a + COEF_BIAS, bb: b + COEF_BIAS, cb: c - (a + b) * BIAS + CONST_BIAS }
}

/// `1` when the line's slope is negative (`ldx * ldy < 0`), `0` otherwise:
/// Doom's `slopetype`, reduced to the single bit [`box_on_line_side`] needs.
///
/// Cold path, computed offline with [`half_plane`]. Not benchmarked.
pub fn diagonal(v1: Point, v2: Point) -> u8 {
    let ldx = fixed::to_units(fixed::sub(v2.x, v1.x));
    let ldy = fixed::to_units(fixed::sub(v2.y, v1.y));
    let neg_x = !felt_ge(ldx + BIAS, BIAS);
    let neg_y = !felt_ge(ldy + BIAS, BIAS);
    if neg_x != neg_y {
        1
    } else {
        0
    }
}

/// Which side of the line `v1 -> v2` the point `p` is on, built from the two
/// vertices instead of a stored predicate.
///
/// The convenience form for a caller that has no precomputed coefficients
/// (a line created at run time, a test). Inside any loop over lines, store
/// the predicate and call [`point_side`] instead: this one rebuilds the
/// three coefficients on every call.
///
/// **Measured: 73 steps, 12 range checks**, against 18 for [`point_side`]
/// with the predicate already stored.
pub fn point_on_side(p: Point, v1: Point, v2: Point) -> u8 {
    point_side_alone(half_plane(v1, v2), p)
}

/// Doom's `P_PointOnLineSide` written from two vertices, **including its
/// truncation**: both sides of the comparison are reduced to 16.16 before
/// being compared, so this returns exactly what the C function returns, at
/// the price of two `fixed::mul`.
///
/// Prefer [`point_side`] everywhere except when reproducing a Doom result
/// for a point within one ulp of a line.
///
/// **Measured: 96 steps, 22 range checks** -- 5x the exact predicate,
/// which is why the crate does not use it internally.
pub fn point_on_side_truncated(p: Point, v1: Point, v2: Point) -> u8 {
    let ldx = fixed::to_units(fixed::sub(v2.x, v1.x));
    let ldy = fixed::to_units(fixed::sub(v2.y, v1.y));
    let dx = fixed::sub(p.x, v1.x);
    let dy = fixed::sub(p.y, v1.y);
    // Doom passes the *integer* delta as a fixed_t operand, so the product
    // is `(ldy * dx) >> 16`, not `ldy * dx`.
    let left = fixed::mul(fixed::from_raw(ldy), dx);
    let right = fixed::mul(dy, fixed::from_raw(ldx));
    if felt_ge(right.enc, left.enc) {
        SIDE_BACK
    } else {
        SIDE_FRONT
    }
}

// ---------------------------------------------------------------------------
// Bounding boxes
// ---------------------------------------------------------------------------

/// `true` when the two boxes do **not** overlap, i.e. when the caller may
/// skip the line entirely. This is the first half of Doom's `PIT_CheckLine`
/// and it must stay first (see the module docs).
///
/// **Measured: 57 steps when all four comparisons run, 26 when the first
/// one rejects** (the common case, and the ~30 S1 §5.7 measured on a real
/// blockmap cell).
pub fn bbox_reject(a: Box, b: Box) -> bool {
    if felt_ge(b.left.enc, a.right.enc) {
        return true;
    }
    if felt_ge(a.left.enc, b.right.enc) {
        return true;
    }
    if felt_ge(b.bottom.enc, a.top.enc) {
        return true;
    }
    felt_ge(a.bottom.enc, b.top.enc)
}

/// Which side of the line the whole box is on, or [`SIDE_CROSS`] when it
/// straddles it: Doom's `P_BoxOnLineSide`.
///
/// `diag` is the stored slope bit ([`diagonal`]): it picks the pair of
/// opposite corners to test, which is what makes two half-plane evaluations
/// enough. S1 §5.5 recommends keeping it in a `const` array -- 11 steps to
/// read against the 34 of the two extra evaluations it avoids.
///
/// **Measured: 66 steps, 4 range checks** (S1's revised exit criterion for
/// R2-A4 was `<= 100`; it measured 92 for the same operation).
pub fn box_on_line_side(hp: HalfPlane, diag: u8, b: Box) -> u8 {
    let (p1, p2) = if diag == 0 {
        (Point { x: b.left, y: b.top }, Point { x: b.right, y: b.bottom })
    } else {
        (Point { x: b.right, y: b.top }, Point { x: b.left, y: b.bottom })
    };
    let s1 = point_side(hp, p1, hoist(p1));
    let s2 = point_side(hp, p2, hoist(p2));
    if s1 == s2 {
        s1
    } else {
        SIDE_CROSS
    }
}

/// Bounding box of the segment `v1 -> v2` (a line's `ld->bbox`).
///
/// Cold path, precomputed offline. Not benchmarked.
pub fn box_of_segment(v1: Point, v2: Point) -> Box {
    Box {
        left: fixed::min(v1.x, v2.x),
        bottom: fixed::min(v1.y, v2.y),
        right: fixed::max(v1.x, v2.x),
        top: fixed::max(v1.y, v2.y),
    }
}

/// Box of radius `r` around `p`, the `tmbbox` of a moving thing.
///
/// **Measured: 4 steps.**
pub fn box_around(p: Point, r: Fixed) -> Box {
    Box {
        left: fixed::sub(p.x, r),
        bottom: fixed::sub(p.y, r),
        right: fixed::add(p.x, r),
        top: fixed::add(p.y, r),
    }
}

// ---------------------------------------------------------------------------
// Intersections and distances
// ---------------------------------------------------------------------------

/// Doom's `P_InterceptVector`: the fraction along `v2` at which it crosses
/// `v1`, in 16.16. Returns `0` when the two are parallel (`den == 0`),
/// exactly like the original -- it never panics.
///
/// Both operands are pre-shifted by 8 bits, as in C, so the result matches
/// Doom's including its rounding.
///
/// **The expensive primitive of this crate** (one `fixed::div`): to merely
/// *order* two intercepts, compare cross products instead (S1 §7).
///
/// **Measured: 228 steps, 52 range checks** -- by far the most expensive
/// function of the geometry stack (4 `mul`, 4 `shr8` and one `div`).
pub fn intercept_fraction(v2: DivLine, v1: DivLine) -> Fixed {
    let num = fixed::add(
        fixed::mul(fixed::shr8(fixed::sub(v1.x, v2.x)), v1.dy),
        fixed::mul(fixed::shr8(fixed::sub(v2.y, v1.y)), v1.dx),
    );
    let den = fixed::sub(
        fixed::mul(fixed::shr8(v1.dy), v2.dx), fixed::mul(fixed::shr8(v1.dx), v2.dy),
    );
    if den.enc == BIAS {
        return fixed::ZERO;
    }
    fixed::div(num, den)
}

/// Doom's `P_AproxDistance`: `|dx| + |dy| - min(|dx|, |dy|) / 2`, an
/// octagonal approximation of the Euclidean distance that never divides.
///
/// Over-estimates by at most ~12 % and under-estimates by at most ~6 %, the
/// same error as the C original, which the whole AI is tuned around.
///
/// **Measured: 65 steps, 11 range checks.**
pub fn approx_distance(dx: Fixed, dy: Fixed) -> Fixed {
    let a = fixed::magnitude(dx);
    let b = fixed::magnitude(dy);
    let (big, small) = if felt_ge(a, b) {
        (a, b)
    } else {
        (b, a)
    };
    let s: u128 = small.try_into().unwrap();
    let half: felt252 = (s / 2).into();
    fixed::from_raw(big + small - half)
}

/// Angle of the vector from `from` to `to` (`R_PointToAngle2`), re-exported
/// here so that consumers of `geom2d` do not have to reach into `bam` for
/// the one operation that takes two points.
///
/// **Measured: 122 steps, 22 range checks** (it *is* `bam::point_to_angle2`).
pub fn angle_between(from: Point, to: Point) -> Angle {
    bam::point_to_angle2(from.x, from.y, to.x, to.y)
}

#[cfg(test)]
mod tests;

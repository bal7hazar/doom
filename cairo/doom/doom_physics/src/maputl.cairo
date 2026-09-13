// SPDX-License-Identifier: GPL-2.0-only
//! Line helpers over the hoisted level spans (`p_maputl.c`: `P_LineOpening`,
//! `P_MakeDivline`, the box test of `PIT_CheckLine`), written against the
//! raw `L_*` felts so that an inner loop never pays the `@LevelMap` snapshot
//! (D24) — and **without a panic path** (S7): every span read is a `get`
//! whose out-of-range arm yields a zero, every conversion a `match`, every
//! comparison `felt_ge_narrow`. A panic site inside a Cairo function costs
//! the function's whole return width in bytecode, and a function with none
//! is compiled without the `PanicResult` wrapper at all (docs/spikes/S7.md
//! §2), so the loops of this crate are built out of these.

use core::num::traits::{WrappingAdd, WrappingSub};
use fixed::{BIAS, Fixed, felt_ge_narrow, to_u128};
use geom2d::{Box, COEF_BIAS, DivLine, HalfPlane, Point};

/// `fixed::BIAS - 2^15 * FRACUNIT`: a 16-bit biased map unit times 65536
/// plus this is its `Fixed::enc` (the same constant `doom_map` uses).
pub const COORD_OFFSET: felt252 = 0x80000000;

// ---------------------------------------------------------------------------
// Panic-free primitives
// ---------------------------------------------------------------------------

/// `*s.at(i)` without the out-of-bounds panic: an index past the end (a
/// caller bug on compiled-in data) reads as `0`.
#[inline(always)]
pub fn rd(s: Span<felt252>, i: u32) -> felt252 {
    match s.get(i) {
        Option::Some(b) => *b.unbox(),
        Option::None => 0,
    }
}

/// [`rd`] on a `Span<u32>`.
#[inline(always)]
pub fn rd32(s: Span<u32>, i: u32) -> u32 {
    match s.get(i) {
        Option::Some(b) => *b.unbox(),
        Option::None => 0,
    }
}

/// [`rd`] on a `Span<u8>`.
#[inline(always)]
pub fn rd8(s: Span<u8>, i: u32) -> u8 {
    match s.get(i) {
        Option::Some(b) => *b.unbox(),
        Option::None => 0,
    }
}

/// `i + 1` on a `u32` without the overflow panic (a counter never reaches
/// 2^32 here).
#[inline(always)]
pub fn inc(i: u32) -> u32 {
    i.wrapping_add(1)
}

/// `i - 1` on a `u32` without the underflow panic (the caller has tested
/// `i != 0`).
#[inline(always)]
pub fn dec(i: u32) -> u32 {
    i.wrapping_sub(1)
}

/// `a + b` / `a - b` on `u32` without the overflow panic.
#[inline(always)]
pub fn add32(a: u32, b: u32) -> u32 {
    a.wrapping_add(b)
}

#[inline(always)]
pub fn sub32(a: u32, b: u32) -> u32 {
    a.wrapping_sub(b)
}

/// A zero the compiler cannot see: a loop-carried counter that starts at a
/// literal gets a second, specialised copy of the loop body (S7 §2), so
/// counters start from `opaque_zero(n)` instead of `0`.
#[inline(always)]
pub fn opaque_zero(n: u32) -> u32 {
    n.wrapping_sub(n)
}

/// `cy * columns + cx` in the field: `blockmap::cell_index` without its
/// `u32` overflow checks (a cell index always fits).
#[inline(always)]
pub fn cell_at(g: blockmap::Grid, cx: u32, cy: u32) -> u32 {
    let c: felt252 = cy.into() * g.columns.into() + cx.into();
    let r: Option<u32> = c.try_into();
    match r {
        Option::Some(v) => v,
        Option::None => 0,
    }
}

/// The low 32 bits of a `u128` the caller knows to be below 2^32.
#[inline(always)]
pub fn low32(v: u128) -> u32 {
    let r: Option<u32> = v.try_into();
    match r {
        Option::Some(x) => x,
        Option::None => 0,
    }
}

// ---------------------------------------------------------------------------
// L_PACKED
// ---------------------------------------------------------------------------

/// The cold fields of one linedef, decoded from its `L_PACKED` felt.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct LineMeta {
    /// Raw WAD flags (`doom_map::ML_*`).
    pub flags: u32,
    pub special: u32,
    pub tag: u32,
    /// Front/back sector, or `doom_map::NO_SECTOR`.
    pub front: u32,
    pub back: u32,
}

/// Decode a whole `L_PACKED` felt: five `u128` divmods.
///
/// Layout (LSB first): flags 16 bits, special 8, tag 16, diagonal 1, front
/// sector 11, back sector 11.
#[inline(never)]
pub fn line_meta(packed: felt252) -> LineMeta {
    let v = to_u128(packed);
    let w16: NonZero<u128> = 0x10000;
    let w8: NonZero<u128> = 0x100;
    let w2: NonZero<u128> = 2;
    let w11: NonZero<u128> = 0x800;
    let (q1, flags) = DivRem::div_rem(v, w16);
    let (q2, special) = DivRem::div_rem(q1, w8);
    let (q3, tag) = DivRem::div_rem(q2, w16);
    let (q4, _diag) = DivRem::div_rem(q3, w2);
    let (back, front) = DivRem::div_rem(q4, w11);
    LineMeta {
        flags: low32(flags),
        special: low32(special),
        tag: low32(tag),
        front: low32(front),
        back: low32(back),
    }
}

/// The flags word alone: one divmod.
pub fn line_flags(packed: felt252) -> u32 {
    let w16: NonZero<u128> = 0x10000;
    let (_, flags) = DivRem::div_rem(to_u128(packed), w16);
    low32(flags)
}

/// What a sight or hitscan crossing needs: `(flags, front, back)` in three
/// divmods instead of `line_flags` + `line_meta`'s six.
#[inline(never)]
pub fn line_sides(packed: felt252) -> (u32, u32, u32) {
    let w16: NonZero<u128> = 0x10000;
    let w25: NonZero<u128> = 0x2000000;
    let w11: NonZero<u128> = 0x800;
    let (q1, flags) = DivRem::div_rem(to_u128(packed), w16);
    let (q4, _) = DivRem::div_rem(q1, w25);
    let (back, front) = DivRem::div_rem(q4, w11);
    (low32(flags), low32(front), low32(back))
}

// ---------------------------------------------------------------------------
// The predicate and what it encodes
// ---------------------------------------------------------------------------

/// The stored predicate of linedef `i`: three reads.
#[inline(always)]
pub fn line_hp(l_ab: Span<felt252>, l_bb: Span<felt252>, l_cb: Span<felt252>, i: u32) -> HalfPlane {
    HalfPlane { ab: rd(l_ab, i), bb: rd(l_bb, i), cb: rd(l_cb, i) }
}

/// `(ldx < 0, ldy < 0)` off the coefficients (`Ab = ldx + 2^17`,
/// `Bb = 2^17 - ldy`): two comparisons.
pub fn delta_signs(hp: HalfPlane) -> (bool, bool) {
    (!felt_ge_narrow(hp.ab, COEF_BIAS), felt_ge_narrow(hp.bb, COEF_BIAS + 1))
}

/// `geom2d::diagonal` of the line, computed from the coefficient signs
/// instead of read from `L_PACKED` (22 steps against a divmod chain).
pub fn line_diagonal(hp: HalfPlane) -> u8 {
    let (neg_x, neg_y) = delta_signs(hp);
    if neg_x != neg_y {
        1
    } else {
        0
    }
}

/// `(ldx, ldy)` as `Fixed` (map units times `FRACUNIT`): pure felt
/// arithmetic on the coefficients.
pub fn line_delta(hp: HalfPlane) -> (Fixed, Fixed) {
    (
        Fixed { enc: (hp.ab - COEF_BIAS) * 65536 + BIAS },
        Fixed { enc: (COEF_BIAS - hp.bb) * 65536 + BIAS },
    )
}

/// The line's first vertex, from its box and its delta signs (the same
/// recovery as `doom_map::linedef_v1`, on values already in hand).
pub fn line_v1(hp: HalfPlane, b: Box) -> Point {
    let (neg_x, neg_y) = delta_signs(hp);
    Point { x: if neg_x {
        b.right
    } else {
        b.left
    }, y: if neg_y {
        b.top
    } else {
        b.bottom
    } }
}

/// Doom's `P_MakeDivline`: the line as a point and a direction.
pub fn line_divline(hp: HalfPlane, b: Box) -> DivLine {
    let v1 = line_v1(hp, b);
    let (dx, dy) = line_delta(hp);
    DivLine { x: v1.x, y: v1.y, dx, dy }
}

// ---------------------------------------------------------------------------
// L_BOX
// ---------------------------------------------------------------------------

/// A 16-bit biased map unit as a `Fixed`.
#[inline(always)]
fn coord(units: u128) -> Fixed {
    let u: felt252 = units.into();
    Fixed { enc: u * 65536 + COORD_OFFSET }
}

/// The full box of a linedef from its `L_BOX` felt (`doom_map::unpack_box`,
/// panic-free). Layout (LSB first): left, bottom, right, top, 16 bits each.
#[inline(never)]
pub fn line_box(packed: felt252) -> Box {
    let w16: NonZero<u128> = 0x10000;
    let (q1, left) = DivRem::div_rem(to_u128(packed), w16);
    let (q2, bottom) = DivRem::div_rem(q1, w16);
    let (top, right) = DivRem::div_rem(q2, w16);
    Box { left: coord(left), bottom: coord(bottom), right: coord(right), top: coord(top) }
}

/// A thing's box in whole map units, rounded so that each of the four
/// rejects of `PIT_CheckLine` is one `u128` comparison against a field of
/// the line's packed `L_BOX` (S7): `line.left >= right_ceil`,
/// `line.right <= left_floor`, `line.bottom >= top_ceil`,
/// `line.top <= bottom_floor` are exactly Doom's four `<=`/`>=` tests on
/// the fixed-point boxes.
#[derive(Copy, Drop)]
pub struct UnitBox {
    pub left_floor: u128,
    pub bottom_floor: u128,
    pub right_ceil: u128,
    pub top_ceil: u128,
}

/// `floor((enc - COORD_OFFSET) / 65536)`: the biased unit at or below `enc`.
#[inline(always)]
fn units_floor(enc: felt252) -> u128 {
    let w16: NonZero<u128> = 65536;
    let (q, _) = DivRem::div_rem(to_u128(enc - COORD_OFFSET), w16);
    q
}

/// `ceil((enc - COORD_OFFSET) / 65536)`: the biased unit at or above `enc`.
#[inline(always)]
fn units_ceil(enc: felt252) -> u128 {
    let w16: NonZero<u128> = 65536;
    let (q, _) = DivRem::div_rem(to_u128(enc - COORD_OFFSET + 65535), w16);
    q
}

/// The unit-rounded bounding box of a *trace*, for the early reject of the
/// traversals (S7): a line whose box lies **strictly** outside the trace's
/// box cannot be crossed by it (nor touched, which the three-valued sight
/// test counts as crossed), so `line.top < y_lo`, `line.bottom > y_hi`,
/// `line.right < x_lo` or `line.left > x_hi` dismiss it without reading its
/// predicate. The y bounds are pre-shifted by 16 bits so that both y tests
/// run on the halves of one `u128` divmod of the packed `L_BOX`.
#[derive(Copy, Drop)]
pub struct TraceBox {
    /// `ceil(min_y) << 16`: the line is below the trace when `hi < y_lo_sh`
    /// (`hi = right + top << 16`).
    pub y_lo_sh: u128,
    /// `(floor(max_y) + 1) << 16`: the line is above the trace when
    /// `lo >= y_hi1_sh` (`lo = left + bottom << 16`).
    pub y_hi1_sh: u128,
    /// `ceil(min_x)`: the line is left of the trace when `right < x_lo`.
    pub x_lo: u128,
    /// `floor(max_x)`: the line is right of the trace when `left > x_hi`.
    pub x_hi: u128,
}

/// The [`TraceBox`] of the trace `p1 -> p2`: four divisions, once per
/// traversal.
pub fn trace_box(p1: Point, p2: Point) -> TraceBox {
    let y_lo: felt252 = units_ceil(fixed::min(p1.y, p2.y).enc).into();
    let y_hi: felt252 = units_floor(fixed::max(p1.y, p2.y).enc).into();
    TraceBox {
        y_lo_sh: to_u128(y_lo * 65536),
        y_hi1_sh: to_u128((y_hi + 1) * 65536),
        x_lo: units_ceil(fixed::min(p1.x, p2.x).enc),
        x_hi: units_floor(fixed::max(p1.x, p2.x).enc),
    }
}

/// `true` when the line's packed `L_BOX` lies strictly outside the trace's
/// [`TraceBox`]: one divmod settles both y tests, two more the x tests.
#[inline(always)]
pub fn line_box_misses(packed: felt252, tb: TraceBox) -> bool {
    let w32: NonZero<u128> = 0x100000000;
    let w16: NonZero<u128> = 0x10000;
    let (hi, lo) = DivRem::div_rem(to_u128(packed), w32);
    if hi < tb.y_lo_sh {
        return true;
    }
    if lo >= tb.y_hi1_sh {
        return true;
    }
    let (_, left) = DivRem::div_rem(lo, w16);
    if left > tb.x_hi {
        return true;
    }
    let (_, right) = DivRem::div_rem(hi, w16);
    right < tb.x_lo
}

/// The [`UnitBox`] of a box: four conversions and four divisions, once per
/// `P_CheckPosition`.
pub fn unit_box(b: Box) -> UnitBox {
    UnitBox {
        left_floor: units_floor(b.left.enc),
        bottom_floor: units_floor(b.bottom.enc),
        right_ceil: units_ceil(b.right.enc),
        top_ceil: units_ceil(b.top.enc),
    }
}

/// The first half of `PIT_CheckLine`, decoding the line's `L_BOX` felt
/// **lazily**: one divmod and one comparison reject a line entirely to the
/// right, two a line entirely below, three the rest. Touching boxes are
/// rejected, like Doom's `<=`/`>=`.
pub fn line_box_rejects(packed: felt252, ub: UnitBox) -> bool {
    let w16: NonZero<u128> = 0x10000;
    let (q1, left) = DivRem::div_rem(to_u128(packed), w16);
    if left >= ub.right_ceil {
        return true;
    }
    let (q2, bottom) = DivRem::div_rem(q1, w16);
    if bottom >= ub.top_ceil {
        return true;
    }
    let (top, right) = DivRem::div_rem(q2, w16);
    if right <= ub.left_floor {
        return true;
    }
    top <= ub.bottom_floor
}

// ---------------------------------------------------------------------------
// P_LineOpening
// ---------------------------------------------------------------------------

/// `P_LineOpening` on a two-sided line, from the current sector heights.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct Opening {
    /// Lower of the two ceilings.
    pub top: Fixed,
    /// Higher of the two floors.
    pub bottom: Fixed,
    /// Lower of the two floors (the drop-off).
    pub lowfloor: Fixed,
    /// The two floors differ / the two ceilings differ (what `P_CheckSight`
    /// and the hitscan slope tests branch on).
    pub floors_differ: bool,
    pub ceilings_differ: bool,
}

/// `P_LineOpening`: four reads and two comparisons.
#[inline(never)]
pub fn line_opening(floor: Span<felt252>, ceil: Span<felt252>, front: u32, back: u32) -> Opening {
    let ff = rd(floor, front);
    let bf = rd(floor, back);
    let fc = rd(ceil, front);
    let bc = rd(ceil, back);
    let (top, ceilings_differ) = if fc == bc {
        (fc, false)
    } else if felt_ge_narrow(bc, fc) {
        (fc, true)
    } else {
        (bc, true)
    };
    let (bottom, lowfloor, floors_differ) = if ff == bf {
        (ff, ff, false)
    } else if felt_ge_narrow(ff, bf) {
        (ff, bf, true)
    } else {
        (bf, ff, true)
    };
    Opening {
        top: Fixed { enc: top },
        bottom: Fixed { enc: bottom },
        lowfloor: Fixed { enc: lowfloor },
        floors_differ,
        ceilings_differ,
    }
}

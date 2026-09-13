// SPDX-License-Identifier: GPL-2.0-only
//! Line helpers over the hoisted level spans (`p_maputl.c`: `P_LineOpening`,
//! `P_MakeDivline`, the box test of `PIT_CheckLine`), written against the
//! raw `L_*` felts so that an inner loop never pays the `@LevelMap` snapshot
//! (D24).

use doom_map::unpack_box;
use fixed::{BIAS, Fixed, felt_ge};
use geom2d::{Box, COEF_BIAS, DivLine, HalfPlane, Point};

/// `fixed::BIAS - 2^15 * FRACUNIT`: a 16-bit biased map unit times 65536
/// plus this is its `Fixed::enc` (the same constant `doom_map` uses).
const COORD_OFFSET: felt252 = 0x80000000;

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
pub fn line_meta(packed: felt252) -> LineMeta {
    let v: u128 = packed.try_into().unwrap();
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
        flags: flags.try_into().unwrap(),
        special: special.try_into().unwrap(),
        tag: tag.try_into().unwrap(),
        front: front.try_into().unwrap(),
        back: back.try_into().unwrap(),
    }
}

/// The flags word alone: one divmod.
pub fn line_flags(packed: felt252) -> u32 {
    let v: u128 = packed.try_into().unwrap();
    let w16: NonZero<u128> = 0x10000;
    let (_, flags) = DivRem::div_rem(v, w16);
    flags.try_into().unwrap()
}

/// The stored predicate of linedef `i`: three reads.
#[inline(always)]
pub fn line_hp(l_ab: Span<felt252>, l_bb: Span<felt252>, l_cb: Span<felt252>, i: u32) -> HalfPlane {
    HalfPlane { ab: *l_ab.at(i), bb: *l_bb.at(i), cb: *l_cb.at(i) }
}

/// `(ldx < 0, ldy < 0)` off the coefficients (`Ab = ldx + 2^17`,
/// `Bb = 2^17 - ldy`): two comparisons.
pub fn delta_signs(hp: HalfPlane) -> (bool, bool) {
    (!felt_ge(hp.ab, COEF_BIAS), felt_ge(hp.bb, COEF_BIAS + 1))
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

/// The first half of `PIT_CheckLine`, decoding the line's `L_BOX` felt
/// **lazily**: one divmod and one comparison reject a line entirely to the
/// right, two a line entirely below, three the rest. Touching boxes are
/// rejected, like Doom's `<=`/`>=`.
pub fn line_box_rejects(packed: felt252, b: Box) -> bool {
    let v: u128 = packed.try_into().unwrap();
    let w16: NonZero<u128> = 0x10000;
    let (q1, left) = DivRem::div_rem(v, w16);
    let left: felt252 = left.into();
    if felt_ge(left * 65536 + COORD_OFFSET, b.right.enc) {
        return true;
    }
    let (q2, bottom) = DivRem::div_rem(q1, w16);
    let bottom: felt252 = bottom.into();
    if felt_ge(bottom * 65536 + COORD_OFFSET, b.top.enc) {
        return true;
    }
    let (top, right) = DivRem::div_rem(q2, w16);
    let right: felt252 = right.into();
    if felt_ge(b.left.enc, right * 65536 + COORD_OFFSET) {
        return true;
    }
    let top: felt252 = top.into();
    felt_ge(b.bottom.enc, top * 65536 + COORD_OFFSET)
}

/// The full box of a linedef from its `L_BOX` felt.
#[inline(always)]
pub fn line_box(packed: felt252) -> Box {
    unpack_box(packed)
}

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
pub fn line_opening(floor: Span<felt252>, ceil: Span<felt252>, front: u32, back: u32) -> Opening {
    let ff = *floor.at(front);
    let bf = *floor.at(back);
    let fc = *ceil.at(front);
    let bc = *ceil.at(back);
    let (top, ceilings_differ) = if fc == bc {
        (fc, false)
    } else if felt_ge(bc, fc) {
        (fc, true)
    } else {
        (bc, true)
    };
    let (bottom, lowfloor, floors_differ) = if ff == bf {
        (ff, ff, false)
    } else if felt_ge(ff, bf) {
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

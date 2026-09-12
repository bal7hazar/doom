//! Half-plane tests: `point_on_side` and `box_on_line_side`, division-free.
//!
//! Two competing representations of the same predicate are implemented so the
//! spike can price R2-A4:
//!
//!   * `six()`   -- A, B, C each split into a non-negative positive part and a
//!                  non-negative negative part: 6 const-array reads, 4 muls.
//!   * `three()` -- A, B, C stored biased by a constant: 3 const-array reads,
//!                  2 muls, and the bias term `K*(X+Y) + BIGC` hoisted out of
//!                  the per-line loop (it does not depend on the line).
//!
//! `cross = A*Y + B*X + C2` with biased coordinates `X = x + OFF`,
//! `Y = y + OFF`.  Doom returns side 0 when `cross < 0`.

use crate::fixed::felt_ge;
use crate::mapdata::{
    HK, L_AN, L_AP, L_BN, L_BP, L_CN, L_CP, N_AB, N_AN, N_AP, N_BB, N_BN, N_BP, N_CB, N_CN, N_CP,
};

/// Bias term of the 3-array form, hoisted per point: `K*(X+Y) + BIGC`.
#[inline(always)]
pub fn hoist(x: felt252, y: felt252, bigc: felt252) -> felt252 {
    HK * (x + y) + bigc
}

/// 6-array form: `side == 1` iff `cross >= 0`.
pub fn line_side_six(li: u32, x: felt252, y: felt252) -> u32 {
    let pos = *L_AP.span().at(li) * y + *L_BP.span().at(li) * x + *L_CP.span().at(li);
    let neg = *L_AN.span().at(li) * y + *L_BN.span().at(li) * x + *L_CN.span().at(li);
    if felt_ge(pos, neg) {
        1
    } else {
        0
    }
}

/// 3-array form; `h` is `hoist(x, y, BIGC)` computed once for this point.
#[inline(always)]
pub fn line_side_three(ab: felt252, bb: felt252, cb: felt252, x: felt252, y: felt252, h: felt252) -> u32 {
    if felt_ge(ab * y + bb * x + cb, h) {
        1
    } else {
        0
    }
}

/// BSP node side, 6-array form.
pub fn node_side_six(ni: u32, x: felt252, y: felt252) -> u32 {
    let pos = *N_AP.span().at(ni) * y + *N_BP.span().at(ni) * x + *N_CP.span().at(ni);
    let neg = *N_AN.span().at(ni) * y + *N_BN.span().at(ni) * x + *N_CN.span().at(ni);
    if felt_ge(pos, neg) {
        1
    } else {
        0
    }
}

/// BSP node side, 3-array form (bias `h` hoisted by the caller).
pub fn node_side_three(ni: u32, x: felt252, y: felt252, h: felt252) -> u32 {
    let v = *N_AB.span().at(ni) * y + *N_BB.span().at(ni) * x + *N_CB.span().at(ni);
    if felt_ge(v, h) {
        1
    } else {
        0
    }
}

/// The bounding box of a moving mobj, in biased fixed coordinates.
#[derive(Copy, Drop)]
pub struct Bbox {
    pub l: felt252,
    pub r: felt252,
    pub b: felt252,
    pub t: felt252,
}

/// Precomputed hoist terms for the four corners of a bbox (3-array form).
#[derive(Copy, Drop)]
pub struct BoxHoist {
    pub lt: felt252,
    pub rb: felt252,
    pub rt: felt252,
    pub lb: felt252,
}

#[inline(always)]
pub fn box_hoist(bb: Bbox, bigc: felt252) -> BoxHoist {
    BoxHoist {
        lt: hoist(bb.l, bb.t, bigc),
        rb: hoist(bb.r, bb.b, bigc),
        rt: hoist(bb.r, bb.t, bigc),
        lb: hoist(bb.l, bb.b, bigc),
    }
}

/// Does the box straddle the line?  (Doom's P_BoxOnLineSide returning -1.)
/// 3-array form: 3 const reads + 1 diag read + 2 half-plane evaluations.
pub fn box_crosses_three(
    ab: felt252, bb: felt252, cb: felt252, diag: felt252, bx: Bbox, h: BoxHoist,
) -> bool {
    if diag == 0 {
        let p1 = felt_ge(ab * bx.t + bb * bx.l + cb, h.lt);
        let p2 = felt_ge(ab * bx.b + bb * bx.r + cb, h.rb);
        p1 != p2
    } else {
        let p1 = felt_ge(ab * bx.t + bb * bx.r + cb, h.rt);
        let p2 = felt_ge(ab * bx.b + bb * bx.l + cb, h.lb);
        p1 != p2
    }
}

/// Same predicate, 6-array form (the baseline R2-A4 improves on).
pub fn box_crosses_six(li: u32, diag: felt252, bx: Bbox) -> bool {
    if diag == 0 {
        let p1 = line_side_six(li, bx.l, bx.t);
        let p2 = line_side_six(li, bx.r, bx.b);
        p1 != p2
    } else {
        let p1 = line_side_six(li, bx.r, bx.t);
        let p2 = line_side_six(li, bx.l, bx.b);
        p1 != p2
    }
}

/// Doom's bbox reject, kept so the spike can price it.  In Cairo this costs
/// *more* than the half-plane test it is supposed to avoid (4 const reads +
/// 4 comparisons), which inverts the C trade-off.
pub fn bbox_reject(li: u32, bx: Bbox) -> bool {
    use crate::mapdata::{L_BBB, L_BBL, L_BBR, L_BBT};
    let s = L_BBL.span();
    if felt_ge(*s.at(li), bx.r) {
        return true;
    }
    if felt_ge(bx.l, *L_BBR.span().at(li)) {
        return true;
    }
    if felt_ge(*L_BBB.span().at(li), bx.t) {
        return true;
    }
    if felt_ge(bx.b, *L_BBT.span().at(li)) {
        return true;
    }
    false
}

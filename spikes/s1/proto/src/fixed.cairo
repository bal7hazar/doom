//! 16.16 fixed point, felt-first, with no negative felt ever reaching memory.
//!
//! Design rules exercised here (PLAN A7 / RISKS R4-A5):
//!   * every value written to a variable is a non-negative felt252 < 2^128;
//!   * signed quantities are (magnitude, sign) pairs: `Sf { m, neg }`;
//!   * positions are stored biased (`X = x + OFF`), never as a signed value;
//!   * comparisons go through exactly one felt252 -> u128 downcast.

pub const FRACUNIT: felt252 = 65536;
pub const FRACUNIT_U128: u128 = 65536;

/// Bias used by `felt_ge`.  Chosen so that every value this crate writes to
/// memory stays **below 2^72**: S0 found that memory values >= 2^72 add 33% to
/// the range_check_9_9 component of the proof, and the measurement in S1 5.1
/// shows that shrinking the bias from 2^104 to 2^64 costs exactly zero steps.
/// Operands must be non-negative and their difference must fit in +/- 2^63;
/// the largest product the prototype forms is ~2^60 (`physics::ray_side`).
pub const CMP_BIAS: felt252 = 0x10000000000000000; // 2^64
pub const CMP_BIAS_U128: u128 = 0x10000000000000000;

/// A signed 16.16 value as magnitude + sign.  `neg == 1` means negative.
/// `m` is always a non-negative felt252.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct Sf {
    pub m: felt252,
    pub neg: u32,
}

#[inline(always)]
pub fn sf(m: felt252, neg: u32) -> Sf {
    Sf { m, neg }
}

#[inline(always)]
pub fn sf_zero() -> Sf {
    Sf { m: 0, neg: 0 }
}

/// `a >= b` for two non-negative felts known to be < 2^104.
/// One felt252 -> u128 downcast + one u128 comparison.
#[inline(always)]
pub fn felt_ge(a: felt252, b: felt252) -> bool {
    let d: u128 = (a - b + CMP_BIAS).try_into().unwrap();
    d >= CMP_BIAS_U128
}

/// `a > b` for two non-negative felts known to be < 2^104.
#[inline(always)]
pub fn felt_gt(a: felt252, b: felt252) -> bool {
    let d: u128 = (a - b + CMP_BIAS).try_into().unwrap();
    d > CMP_BIAS_U128
}

/// Difference of two non-negative felts as a signed value.
pub fn felt_sub(a: felt252, b: felt252) -> Sf {
    if felt_ge(a, b) {
        Sf { m: a - b, neg: 0 }
    } else {
        Sf { m: b - a, neg: 1 }
    }
}

/// Add a signed value to a biased non-negative base, staying non-negative.
#[inline(always)]
pub fn bias_add(base: felt252, d: Sf) -> felt252 {
    if d.neg == 0 {
        base + d.m
    } else {
        base - d.m
    }
}

/// FixedMul on magnitudes: (a * b) >> 16.  Both operands non-negative.
pub fn fixed_mul_mag(a: felt252, b: felt252) -> felt252 {
    let p: u128 = (a * b).try_into().unwrap();
    (p / FRACUNIT_U128).into()
}

/// FixedDiv on magnitudes: (a << 16) / b.  `b` must be non-zero.
pub fn fixed_div_mag(a: felt252, b: felt252) -> felt252 {
    let na: u128 = a.try_into().unwrap();
    let nb: u128 = b.try_into().unwrap();
    if nb == 0 {
        return 0;
    }
    ((na * FRACUNIT_U128) / nb).into()
}

/// Signed FixedMul.
pub fn fixed_mul(a: Sf, b: Sf) -> Sf {
    let m = fixed_mul_mag(a.m, b.m);
    let neg = if a.neg == b.neg {
        0
    } else {
        1
    };
    Sf { m, neg }
}

/// Signed add.
pub fn sf_add(a: Sf, b: Sf) -> Sf {
    if a.neg == b.neg {
        Sf { m: a.m + b.m, neg: a.neg }
    } else if felt_ge(a.m, b.m) {
        Sf { m: a.m - b.m, neg: a.neg }
    } else {
        Sf { m: b.m - a.m, neg: b.neg }
    }
}

/// Doom's P_AproxDistance: max + min/2, on magnitudes.
///
/// NOTE: `/` on felt252 is *field* division, which is not integer division.
/// Halving therefore has to go through u128 (this is a trap the real `fixed`
/// crate must forbid outright: no `/` on felt252 anywhere).
pub fn approx_dist(dx: felt252, dy: felt252) -> felt252 {
    let a: u128 = dx.try_into().unwrap();
    let b: u128 = dy.try_into().unwrap();
    if a >= b {
        (a + b / 2).into()
    } else {
        (b + a / 2).into()
    }
}

// SPDX-License-Identifier: Apache-2.0
//! 16.16 fixed-point arithmetic, felt-first, with offset (biased) encoding.
//!
//! # Representation
//!
//! A [`Fixed`] wraps a single **non-negative** `felt252`:
//!
//! ```text
//! enc = raw + BIAS,   BIAS = 2^32,   raw = value * 65536
//! ```
//!
//! `raw` is the same 16.16 quantity as Doom's `fixed_t` (16 integer bits,
//! 16 fractional bits). Doom's `fixed_t` is an `int32`, so `raw` lives in
//! `[-2^31, 2^31)`; this crate reserves one extra bit of headroom and
//! guarantees correctness for `raw` in `(-2^32, 2^32)`, i.e. `enc` in
//! `(0, 2^33)`. Every value written to memory therefore stays **below
//! 2^72**, the threshold above which S0 measured +33 % on the
//! `range_check_9_9` component (docs/spikes/S0.md, S1.md §5.2).
//!
//! Why an offset instead of a raw (possibly negative) felt: S1 §5.2 measured
//! the same half-plane predicate at **18 steps** biased against **28 steps**
//! on raw negative felts, because a felt that may be negative has no cheap
//! sign test (it needs a `u256` round trip), and because any negative felt is
//! ~2^251 in memory and so always pays the +33 % penalty.
//!
//! # Cost model (S1 §5.1)
//!
//! `felt252` add = 1 step, `felt252` mul = 2 steps, a `u128` conversion = 6
//! steps, a `u128` division ~15 steps, and the signed comparison
//! ([`felt_ge`]) **11 steps measured here** (S1 §5.1 quotes 17 for the same
//! shape; the constant comparison bound saves the difference). Every public
//! function below documents its **measured** cost -- `bench/measure.py`, net
//! of the baseline that builds the same operands, on Scarb 2.16.0.
//!
//! # Forbidden
//!
//! `/` on `felt252` is a *field* division, not an integer division, and is
//! silently wrong (`x / 2` on an odd `x` gives a huge felt). This crate never
//! uses it: every halving/shift/division goes through `u128`.

/// Number of fractional bits (Doom's `FRACBITS`).
pub const FRACBITS: u32 = 16;

/// `1.0` as a raw 16.16 value (Doom's `FRACUNIT`).
pub const FRACUNIT_RAW: felt252 = 65536;

/// Offset applied to every stored value: `enc = raw + BIAS`.
///
/// `2^32` is exactly `65536 * 65536`, so `BIAS` is a whole number of map
/// units, which keeps [`to_units`] a single `u128` division.
pub const BIAS: felt252 = 0x100000000;

/// Comparison bias used by [`felt_ge`]: `2^71`, the largest power of two that
/// keeps `a - b + CMP_BIAS` strictly below the 2^72 penalty threshold.
pub const CMP_BIAS: felt252 = 0x800000000000000000;
const CMP_BIAS_U128: u128 = 0x800000000000000000;

/// Largest `enc` a well-formed [`Fixed`] may hold, exclusive (`2^33`).
pub const ENC_MAX: felt252 = 0x200000000;

/// `2^48 - 2^32`, the constant folded back into [`mul`]'s result.
const MUL_FIXUP: felt252 = 0xFFFF00000000;
/// `2^64`, the offset that makes [`mul`]'s product non-negative. It is a
/// multiple of 65536, so shifting the offset product right by 16 bits and
/// subtracting `2^48` reproduces an arithmetic shift (floor division).
const MUL_OFFSET: felt252 = 0x10000000000000000;

/// Doom's `MAXINT` as a raw 16.16 value (`FixedDiv` overflow result).
pub const RAW_MAX: felt252 = 0x7FFFFFFF;
/// Doom's `MININT` as a raw 16.16 value (`FixedDiv` overflow result).
pub const RAW_MIN: felt252 = -0x80000000;

/// A 16.16 fixed-point number stored as a non-negative, offset-encoded felt.
///
/// The field is public so that consumers can build `const` arrays of encoded
/// values without a function call, but it must always hold `raw + BIAS`;
/// use [`from_raw`] / [`from_units`] to build one and [`to_raw`] /
/// [`to_units`] to leave the encoding.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Fixed {
    pub enc: felt252,
}

/// `0.0`.
pub const ZERO: Fixed = Fixed { enc: BIAS };
/// `1.0` (Doom's `FRACUNIT`).
pub const FRACUNIT: Fixed = Fixed { enc: BIAS + FRACUNIT_RAW };
/// `0.5`.
pub const HALF: Fixed = Fixed { enc: BIAS + 32768 };

// ---------------------------------------------------------------------------
// The one comparison primitive
// ---------------------------------------------------------------------------

/// `a >= b` for two felts known to be in `[0, 2^71)`.
///
/// This is *the* comparison primitive of the whole geometry stack: one field
/// subtraction, one `u128` conversion and one `u128` comparison against a
/// constant. S1 §5.1 called 17 steps the floor for a signed comparison;
/// comparing against the constant bias instead of a second variable brings it
/// to 11. Sizing any function starts by counting its calls to this.
///
/// Panics (via `try_into`) if either argument is outside `[0, 2^71)`, which
/// is a caller bug: every encoded quantity in this workspace is bounded by
/// construction (`Fixed` < 2^33, `geom2d` half-plane sums < 2^54).
///
/// **Measured: 11 steps, 2 range checks.**
pub fn felt_ge(a: felt252, b: felt252) -> bool {
    let d: u128 = (a - b + CMP_BIAS).try_into().unwrap();
    d >= CMP_BIAS_U128
}

/// `2^64`: the bias of [`felt_ge_narrow`].
const NARROW_BIAS: felt252 = 0x10000000000000000;

/// `a >= b` for two felts whose difference is below `2^64` in magnitude
/// (`|a - b| < 2^64`), **with no panic path**: `a - b + 2^64` fits a `u64`
/// exactly when `a < b`, so one `u64` conversion is the whole test.
///
/// This is the comparison the hot loops of `doom_physics` use
/// (docs/spikes/S7.md). [`felt_ge`] keeps the wider `[0, 2^71)` domain and
/// its panic on a caller bug, but that panic is paid in bytecode at every
/// inlined use — a propagation path that stores the enclosing function's
/// whole return width in zero-padding — and it makes the enclosing function
/// panicking. This form compiles to **38 words per inlined site against 57**
/// and leaves the enclosing function `nopanic`-eligible. Outside its domain
/// the answer is meaningless but the function still returns; every `Fixed`
/// (below `2^33`) and every `geom2d` half-plane sum (below `2^54`) is well
/// inside it, so the `Fixed` comparisons below are built on it.
///
/// **Measured: 13 steps, 2.5 range checks** (`felt_ge`: 11 and 2).
pub fn felt_ge_narrow(a: felt252, b: felt252) -> bool {
    let r: Option<u64> = (a - b + NARROW_BIAS).try_into();
    match r {
        Option::Some(_) => false,
        Option::None => true,
    }
}

/// `felt252 -> u128` for a value the caller knows to be below `2^128`,
/// with no panic path: an out-of-domain value (a caller bug) reads as `0`
/// instead of aborting the proof. See [`felt_ge_narrow`] for why.
pub fn to_u128(v: felt252) -> u128 {
    let r: Option<u128> = v.try_into();
    match r {
        Option::Some(u) => u,
        Option::None => 0,
    }
}

// ---------------------------------------------------------------------------
// Boundary conversions
// ---------------------------------------------------------------------------

/// Encode a raw 16.16 value (Doom's `fixed_t`), which may be negative.
///
/// **Measured: 1 step.**
pub fn from_raw(raw: felt252) -> Fixed {
    Fixed { enc: raw + BIAS }
}

/// Decode to a raw 16.16 value. The result is a *possibly negative* felt and
/// must not be stored in the state: it is a boundary value only.
///
/// **Measured: 1 step.**
pub fn to_raw(a: Fixed) -> felt252 {
    a.enc - BIAS
}

/// Build from an integer number of map units (`n * FRACUNIT`).
///
/// **Measured: 3 steps.**
pub fn from_units(n: felt252) -> Fixed {
    Fixed { enc: n * FRACUNIT_RAW + BIAS }
}

/// Build from an integer number of map units given as `i64`.
///
/// Convenience for callers that hold a signed machine integer at a boundary
/// (test fixtures, WAD-derived data). Prefer [`from_units`] inside the
/// engine: it never leaves the field.
///
/// **Boundary helper, not benchmarked** (it is never on a hot path).
pub fn from_int(n: i64) -> Fixed {
    from_units(n.into())
}

/// Integer map units, rounded **down** (like Doom's `x >> FRACBITS`).
///
/// **Measured: 15 steps, 5 range checks.**
pub fn to_units(a: Fixed) -> felt252 {
    let w16: NonZero<u128> = 65536;
    let (q128, _) = DivRem::div_rem(to_u128(a.enc), w16);
    let q: felt252 = q128.into();
    // BIAS is exactly 65536 map units, so the shift of the bias is exact.
    q - 65536
}

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

/// `a + b`. No overflow check: the caller keeps the domain (see module docs).
///
/// **Measured: 1 step.**
pub fn add(a: Fixed, b: Fixed) -> Fixed {
    Fixed { enc: a.enc + b.enc - BIAS }
}

/// `a - b`.
///
/// **Measured: 1 step.**
pub fn sub(a: Fixed, b: Fixed) -> Fixed {
    Fixed { enc: a.enc - b.enc + BIAS }
}

/// `-a`.
///
/// **Measured: 2 steps.**
pub fn neg(a: Fixed) -> Fixed {
    Fixed { enc: BIAS + BIAS - a.enc }
}

/// `true` if `a < 0`.
///
/// **Measured: 15 steps, 2 range checks.**
pub fn is_neg(a: Fixed) -> bool {
    !felt_ge_narrow(a.enc, BIAS)
}

/// `|a|` as a non-negative raw felt (no re-encoding), for callers that need a
/// magnitude to multiply or divide.
///
/// **Measured: 15 steps, 2 range checks.**
pub fn magnitude(a: Fixed) -> felt252 {
    if felt_ge_narrow(a.enc, BIAS) {
        a.enc - BIAS
    } else {
        BIAS - a.enc
    }
}

/// `(a < 0, |a|)` in a single sign test: the shape every caller that needs
/// both the sign and the magnitude should use (`bam::point_to_angle`,
/// `blockmap`'s ray walk), instead of calling [`is_neg`] and [`magnitude`]
/// separately and paying for two.
///
/// **Measured: 16 steps, 2 range checks.**
pub fn split(a: Fixed) -> (bool, felt252) {
    if felt_ge_narrow(a.enc, BIAS) {
        (false, a.enc - BIAS)
    } else {
        (true, BIAS - a.enc)
    }
}

/// `|a|`.
///
/// **Measured: 14 steps, 2 range checks.**
pub fn abs(a: Fixed) -> Fixed {
    if felt_ge_narrow(a.enc, BIAS) {
        a
    } else {
        Fixed { enc: BIAS + BIAS - a.enc }
    }
}

/// `a >> 8` with C's semantics on a signed value: a division by 256
/// rounding toward minus infinity.
///
/// It exists because Doom pre-shifts its operands by 8 bits in
/// `P_InterceptVector` (and in the slide-move slopes) to keep the `int32`
/// intermediate products in range; reproducing the formula means
/// reproducing the shift. The encoding makes it free of sign tests: `BIAS`
/// is `2^32`, a multiple of 256, so shifting the encoded value and
/// subtracting `2^24` shifts the raw value.
///
/// **Measured: 15 steps, 5 range checks.**
pub fn shr8(a: Fixed) -> Fixed {
    let w8: NonZero<u128> = 256;
    let (q128, _) = DivRem::div_rem(to_u128(a.enc), w8);
    let q: felt252 = q128.into();
    Fixed { enc: q - 0x1000000 + BIAS }
}

/// `a * b`, i.e. Doom's `FixedMul`: the exact product shifted right by 16
/// bits, **rounding toward minus infinity** (an arithmetic shift, exactly
/// what `((int64_t) a * b) >> FRACBITS` does in C).
///
/// No sign test is needed: the product is offset by `2^64` (a multiple of
/// 65536) before the single `u128` division, and the offset is subtracted
/// back afterwards. Intermediates stay below 2^65.
///
/// **Measured: 18 steps, 5 range checks** -- exactly the 18 S1 §5.1
/// measured for the same operation on bare magnitudes, sign handling
/// included here.
pub fn mul(a: Fixed, b: Fixed) -> Fixed {
    let p = (a.enc - BIAS) * (b.enc - BIAS) + MUL_OFFSET;
    let w16: NonZero<u128> = 65536;
    let (q128, _) = DivRem::div_rem(to_u128(p), w16);
    let q: felt252 = q128.into();
    Fixed { enc: q - MUL_FIXUP }
}

/// `a / b`, i.e. Doom's `FixedDiv`: `(a << 16) / b` truncated **toward
/// zero**, with Doom's overflow guard — when `|a| >> 14 >= |b|` (which
/// includes every division by zero) the result saturates to `MAXINT` or
/// `MININT` according to the sign of the quotient, exactly like the C
/// original. It never panics.
///
/// `div` is the most expensive primitive of the stack; S1 §7 recommends
/// using it only where Doom does (intercept fractions, slide slopes) and
/// comparing cross products instead of dividing whenever two fractions only
/// have to be *ordered*.
///
/// **Measured: 77 steps, 12 range checks.** S1 §5.1 quotes 55 steps for a
/// division of two bare non-negative magnitudes; the extra 22 are the two
/// sign tests and Doom's overflow guard, which that figure did not include.
pub fn div(a: Fixed, b: Fixed) -> Fixed {
    let a_neg = !felt_ge_narrow(a.enc, BIAS);
    let b_neg = !felt_ge_narrow(b.enc, BIAS);
    let ma_f = if a_neg {
        BIAS - a.enc
    } else {
        a.enc - BIAS
    };
    let mb_f = if b_neg {
        BIAS - b.enc
    } else {
        b.enc - BIAS
    };
    let negative = a_neg != b_neg;
    // Doom writes the guard as `(abs(a) >> 14) >= abs(b)`; over integers that
    // is exactly `abs(a) >= abs(b) << 14`. Kept in the field: measured, the
    // whole `div` costs 77 steps this way, 86 with a `u128` division and 101
    // with a checked `u128` multiplication.
    if felt_ge_narrow(ma_f, mb_f * 16384) {
        // Doom's FixedDiv overflow branch (also catches mb == 0).
        return if negative {
            Fixed { enc: RAW_MIN + BIAS }
        } else {
            Fixed { enc: RAW_MAX + BIAS }
        };
    }
    // The guard above bounds the quotient by 2^30, so `ma_f << 16 < 2^48`.
    let num: u128 = to_u128(ma_f * 65536);
    // The guard also excludes `mb == 0`, so the divisor is non-zero here;
    // the fallback arm is unreachable and only keeps the function panic-free.
    let den_opt: Option<NonZero<u128>> = to_u128(mb_f).try_into();
    let den: NonZero<u128> = match den_opt {
        Option::Some(nz) => nz,
        Option::None => 1,
    };
    let (q128, _) = DivRem::div_rem(num, den);
    let q: felt252 = q128.into();
    if negative {
        Fixed { enc: BIAS - q }
    } else {
        Fixed { enc: BIAS + q }
    }
}

// ---------------------------------------------------------------------------
// Comparisons
// ---------------------------------------------------------------------------

/// `a >= b`. **Measured: 11 steps, 2 range checks.**
pub fn ge(a: Fixed, b: Fixed) -> bool {
    felt_ge_narrow(a.enc, b.enc)
}

/// `a > b`. **Measured: 11 steps, 2 range checks.**
pub fn gt(a: Fixed, b: Fixed) -> bool {
    !felt_ge_narrow(b.enc, a.enc)
}

/// `a <= b`. **Measured: 11 steps, 2 range checks.**
pub fn le(a: Fixed, b: Fixed) -> bool {
    felt_ge_narrow(b.enc, a.enc)
}

/// `a < b`. **Measured: 11 steps, 2 range checks.**
pub fn lt(a: Fixed, b: Fixed) -> bool {
    !felt_ge_narrow(a.enc, b.enc)
}

/// Smaller of the two. **Measured: 13 steps, 2 range checks** (25 for
/// `min` and `max` together).
pub fn min(a: Fixed, b: Fixed) -> Fixed {
    if felt_ge_narrow(a.enc, b.enc) {
        b
    } else {
        a
    }
}

/// Larger of the two. **Measured: 13 steps, 2 range checks** (25 for
/// `min` and `max` together).
pub fn max(a: Fixed, b: Fixed) -> Fixed {
    if felt_ge_narrow(a.enc, b.enc) {
        a
    } else {
        b
    }
}

// ---------------------------------------------------------------------------
// Operator sugar (one concrete impl each, no generic monomorphisation)
// ---------------------------------------------------------------------------

pub impl FixedAdd of Add<Fixed> {
    fn add(lhs: Fixed, rhs: Fixed) -> Fixed {
        add(lhs, rhs)
    }
}

pub impl FixedSub of Sub<Fixed> {
    fn sub(lhs: Fixed, rhs: Fixed) -> Fixed {
        sub(lhs, rhs)
    }
}

pub impl FixedMul of Mul<Fixed> {
    fn mul(lhs: Fixed, rhs: Fixed) -> Fixed {
        mul(lhs, rhs)
    }
}

pub impl FixedDiv of Div<Fixed> {
    fn div(lhs: Fixed, rhs: Fixed) -> Fixed {
        div(lhs, rhs)
    }
}

pub impl FixedNeg of Neg<Fixed> {
    fn neg(a: Fixed) -> Fixed {
        neg(a)
    }
}

pub impl FixedPartialOrd of PartialOrd<Fixed> {
    fn lt(lhs: Fixed, rhs: Fixed) -> bool {
        lt(lhs, rhs)
    }
    fn le(lhs: Fixed, rhs: Fixed) -> bool {
        le(lhs, rhs)
    }
    fn gt(lhs: Fixed, rhs: Fixed) -> bool {
        gt(lhs, rhs)
    }
    fn ge(lhs: Fixed, rhs: Fixed) -> bool {
        ge(lhs, rhs)
    }
}

#[cfg(test)]
mod tests;

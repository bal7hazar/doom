//! Lazily-reduced arithmetic for the FRI folds (Hellproof patch 0002, see `vendor/patches`).
//!
//! Starknet bills these classes by their range-check count (1 600 gas each, the binding VM
//! resource), and every reduced field operation of the vendored `fri_fold` pays for it: a
//! reduced M31 multiplication costs 3 range checks, a QM31 multiplication 16, the packed
//! `fri_fold` 28 and an M31 inversion 136. This module folds a whole subset (the `2^fold_step`
//! evaluations one query decommits) with plain `felt252` arithmetic on unreduced limbs — no
//! range check per node — and reduces modulo P only where the integer bounds require it. The
//! twiddle inverses of a layer come from one Montgomery batch inversion
//! (`fields::BatchInvertible`, already used by the vendored quotients) instead of one
//! exponentiation per twiddle.
//!
//! Equivalence with the vendored code: every node computes exactly
//! `fri_fold(v0, v1, itwid, alpha) = (v0 + v1) + alpha * itwid * (v0 - v1)` (the ibutterfly
//! followed by the random linear combination of `poly::utils::fri_fold`); only the moment of the
//! reduction modulo P differs. The invariant of a [`Lazy`] value is: each limb is a non-negative
//! integer below `2^e` (the bound exponent `e` tracked by [`fold_subset`]) and congruent modulo P
//! to the corresponding coordinate of the QM31 value the vendored code holds at the same node.
//! Since the whole computation happens in the prime field of the felt252 and every integer
//! stays below the prime (`2^241 < PRIME`), the congruences are exact and the final reduction
//! returns the same field element.
use bounded_int::{AddHelper, BoundedInt, DivRemHelper, MulHelper, add, bounded_int_mul, div_rem};
use crate::fields::m31::{M31, M31InnerT, M31Trait, P};
use crate::fields::qm31::{QM31, QM31Trait};

type ConstValue<const VALUE: felt252> = BoundedInt<VALUE, VALUE>;

const NZ_M31_P: NonZero<ConstValue<P>> = 0x7fffffff;
const SIXTEEN: ConstValue<16> = 16;

/// An unreduced QM31 `(a + b i) + (c + d i) u`, each limb a non-negative integer in a `felt252`.
#[derive(Copy, Drop)]
pub struct Lazy {
    pub a: felt252,
    pub b: felt252,
    pub c: felt252,
    pub d: felt252,
}

/// Number of fold levels computed on unreduced limbs before a reduction is required: three
/// levels from reduced inputs (`e = 31`) end below `2^241 < PRIME` (see [`fold_node`]).
const LEVELS_PER_RUN: felt252 = 3;

// Offsets added before a subtraction (`OFF_SUB_r`) and before the multiplication by the folding
// alpha (`OFF_MUL_r`) at level `r` of a run, whose inputs are bounded by `2^e_r`,
// `e_r = 31 + 70 r`. All are multiples of P (they do not change the value modulo P):
//   OFF_SUB_r = P * 2^(e_r - 30)  in [2^e_r, 2^(e_r + 1)),
//   OFF_MUL_r = P * 2^(e_r + 37)  in [2^(e_r + 67), 2^(e_r + 68)).
const OFF_SUB_0: felt252 = 0xfffffffe; // P * 2^1
const OFF_SUB_1: felt252 = 0x3fffffff800000000000000000; // P * 2^71
const OFF_SUB_2: felt252 = 0xfffffffe00000000000000000000000000000000000; // P * 2^141
const OFF_MUL_0: felt252 = 0x7fffffff00000000000000000; // P * 2^68
const OFF_MUL_1: felt252 = 0x1fffffffc0000000000000000000000000000000000; // P * 2^138
const OFF_MUL_2: felt252 =
    0x7fffffff0000000000000000000000000000000000000000000000000000; // P * 2^208

/// `P * P`: offset of a difference of two products of reduced values.
pub const PP: felt252 = 0x3fffffff00000001;

#[inline]
fn offsets(r: felt252) -> (felt252, felt252) {
    if r == 0 {
        (OFF_SUB_0, OFF_MUL_0)
    } else if r == 1 {
        (OFF_SUB_1, OFF_MUL_1)
    } else {
        (OFF_SUB_2, OFF_MUL_2)
    }
}

/// A reduced QM31 as a [`Lazy`] value (limbs below `2^31`).
#[inline]
pub fn lazy(v: QM31) -> Lazy {
    let [a, b, c, d] = v.to_fixed_array();
    Lazy { a: a.into(), b: b.into(), c: c.into(), d: d.into() }
}

/// `fri_fold(v0, v1, itwid, alpha) = (v0 + v1) + alpha * (itwid * (v0 - v1))` on unreduced
/// limbs bounded by `2^e` (`e = 31 + 70 r`), with `itwid` and `alpha` reduced.
///
/// Bounds: `d = v0 - v1 + OFF_SUB_r < 2^(e+2)`; `f1 = itwid * d < 2^(e+33)`; in the product by
/// alpha each limb is a signed sum of products `f1_limb * alpha_limb < 2^(e+64)` with at most 5
/// negative and at most 7 positive terms (the coefficients of `u^2 = 2 + i`), so adding
/// `OFF_MUL_r >= 5 * 2^(e+64)` keeps it non-negative and below `2^(e+68) + 2^(e+67)`; adding
/// `f0 = v0 + v1 < 2^(e+1)` keeps the result below `2^(e+70)`.
#[inline]
fn fold_node(v0: Lazy, v1: Lazy, itwid: M31, alpha: QM31, off_sub: felt252, off_mul: felt252) -> Lazy {
    let t: felt252 = itwid.into();
    // f1 = itwid * (v0 - v1): (a + b i) + (c + d i) u.
    let a = (v0.a - v1.a + off_sub) * t;
    let b = (v0.b - v1.b + off_sub) * t;
    let c = (v0.c - v1.c + off_sub) * t;
    let d = (v0.d - v1.d + off_sub) * t;
    // alpha = (x0 + x1 i) + (x2 + x3 i) u, reduced.
    let [x0, x1, x2, x3] = alpha.to_fixed_array();
    let x0: felt252 = x0.into();
    let x1: felt252 = x1.into();
    let x2: felt252 = x2.into();
    let x3: felt252 = x3.into();
    // alpha * f1 with u^2 = 2 + i (same expansion as `qm31::naive::unreduced::mul_qm_unreduced`):
    //   re  = Re(A A') + 2 Re(C C') - Im(C C')
    //   im  = Im(A A') + Re(C C') + 2 Im(C C')
    //   ure = Re(A C') + Re(C A'),  uim = Im(A C') + Im(C A')
    // where A = a + b i, C = c + d i, A' = x0 + x1 i, C' = x2 + x3 i.
    let re = a * x0 - b * x1 + 2 * (c * x2 - d * x3) - (c * x3 + d * x2) + off_mul;
    let im = a * x1 + b * x0 + (c * x2 - d * x3) + 2 * (c * x3 + d * x2) + off_mul;
    let ure = a * x2 - b * x3 + c * x0 - d * x1 + off_mul;
    let uim = a * x3 + b * x2 + c * x1 + d * x0 + off_mul;
    // + f0 = v0 + v1.
    Lazy {
        a: re + v0.a + v1.a, b: im + v0.b + v1.b, c: ure + v0.c + v1.c, d: uim + v0.d + v1.d,
    }
}

/// Reduces a limb below `2^128` (1 + 3 range checks).
#[inline]
pub fn reduce_narrow(x: felt252) -> M31 {
    M31Trait::reduce_u128(x.try_into().unwrap())
}

impl M31MulSixteen of MulHelper<M31InnerT, ConstValue<16>> {
    type Result = BoundedInt<0, { 16 * (P - 1) }>;
}
impl M31AddSixteenFold of AddHelper<BoundedInt<0, { 16 * (P - 1) }>, M31InnerT> {
    type Result = BoundedInt<0, { 17 * (P - 1) }>;
}
impl DivRemSeventeenP of DivRemHelper<BoundedInt<0, { 17 * (P - 1) }>, ConstValue<P>> {
    type DivT = BoundedInt<0, 16>;
    type RemT = M31InnerT;
}

/// Reduces a limb below `2^248` (3 + 3 + 3 + 3 range checks): `x = hi * 2^128 + lo` and
/// `2^128 = 2^(4 * 31 + 4) ≡ 16 (mod P)`.
#[inline]
pub fn reduce_wide(x: felt252) -> M31 {
    let u256 { low, high } = x.into();
    let lo = M31Trait::reduce_u128(low);
    let hi = M31Trait::reduce_u128(high);
    let t = add(bounded_int_mul(hi.inner, SIXTEEN), lo.inner);
    let (_, r) = div_rem(t, NZ_M31_P);
    M31Trait::new(r)
}

#[inline]
fn reduce_narrow_qm31(v: Lazy) -> QM31 {
    QM31Trait::from_fixed_array(
        [reduce_narrow(v.a), reduce_narrow(v.b), reduce_narrow(v.c), reduce_narrow(v.d)],
    )
}

#[inline]
fn reduce_wide_qm31(v: Lazy) -> QM31 {
    QM31Trait::from_fixed_array(
        [reduce_wide(v.a), reduce_wide(v.b), reduce_wide(v.c), reduce_wide(v.d)],
    )
}

/// Folds the `2^k` evaluations of one subset into one value: level `l` folds consecutive pairs
/// with `fri_fold(v0, v1, itwiddles.next(), alpha_powers[l])`, exactly like the vendored
/// `fold_coset` (which consumed `x.inverse()` per pair and squared the alpha per level). The
/// inverse twiddles are consumed from `itwiddles` in the same order (level by level, pairs in
/// order); `alpha_powers` must hold `alpha, alpha^2, alpha^4, ...` (at least `k` of them).
pub fn fold_subset(
    evals: Span<QM31>, ref itwiddles: Span<M31>, mut alpha_powers: Span<QM31>,
) -> QM31 {
    let mut cur: Array<Lazy> = array![];
    for e in evals {
        cur.append(lazy(*e));
    }
    // Levels since the last reduction; the limbs of `cur` are below `2^(31 + 70 r)`.
    let mut r: felt252 = 0;
    while cur.len() != 1 {
        if r == LEVELS_PER_RUN {
            let mut reduced = array![];
            for v in cur.span() {
                reduced.append(lazy(reduce_wide_qm31(*v)));
            }
            cur = reduced;
            r = 0;
        }
        let (off_sub, off_mul) = offsets(r);
        let alpha = *alpha_powers.pop_front().unwrap();
        let mut pairs = cur.span();
        let mut next = array![];
        while let Some(v0) = pairs.pop_front() {
            let v1 = pairs.pop_front().unwrap();
            let itwid = *itwiddles.pop_front().unwrap();
            next.append(fold_node(*v0, *v1, itwid, alpha, off_sub, off_mul));
        }
        cur = next;
        r += 1;
    }
    let out = *cur.span().pop_front().unwrap();
    if r == 0 {
        // Only possible for an empty fold (a single evaluation): the limbs are reduced.
        reduce_narrow_qm31(out)
    } else if r == 1 {
        // Below 2^101.
        reduce_narrow_qm31(out)
    } else {
        // Below 2^171 or 2^241.
        reduce_wide_qm31(out)
    }
}

/// `x` coordinate of `p + q` for reduced points, as an unreduced limb below `2 P^2`
/// (`x_p x_q - y_p y_q + P^2`).
#[inline]
pub fn lazy_add_x(px: felt252, py: felt252, qx: felt252, qy: felt252) -> felt252 {
    px * qx - py * qy + PP
}

/// `y` coordinate of `p + q` for reduced points, as an unreduced limb below `2 P^2`.
#[inline]
pub fn lazy_add_y(px: felt252, py: felt252, qx: felt252, qy: felt252) -> felt252 {
    px * qy + py * qx
}

/// `2 x^2 - 1` (`CirclePointTrait::double_x`) for a reduced `x`, as an unreduced limb below
/// `2^63` (`2 x^2 + (P - 1)`).
#[inline]
pub fn lazy_double_x(x: felt252) -> felt252 {
    2 * x * x + (P - 1)
}

// SPDX-License-Identifier: Apache-2.0
//! Unit tests: encoding invariants, edge cases, algebraic properties and the
//! Python-generated reference vectors (`tests/vectors.cairo`, produced by
//! `scripts/gen_vectors.py`).
//!
//! Everything that loops lives in this *unit* test target: `scarb test`
//! computes gas for the `tests/` integration target even though the
//! workspace sets `enable-gas = false`, and Cairo compiles `while` into
//! recursive functions, which makes that computation fail with
//! "found an unexpected cycle during cost computation". The integration
//! target is therefore kept loop-free (see `tests/lib.cairo`).

mod vectors;
use vectors::{DIV_A_ENC, DIV_B_ENC, DIV_R_ENC, MUL_A_ENC, MUL_B_ENC, MUL_R_ENC};
use super::{
    BIAS, ENC_MAX, FRACUNIT, FRACUNIT_RAW, Fixed, HALF, RAW_MAX, RAW_MIN, ZERO, abs, add, div,
    felt_ge, from_int, from_raw, from_units, ge, gt, is_neg, le, lt, magnitude, max, min, mul, neg,
    split, sub, to_raw, to_units,
};

/// Deterministic pseudo-random raw values in `(-2^31, 2^31)`, from a
/// multiplicative LCG folded into a signed range.
fn lcg(state: u64) -> u64 {
    // Numerical Recipes LCG constants, mod 2^32.
    ((state * 1664525 + 1013904223) % 0x100000000)
}

fn sample_raw(i: u64) -> felt252 {
    let s = lcg(i * 2654435761 % 0x100000000);
    let v: felt252 = (s % 0x100000000).into();
    v - 0x80000000
}

/// Deterministic pseudo-random raw values in `(-2^24, 2^24)`, i.e. map
/// coordinates of at most +/- 256 units: small enough that products and sums
/// of three of them stay inside the documented domain.
fn sample_small_raw(i: u64) -> felt252 {
    let s = lcg(i * 2654435761 % 0x100000000);
    let v: felt252 = (s % 0x2000000).into();
    v - 0x1000000
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

#[test]
fn test_encoding_is_the_offset_of_the_raw_value() {
    assert(ZERO.enc == BIAS, 'zero is the bias');
    assert(FRACUNIT.enc == BIAS + FRACUNIT_RAW, 'one is bias+65536');
    assert(from_units(1) == FRACUNIT, 'from_units(1) == FRACUNIT');
    assert(HALF.enc == BIAS + 32768, 'half is bias+32768');
    assert(from_raw(0) == ZERO, 'from_raw(0) is zero');
}

#[test]
fn test_raw_roundtrip_including_negatives() {
    let mut i: u64 = 0;
    while i != 64 {
        let raw = sample_raw(i);
        assert(to_raw(from_raw(raw)) == raw, 'raw roundtrip');
        i += 1;
    }
    assert(to_raw(from_raw(-1)) == -1, 'roundtrip -1');
    assert(to_raw(from_raw(RAW_MIN)) == RAW_MIN, 'roundtrip RAW_MIN');
    assert(to_raw(from_raw(RAW_MAX)) == RAW_MAX, 'roundtrip RAW_MAX');
}

#[test]
fn test_every_encoded_value_stays_below_2_pow_33() {
    // Provability invariant (A7 / S1 §5.2): nothing reaches 2^72.
    let extremes = array![
        from_raw(RAW_MIN), from_raw(RAW_MAX), from_units(-32768), from_units(32767), ZERO,
    ];
    let mut i: u32 = 0;
    while i != extremes.len() {
        let v = *extremes.at(i);
        assert(felt_ge(v.enc, 0), 'enc is non-negative');
        assert(!felt_ge(v.enc, ENC_MAX), 'enc < 2^33');
        i += 1;
    }
}

#[test]
fn test_units_conversions() {
    assert(to_units(from_units(0)) == 0, 'units 0');
    assert(to_units(from_units(7)) == 7, 'units 7');
    assert(to_units(from_units(-7)) == -7, 'units -7');
    assert(to_units(from_int(-32768)) == -32768, 'units -32768');
    assert(to_units(from_int(32767)) == 32767, 'units 32767');
    // to_units floors, like `>> FRACBITS` in C.
    assert(to_units(from_raw(65535)) == 0, 'floor 0.99');
    assert(to_units(from_raw(-1)) == -1, 'floor -0.00001');
    assert(to_units(from_raw(-65537)) == -2, 'floor -1.00001');
}

#[test]
fn test_from_int_matches_from_units() {
    assert(from_int(-5) == from_units(-5), 'i64 boundary matches');
    assert(from_int(0) == ZERO, 'i64 zero');
}

// ---------------------------------------------------------------------------
// felt_ge, the comparison primitive
// ---------------------------------------------------------------------------

#[test]
fn test_felt_ge_total_order() {
    assert(felt_ge(0, 0), 'ge reflexive');
    assert(felt_ge(1, 0), '1 >= 0');
    assert(!felt_ge(0, 1), 'not 0 >= 1');
    // Near the domain edge (2^71 - 1) the predicate is still exact.
    let hi: felt252 = 0x7FFFFFFFFFFFFFFFFF;
    assert(felt_ge(hi, 0), 'hi >= 0');
    assert(!felt_ge(0, hi), 'not 0 >= hi');
    assert(felt_ge(hi, hi), 'hi >= hi');
}

#[test]
#[should_panic]
fn test_felt_ge_panics_outside_its_domain() {
    // 2^88 is outside [0, 2^71): the difference underflows the comparison
    // bias and `try_into` refuses it instead of returning a wrong answer.
    felt_ge(0, 0x100000000000000000000000);
}

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

#[test]
fn test_add_sub_neg_edge_cases() {
    assert(add(ZERO, ZERO) == ZERO, '0+0');
    assert(add(FRACUNIT, neg(FRACUNIT)) == ZERO, '1-1');
    assert(sub(ZERO, FRACUNIT) == from_units(-1), '0-1');
    assert(neg(ZERO) == ZERO, '-0 == 0');
    assert(neg(neg(from_units(3))) == from_units(3), 'double negation');
    assert(add(from_units(3), from_units(4)) == from_units(7), '3+4');
    assert(sub(from_units(3), from_units(4)) == from_units(-1), '3-4');
}

#[test]
fn test_add_is_associative_and_commutative() {
    let mut i: u64 = 0;
    while i != 32 {
        let a = from_raw(sample_raw(i));
        let b = from_raw(sample_raw(i + 100));
        let c = from_raw(sample_raw(i + 200));
        assert(add(a, b) == add(b, a), 'add commutes');
        assert(add(add(a, b), c) == add(a, add(b, c)), 'add associates');
        assert(sub(add(a, b), b) == a, 'sub inverts add');
        i += 1;
    }
}

#[test]
fn test_abs_magnitude_is_neg() {
    assert(!is_neg(ZERO), '0 is not negative');
    assert(is_neg(from_units(-1)), '-1 is negative');
    assert(!is_neg(from_raw(1)), '+1 raw is not negative');
    assert(abs(from_units(-5)) == from_units(5), 'abs(-5)');
    assert(abs(from_units(5)) == from_units(5), 'abs(5)');
    assert(abs(ZERO) == ZERO, 'abs(0)');
    assert(magnitude(from_units(-5)) == 5 * FRACUNIT_RAW, 'magnitude(-5)');
    assert(magnitude(from_units(5)) == 5 * FRACUNIT_RAW, 'magnitude(5)');
    assert(magnitude(ZERO) == 0, 'magnitude(0)');
}

#[test]
fn test_split_returns_sign_and_magnitude() {
    let (n1, m1) = split(from_units(-5));
    assert(n1 && m1 == 5 * FRACUNIT_RAW, 'split(-5)');
    let (n2, m2) = split(from_units(5));
    assert(!n2 && m2 == 5 * FRACUNIT_RAW, 'split(5)');
    let (n3, m3) = split(ZERO);
    assert(!n3 && m3 == 0, 'split(0) is positive');
    let (n4, m4) = split(from_raw(-1));
    assert(n4 && m4 == 1, 'split(-1 ulp)');
}

#[test]
fn test_mul_reference_and_identities() {
    assert(mul(FRACUNIT, FRACUNIT) == FRACUNIT, '1*1');
    assert(mul(ZERO, from_units(1234)) == ZERO, '0*x');
    assert(mul(from_units(3), from_units(4)) == from_units(12), '3*4');
    assert(mul(from_units(-3), from_units(4)) == from_units(-12), '-3*4');
    assert(mul(from_units(-3), from_units(-4)) == from_units(12), '-3*-4');
    assert(mul(HALF, from_units(2)) == FRACUNIT, '0.5*2');
    assert(mul(HALF, HALF) == from_raw(16384), '0.5*0.5');
    assert(mul(from_units(7), FRACUNIT) == from_units(7), 'x*1');
}

#[test]
fn test_mul_rounds_toward_minus_infinity_like_an_arithmetic_shift() {
    // 1 * 0.5 ulp: raw 1 * raw 32768 = 32768, >> 16 = 0.
    assert(mul(from_raw(1), from_raw(32768)) == from_raw(0), 'positive truncates to 0');
    // -1 ulp * 0.5: -32768 >> 16 = -1 (floor), not 0 (truncation).
    assert(mul(from_raw(-1), from_raw(32768)) == from_raw(-1), 'negative floors to -1');
    assert(mul(from_raw(-1), from_raw(65536)) == from_raw(-1), 'exact negative');
}

#[test]
fn test_mul_is_commutative() {
    let mut i: u64 = 0;
    while i != 32 {
        // Keep operands small enough that the product stays in range.
        let a = from_raw(sample_small_raw(i));
        let b = from_raw(sample_small_raw(i + 7));
        assert(mul(a, b) == mul(b, a), 'mul commutes');
        i += 1;
    }
}

#[test]
fn test_div_reference_values() {
    assert(div(from_units(6), from_units(2)) == from_units(3), '6/2');
    assert(div(from_units(-6), from_units(2)) == from_units(-3), '-6/2');
    assert(div(from_units(6), from_units(-2)) == from_units(-3), '6/-2');
    assert(div(from_units(-6), from_units(-2)) == from_units(3), '-6/-2');
    assert(div(ZERO, from_units(5)) == ZERO, '0/5');
    assert(div(FRACUNIT, from_units(2)) == HALF, '1/2');
}

#[test]
fn test_div_truncates_toward_zero() {
    // 1 / 3 = 0.333.. -> 21845.33 -> 21845 ; -1/3 -> -21845 (toward zero).
    assert(div(FRACUNIT, from_units(3)) == from_raw(21845), '1/3');
    assert(div(from_units(-1), from_units(3)) == from_raw(-21845), '-1/3');
}

#[test]
fn test_div_overflow_guard_matches_doom() {
    // |a| >> 14 >= |b| saturates instead of overflowing (Doom's FixedDiv).
    assert(div(from_units(100000), from_raw(1)) == from_raw(RAW_MAX), 'saturates high');
    assert(div(from_units(-100000), from_raw(1)) == from_raw(RAW_MIN), 'saturates low');
    // Division by zero takes the same branch: no panic, ever.
    assert(div(FRACUNIT, ZERO) == from_raw(RAW_MAX), '1/0 saturates');
    assert(div(from_units(-1), ZERO) == from_raw(RAW_MIN), '-1/0 saturates');
    assert(div(ZERO, ZERO) == from_raw(RAW_MAX), '0/0 saturates');
}

#[test]
fn test_div_then_mul_is_close_to_the_numerator() {
    // Property: |mul(div(a, b), b) - a| <= 1 ulp * |b| for well-scaled inputs.
    let a = from_units(10);
    let b = from_units(4);
    let q = div(a, b);
    assert(mul(q, b) == a, '10/4*4 == 10');
}

// ---------------------------------------------------------------------------
// Comparisons
// ---------------------------------------------------------------------------

#[test]
fn test_comparisons_edge_cases() {
    let a = from_units(-3);
    let b = ZERO;
    let c = from_units(3);
    assert(lt(a, b) && lt(b, c) && lt(a, c), 'strict order');
    assert(le(a, a) && ge(a, a), 'reflexive');
    assert(!gt(a, a) && !lt(a, a), 'irreflexive');
    assert(gt(c, a), 'gt');
    assert(min(a, c) == a && max(a, c) == c, 'min/max');
    assert(min(a, a) == a && max(c, c) == c, 'min/max equal');
}

#[test]
fn test_order_is_translation_invariant() {
    let mut i: u64 = 0;
    while i != 32 {
        let a = from_raw(sample_small_raw(i));
        let b = from_raw(sample_small_raw(i + 11));
        let c = from_raw(sample_small_raw(i + 23));
        assert(lt(a, b) == lt(add(a, c), add(b, c)), 'translation invariance');
        assert(lt(a, b) == gt(neg(a), neg(b)), 'negation reverses');
        i += 1;
    }
}

#[test]
fn test_operator_sugar_matches_the_functions() {
    let a = from_units(7);
    let b = from_units(-3);
    assert(a + b == add(a, b), 'Add impl');
    assert(a - b == sub(a, b), 'Sub impl');
    assert(a * b == mul(a, b), 'Mul impl');
    assert(a / b == div(a, b), 'Div impl');
    assert(-a == neg(a), 'Neg impl');
    assert((b < a) == lt(b, a), 'PartialOrd lt');
    assert((b <= a) == le(b, a), 'PartialOrd le');
    assert((a > b) == gt(a, b), 'PartialOrd gt');
    assert((a >= b) == ge(a, b), 'PartialOrd ge');
}

#[test]
fn test_serde_roundtrip_keeps_values_below_the_provability_bound() {
    let v = from_units(-1234);
    let mut out: Array<felt252> = array![];
    Serde::serialize(@v, ref out);
    assert(out.len() == 1, 'one felt per Fixed');
    let word: Fixed = Fixed { enc: *out.at(0) };
    assert(word == v, 'serde roundtrip');
    assert(!felt_ge(*out.at(0), ENC_MAX), 'serialized word < 2^33');
}

// ---------------------------------------------------------------------------
// Reference vectors (Python arbitrary-precision integers)
// ---------------------------------------------------------------------------

#[test]
fn test_mul_matches_python_reference_vectors() {
    let a = MUL_A_ENC.span();
    let b = MUL_B_ENC.span();
    let r = MUL_R_ENC.span();
    assert(a.len() == r.len() && b.len() == r.len(), 'vector lengths agree');
    assert(r.len() > 100, 'enough vectors');
    let mut i: u32 = 0;
    while i != r.len() {
        let got = mul(Fixed { enc: *a.at(i) }, Fixed { enc: *b.at(i) });
        assert(got.enc == *r.at(i), 'mul matches reference');
        i += 1;
    }
}

#[test]
fn test_div_matches_python_reference_vectors() {
    let a = DIV_A_ENC.span();
    let b = DIV_B_ENC.span();
    let r = DIV_R_ENC.span();
    assert(a.len() == r.len() && b.len() == r.len(), 'vector lengths agree');
    assert(r.len() > 100, 'enough vectors');
    let mut i: u32 = 0;
    while i != r.len() {
        let got = div(Fixed { enc: *a.at(i) }, Fixed { enc: *b.at(i) });
        assert(got.enc == *r.at(i), 'div matches reference');
        i += 1;
    }
}

#[test]
fn test_every_reference_vector_stays_inside_the_provable_domain() {
    let all = array![
        MUL_A_ENC.span(), MUL_B_ENC.span(), MUL_R_ENC.span(), DIV_A_ENC.span(), DIV_B_ENC.span(),
        DIV_R_ENC.span(),
    ];
    let mut k: u32 = 0;
    while k != all.len() {
        let s = *all.at(k);
        let mut i: u32 = 0;
        while i != s.len() {
            assert(felt_ge(*s.at(i), 0), 'non-negative');
            assert(!felt_ge(*s.at(i), ENC_MAX), 'below 2^33');
            i += 1;
        }
        k += 1;
    }
}

// SPDX-License-Identifier: Apache-2.0
//! Integration tests: the public API as an external consumer sees it.
//!
//! This target must stay **loop-free**. `scarb test` computes gas for the
//! integration target even though the workspace disables gas, and Cairo
//! lowers `while` into recursive functions, which makes that computation
//! fail ("found an unexpected cycle during cost computation"). Everything
//! that iterates lives in the unit-test target (`src/tests.cairo`).

use fixed::{
    BIAS, FRACUNIT, FRACUNIT_RAW, Fixed, HALF, ZERO, abs, add, div, felt_ge, from_int, from_raw,
    from_units, ge, gt, is_neg, le, lt, magnitude, max, min, mul, neg, sub, to_raw, to_units,
};

#[test]
fn test_public_api_is_usable_from_outside_the_crate() {
    let a: Fixed = from_units(3);
    let b: Fixed = from_int(-4);

    assert(add(a, b) == from_units(-1), 'add');
    assert(sub(a, b) == from_units(7), 'sub');
    assert(mul(a, b) == from_units(-12), 'mul');
    assert(div(from_units(-12), a) == b, 'div');
    assert(neg(a) == from_units(-3), 'neg');
    assert(abs(b) == from_units(4), 'abs');
    assert(magnitude(b) == 4 * FRACUNIT_RAW, 'magnitude');
    assert(is_neg(b) && !is_neg(a), 'is_neg');
    assert(min(a, b) == b && max(a, b) == a, 'min/max');
    assert(lt(b, a) && le(b, a) && gt(a, b) && ge(a, b), 'comparisons');
    assert(to_units(a) == 3, 'to_units');
    assert(to_raw(from_raw(-7)) == -7, 'raw roundtrip');
    assert(ZERO.enc == BIAS, 'ZERO');
    assert(add(HALF, HALF) == FRACUNIT, 'HALF + HALF');
    assert(felt_ge(1, 0), 'felt_ge');
}

#[test]
fn test_operator_sugar_is_exported() {
    let a: Fixed = from_units(10);
    let b: Fixed = from_units(4);
    assert(a + b == from_units(14), 'Add');
    assert(a - b == from_units(6), 'Sub');
    assert(a * b == from_units(40), 'Mul');
    assert(a / b == from_units(2) + HALF, 'Div');
    assert(-a == from_units(-10), 'Neg');
    assert(b < a && b <= a && a > b && a >= b, 'PartialOrd');
}

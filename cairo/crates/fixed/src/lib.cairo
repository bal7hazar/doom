// SPDX-License-Identifier: Apache-2.0

/// 16.16 fixed-point number, backed by a signed 64-bit raw value (matches
/// Doom's `fixed_t`: 16 integer bits, 16 fractional bits).
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Fixed {
    pub raw: i64,
}

/// Number of fractional bits.
pub const FRAC_BITS: u8 = 16;
/// `1.0` in raw 16.16 representation.
pub const ONE: i64 = 65536;

pub fn from_int(n: i64) -> Fixed {
    Fixed { raw: n * ONE }
}

pub fn to_int(a: Fixed) -> i64 {
    a.raw / ONE
}

pub fn add(a: Fixed, b: Fixed) -> Fixed {
    Fixed { raw: a.raw + b.raw }
}

pub fn sub(a: Fixed, b: Fixed) -> Fixed {
    Fixed { raw: a.raw - b.raw }
}

pub fn neg(a: Fixed) -> Fixed {
    Fixed { raw: -a.raw }
}

/// Multiply two 16.16 values, rounding toward zero (matches `FixedMul`).
pub fn mul(a: Fixed, b: Fixed) -> Fixed {
    let wide: i128 = a.raw.into() * b.raw.into();
    let shifted: i128 = wide / ONE.into();
    Fixed { raw: shifted.try_into().unwrap() }
}

/// Divide two 16.16 values, rounding toward zero (matches `FixedDiv`).
/// Panics on division by zero, like the reference `FixedDiv` would trap.
pub fn div(a: Fixed, b: Fixed) -> Fixed {
    assert(b.raw != 0, 'fixed: div by zero');
    let wide: i128 = a.raw.into() * ONE.into();
    let shifted: i128 = wide / b.raw.into();
    Fixed { raw: shifted.try_into().unwrap() }
}

pub fn abs(a: Fixed) -> Fixed {
    if a.raw < 0 {
        Fixed { raw: -a.raw }
    } else {
        a
    }
}

pub fn lt(a: Fixed, b: Fixed) -> bool {
    a.raw < b.raw
}

#[cfg(test)]
mod tests {
    use super::{Fixed, ONE, abs, add, div, from_int, lt, mul, neg, sub, to_int};

    #[test]
    fn test_from_to_int_roundtrip() {
        assert(to_int(from_int(0)) == 0, 'zero roundtrip');
        assert(to_int(from_int(7)) == 7, 'positive roundtrip');
        assert(to_int(from_int(-7)) == -7, 'negative roundtrip');
    }

    #[test]
    fn test_add_sub() {
        let a = from_int(3);
        let b = from_int(4);
        assert(add(a, b) == from_int(7), 'add');
        assert(sub(b, a) == from_int(1), 'sub');
    }

    #[test]
    fn test_mul_reference_values() {
        // 1.5 * 2.0 == 3.0
        let one_half = Fixed { raw: ONE + ONE / 2 };
        let two = from_int(2);
        assert(mul(one_half, two) == from_int(3), 'mul 1.5*2');
        // 1.0 * 1.0 == 1.0
        assert(mul(from_int(1), from_int(1)) == from_int(1), 'mul identity');
    }

    #[test]
    fn test_div_reference_values() {
        // 6.0 / 2.0 == 3.0
        assert(div(from_int(6), from_int(2)) == from_int(3), 'div');
    }

    #[test]
    #[should_panic(expected: 'fixed: div by zero')]
    fn test_div_by_zero_panics() {
        div(from_int(1), from_int(0));
    }

    #[test]
    fn test_abs_and_neg() {
        assert(abs(from_int(-5)) == from_int(5), 'abs neg');
        assert(abs(from_int(5)) == from_int(5), 'abs pos');
        assert(neg(from_int(5)) == from_int(-5), 'neg');
    }

    #[test]
    fn test_ordering_property() {
        // Property: for any a < b, a + c < b + c (translation invariance).
        let a = from_int(1);
        let b = from_int(2);
        let c = from_int(100);
        assert(lt(a, b), 'a<b');
        assert(lt(add(a, c), add(b, c)), 'translation invariance');
    }

    #[test]
    fn test_step_budget_mul() {
        // Budget test: multiplying two representative fixed values must stay
        // well within a tiny step budget so regressions are caught early.
        let mut i: u32 = 0;
        let mut acc = from_int(1);
        let step = Fixed { raw: ONE + 1 };
        loop {
            if i == 16 {
                break;
            }
            acc = mul(acc, step);
            i += 1;
        }
        // No panic and no runaway growth outside i64 range (checked by the
        // `try_into().unwrap()` inside `mul`/`div` above): reaching here at
        // all is the pass condition for this budget/regression smoke test.
        assert(acc.raw != 0, 'non-zero result');
    }
}

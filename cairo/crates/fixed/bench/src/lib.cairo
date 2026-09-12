// SPDX-License-Identifier: Apache-2.0
//! Step-cost benchmark for the `fixed` crate.
//!
//! `main(op, n)` runs `n` iterations of one operation. The cost of the
//! operation is obtained by **differencing** two runs (S1 §3.1):
//!
//! ```text
//! cost(op) = (steps(op, 2N) - steps(op, N)) / N
//! ```
//!
//! which cancels bootstrap, argument deserialization and output
//! serialization.
//!
//! **Every operand varies with the loop counter**, otherwise the compiler
//! hoists the whole call out of the loop and the measurement is
//! meaningless. Each operation is therefore measured against the baseline op
//! that builds the same operands and does nothing else (`base` in
//! `budgets.json`):
//!
//! * op 0 -- bare loop;
//! * op 1 -- two-operand baseline (`a`, `b`), used by everything below;
//! * op 2 -- one-operand baseline (`a`).
//!
//! The accumulator is returned so that nothing can be optimized away.

use fixed::{
    BIAS, Fixed, abs, add, div, felt_ge, from_units, ge, is_neg, magnitude, max, min, mul, neg,
    split, sub, to_units,
};

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    // Operands around 8.5 and -3.25 units, moving one ulp per iteration.
    let a0: felt252 = 4295524352;
    let b0: felt252 = 4294754304;

    if op == 0 { // bare loop
        while i != n {
            i += 1;
        }
    } else if op == 1 {
        // two-operand baseline
        while i != n {
            let a = Fixed { enc: a0 + i.into() };
            let b = Fixed { enc: b0 + i.into() };
            acc += a.enc + b.enc;
            i += 1;
        }
    } else if op == 2 {
        // one-operand baseline
        while i != n {
            let a = Fixed { enc: a0 + i.into() };
            acc += a.enc;
            i += 1;
        }
    } else if op == 3 {
        while i != n {
            let a = Fixed { enc: a0 + i.into() };
            let b = Fixed { enc: b0 + i.into() };
            acc += felt_ge(a.enc, b.enc).into();
            i += 1;
        }
    } else if op == 4 {
        while i != n {
            let a = Fixed { enc: a0 + i.into() };
            let b = Fixed { enc: b0 + i.into() };
            acc += add(a, b).enc;
            i += 1;
        }
    } else if op == 5 {
        while i != n {
            let a = Fixed { enc: a0 + i.into() };
            let b = Fixed { enc: b0 + i.into() };
            acc += sub(a, b).enc;
            i += 1;
        }
    } else if op == 6 {
        while i != n {
            let a = Fixed { enc: a0 + i.into() };
            acc += neg(a).enc;
            i += 1;
        }
    } else if op == 7 {
        while i != n {
            let a = Fixed { enc: a0 + i.into() };
            let b = Fixed { enc: b0 + i.into() };
            acc += mul(a, b).enc;
            i += 1;
        }
    } else if op == 8 {
        while i != n {
            let a = Fixed { enc: a0 + i.into() };
            let b = Fixed { enc: b0 + i.into() };
            acc += div(a, b).enc;
            i += 1;
        }
    } else if op == 9 {
        while i != n {
            let b = Fixed { enc: b0 + i.into() };
            acc += abs(b).enc;
            i += 1;
        }
    } else if op == 10 {
        while i != n {
            let b = Fixed { enc: b0 + i.into() };
            acc += magnitude(b);
            i += 1;
        }
    } else if op == 11 {
        while i != n {
            let b = Fixed { enc: b0 + i.into() };
            acc += is_neg(b).into();
            i += 1;
        }
    } else if op == 12 {
        while i != n {
            let a = Fixed { enc: a0 + i.into() };
            let b = Fixed { enc: b0 + i.into() };
            acc += ge(a, b).into();
            i += 1;
        }
    } else if op == 13 {
        while i != n {
            let a = Fixed { enc: a0 + i.into() };
            let b = Fixed { enc: b0 + i.into() };
            acc += min(a, b).enc + max(a, b).enc;
            i += 1;
        }
    } else if op == 14 {
        while i != n {
            let a = Fixed { enc: a0 + i.into() };
            acc += to_units(a);
            i += 1;
        }
    } else if op == 15 {
        while i != n {
            acc += from_units(i.into()).enc;
            i += 1;
        }
    } else if op == 16 {
        while i != n {
            let b = Fixed { enc: b0 + i.into() };
            let (s, m) = split(b);
            acc += m + s.into();
            i += 1;
        }
    } else if op == 17 {
        // Representative composite: the momentum step `x + mul(v, c)` at the
        // heart of P_XYMovement.
        while i != n {
            let a = Fixed { enc: a0 + i.into() };
            let b = Fixed { enc: b0 + i.into() };
            acc += add(a, mul(b, a)).enc - BIAS;
            i += 1;
        }
    }
    acc
}

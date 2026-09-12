// SPDX-License-Identifier: Apache-2.0
//! Step-cost benchmark for the `bam` crate.
//!
//! Method: differential measurement (S1 §3.1) -- each operation is run `n`
//! and `2n` times and the difference is divided by `n`.
//!
//! **Every operand varies with the loop counter.** With loop-invariant
//! operands the Cairo compiler hoists the whole call out of the loop and the
//! measurement reads 1 step, which is how this file looked on its first
//! draft (`angle_to_fine_index` "cost" 1 step, `cosine` 17 against `sine`
//! 54 for the same work). Each operation is therefore measured against the
//! **baseline op that generates the same operands** and does nothing else:
//! `budgets.json` names it in each entry's `base` field.
//!
//! op 0: bare loop
//! op 1: angle operand baseline
//! op 2: point (dx, dy) operand baseline

use bam::{
    add, angle_to_fine_index, cosine, finecosine, finesine, neg, point_to_angle, point_to_angle2,
    reduce, sin_cos, sine, slope_div, sub, tantoangle,
};
use fixed::Fixed;

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    let a: u32 = 0x2ABCDEF0;
    let b: u32 = 0x1234567;

    if op == 0 { // bare loop
        while i != n {
            i += 1;
        }
    } else if op == 1 {
        // angle operand baseline
        while i != n {
            let ang: u32 = a + i;
            acc += ang.into();
            i += 1;
        }
    } else if op == 2 {
        // point operand baseline: 137.5 units east, 42.25 units north, moving
        while i != n {
            let dx = Fixed { enc: 4303977984 + i.into() };
            let dy = Fixed { enc: 4297736192 + i.into() };
            acc += dx.enc + dy.enc;
            i += 1;
        }
    } else if op == 3 {
        while i != n {
            let ang: u32 = a + i;
            acc += add(ang, b).into();
            i += 1;
        }
    } else if op == 4 {
        while i != n {
            let ang: u32 = a + i;
            acc += sub(ang, b).into();
            i += 1;
        }
    } else if op == 5 {
        while i != n {
            let ang: u32 = a + i;
            acc += neg(ang).into();
            i += 1;
        }
    } else if op == 6 {
        while i != n {
            let ang: u32 = a + i;
            acc += reduce(ang.into() + 0x1FEDCBA9876).into();
            i += 1;
        }
    } else if op == 7 {
        while i != n {
            let ang: u32 = a + i;
            acc += angle_to_fine_index(ang).into();
            i += 1;
        }
    } else if op == 8 {
        while i != n {
            let idx: u32 = 5000 + i;
            acc += finesine(idx).enc;
            i += 1;
        }
    } else if op == 9 {
        while i != n {
            let idx: u32 = 5000 + i;
            acc += finecosine(idx).enc;
            i += 1;
        }
    } else if op == 10 {
        while i != n {
            let ang: u32 = a + i;
            acc += sine(ang).enc;
            i += 1;
        }
    } else if op == 11 {
        while i != n {
            let ang: u32 = a + i;
            acc += cosine(ang).enc;
            i += 1;
        }
    } else if op == 12 {
        while i != n {
            let ang: u32 = a + i;
            let (s, c) = sin_cos(ang);
            acc += s.enc + c.enc;
            i += 1;
        }
    } else if op == 13 {
        while i != n {
            let idx: u32 = 1234 + i;
            acc += tantoangle(idx).into();
            i += 1;
        }
    } else if op == 14 {
        while i != n {
            acc += slope_div(2768896 + i.into(), 9010688).into();
            i += 1;
        }
    } else if op == 15 {
        while i != n {
            let dx = Fixed { enc: 4303977984 + i.into() };
            let dy = Fixed { enc: 4297736192 + i.into() };
            acc += point_to_angle(dx, dy).into();
            i += 1;
        }
    } else if op == 16 {
        while i != n {
            let dx = Fixed { enc: 4303977984 + i.into() };
            let dy = Fixed { enc: 4297736192 + i.into() };
            acc += point_to_angle2(Fixed { enc: 4294967296 }, Fixed { enc: 4294967296 }, dx, dy)
                .into();
            i += 1;
        }
    } else if op == 17 {
        // Representative composite: turn by a ticcmd, then take the sine and
        // cosine of the new angle -- the core of P_PlayerThink's movement.
        while i != n {
            let ang = add(a + i, b);
            let (s, c) = sin_cos(ang);
            acc += s.enc + c.enc;
            i += 1;
        }
    }
    acc
}

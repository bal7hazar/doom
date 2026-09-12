// SPDX-License-Identifier: Apache-2.0
//! Step-cost benchmark for the `geom2d` crate.
//!
//! Differential measurement (S1 §3.1) with **varying operands** and a
//! per-operation baseline (`base` in `budgets.json`):
//!
//! * op 0 -- bare loop;
//! * op 1 -- point operand baseline;
//! * op 2 -- point + box operand baseline;
//! * op 3 -- point + hoisted term baseline (what a loop over lines pays
//!           once, before touching any line);
//! * op 16 -- op 3 plus the `i % 8` that varies the line index, the
//!            baseline of the planar `point_side_at`.
//!
//! Ops 10 and 11 answer the question S1 §5.7 raised: what the two rejection
//! orders of `PIT_CheckLine` cost on a line that is far away (the common
//! case), so that the crate's README can justify keeping Doom's order.

use fixed::Fixed;
use geom2d::{
    Box, DivLine, HalfPlane, Point, approx_distance, bbox_reject, box_around, box_on_line_side,
    divline_side, hoist, intercept_fraction, point_on_side, point_on_side_truncated, point_side,
    point_side_alone, point_side_at,
};

/// Three parallel coefficient arrays, the shape the level data uses.
const AB: [felt252; 8] = [131200, 131008, 131072, 131136, 130944, 131328, 131072, 131072];
const BB: [felt252; 8] = [131072, 131072, 131200, 130944, 131136, 131008, 131072, 131328];
const CB: [felt252; 8] = [
    1125899906842624, 1125350151028736, 1126449662656512, 1124800395214848, 1126999418470400,
    1124250639400960, 1125899906842624, 1127549174284288,
];

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    let x0: felt252 = 4302700544; // 118 units east
    let y0: felt252 = 4296015872; // 16 units north
    let r: Fixed = Fixed { enc: 4296015872 }; // radius 16

    if op == 0 { // bare loop
        while i != n {
            i += 1;
        }
    } else if op == 1 {
        // point operand baseline
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            acc += p.x.enc + p.y.enc;
            i += 1;
        }
    } else if op == 2 {
        // point + box baseline
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let b = box_around(p, r);
            acc += b.left.enc + b.top.enc;
            i += 1;
        }
    } else if op == 3 {
        // point + hoisted term baseline
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            acc += hoist(p);
            i += 1;
        }
    } else if op == 16 {
        // point + hoisted term + varying line index baseline
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            acc += hoist(p) + (i % 8).into();
            i += 1;
        }
    } else if op == 4 {
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let hp = HalfPlane { ab: 131200, bb: 131072, cb: 1125899906842624 };
            acc += point_side(hp, p, hoist(p)).into();
            i += 1;
        }
    } else if op == 5 {
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let hp = HalfPlane { ab: 131200, bb: 131072, cb: 1125899906842624 };
            acc += point_side_alone(hp, p).into();
            i += 1;
        }
    } else if op == 6 {
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let hp = HalfPlane { ab: 131200, bb: 131072, cb: 1125899906842624 };
            acc += divline_side(hp, p, hoist(p)).into();
            i += 1;
        }
    } else if op == 7 {
        // the planar form: three array reads then the predicate
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            acc += point_side_at(AB.span(), BB.span(), CB.span(), i % 8, p, hoist(p)).into();
            i += 1;
        }
    } else if op == 8 {
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let b = box_around(p, r);
            let hp = HalfPlane { ab: 131200, bb: 131072, cb: 1125899906842624 };
            acc += box_on_line_side(hp, 0, b).into();
            i += 1;
        }
    } else if op == 9 {
        // bbox_reject on a line that overlaps: all four comparisons run
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let b = box_around(p, r);
            acc += bbox_reject(b, b).into();
            i += 1;
        }
    } else if op == 10 {
        // bbox_reject on a far line: short-circuits on the first comparison
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let b = box_around(p, r);
            let far = Box {
                left: Fixed { enc: 4400000000 },
                bottom: Fixed { enc: 4400000000 },
                right: Fixed { enc: 4400065536 },
                top: Fixed { enc: 4400065536 },
            };
            acc += bbox_reject(b, far).into();
            i += 1;
        }
    } else if op == 11 {
        // Doom's order on a far line: the bbox test rejects, so the
        // half-plane test is never reached.
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let b = box_around(p, r);
            let far = Box {
                left: Fixed { enc: 4400000000 },
                bottom: Fixed { enc: 4400000000 },
                right: Fixed { enc: 4400065536 },
                top: Fixed { enc: 4400065536 },
            };
            let hp = HalfPlane { ab: 131200, bb: 131072, cb: 1125899906842624 };
            if !bbox_reject(b, far) {
                acc += box_on_line_side(hp, 0, b).into();
            }
            i += 1;
        }
    } else if op == 12 {
        // The inverted order on the same far line: the half-plane test runs
        // first and is wasted.
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let b = box_around(p, r);
            let far = Box {
                left: Fixed { enc: 4400000000 },
                bottom: Fixed { enc: 4400000000 },
                right: Fixed { enc: 4400065536 },
                top: Fixed { enc: 4400065536 },
            };
            let hp = HalfPlane { ab: 131200, bb: 131072, cb: 1125899906842624 };
            if box_on_line_side(hp, 0, b) == 2 {
                acc += bbox_reject(b, far).into();
            }
            i += 1;
        }
    } else if op == 13 {
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            acc += approx_distance(p.x, p.y).enc;
            i += 1;
        }
    } else if op == 14 {
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let trace = DivLine {
                x: p.x, y: p.y, dx: Fixed { enc: 4297064448 }, dy: Fixed { enc: 4296015872 },
            };
            let wall = DivLine {
                x: Fixed { enc: 4302700544 },
                y: Fixed { enc: 4294115328 },
                dx: Fixed { enc: 4294967296 },
                dy: Fixed { enc: 4297064448 },
            };
            acc += intercept_fraction(trace, wall).enc;
            i += 1;
        }
    } else if op == 17 {
        // the two-vertex convenience form, which rebuilds the predicate
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let a = Point { x: Fixed { enc: 4294967296 }, y: Fixed { enc: 4294967296 } };
            let b = Point { x: Fixed { enc: 4299161600 }, y: Fixed { enc: 4294967296 } };
            acc += point_on_side(p, a, b).into();
            i += 1;
        }
    } else if op == 15 {
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let a = Point { x: Fixed { enc: 4294967296 }, y: Fixed { enc: 4294967296 } };
            let b = Point { x: Fixed { enc: 4299161600 }, y: Fixed { enc: 4294967296 } };
            acc += point_on_side_truncated(p, a, b).into();
            i += 1;
        }
    }
    acc
}

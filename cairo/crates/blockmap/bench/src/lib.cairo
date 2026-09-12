// SPDX-License-Identifier: Apache-2.0
//! Step-cost benchmark for the `blockmap` crate.
//!
//! Differential measurement (S1 §3.1) with varying operands and a
//! per-operation baseline (`base` in `budgets.json`):
//!
//! * op 0 -- bare loop;
//! * op 1 -- point operand baseline;
//! * op 2 -- point + box baseline;
//! * op 3 -- two-point baseline (a ray);
//! * op 12 -- the `i % 16` a cell index costs in this bench;
//! * op 14 -- the two `%` of op 5's cell coordinates.
//!
//! Ops 10 and 11 are the two ways to iterate one cell's line list, the
//! comparison R2-A10 asks for: the open-coded loop over `list_range` and the
//! visitor-based `for_each_in_cell`.

use blockmap::{
    CELL_RAW, Grid, ItemVisitor, PackedLists, Walk, cell_index, cell_of, cells_of_box,
    for_each_in_cell, list_item, list_range, range_cell, range_len, walk_next, walk_start,
};
use fixed::Fixed;
use geom2d::{Point, box_around};

/// A blocklist over 16 cells, 4 lines each: E1M1 averages 4.18 lines per
/// non-empty cell (S1 §4).
const START: [u32; 17] = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60, 64];
const ITEMS: [u32; 64] = [
    17, 44, 91, 6, 12, 88, 3, 55, 71, 2, 19, 34, 60, 81, 5, 27, 93, 41, 8, 66, 14, 39, 77, 1, 52,
    28, 95, 7, 63, 22, 48, 86, 11, 37, 74, 4, 59, 25, 92, 16, 43, 79, 9, 68, 31, 54, 83, 20, 47, 13,
    70, 36, 99, 24, 57, 10, 82, 45, 21, 64, 38, 90, 15, 51,
];

#[derive(Drop)]
struct Sum {
    total: u32,
}

impl SumVisitor of ItemVisitor<Sum> {
    fn visit(ref self: Sum, item: u32) -> bool {
        self.total += item;
        true
    }
}

fn grid() -> Grid {
    // 32 x 27 cells, origin at (-1024, -1024) map units: E1M1's shape.
    Grid {
        origin_x: Fixed { enc: 4294967296 - 67108864 },
        origin_y: Fixed { enc: 4294967296 - 67108864 },
        columns: 32,
        rows: 27,
    }
}

fn lists() -> PackedLists {
    PackedLists { start: START.span(), items: ITEMS.span() }
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    let g = grid();
    let l = lists();
    // A point 300 units into the grid, and a target 1 500 units away.
    let x0: felt252 = 4294967296 - 47448064;
    let y0: felt252 = 4294967296 - 47448064;
    let x1: felt252 = 4294967296 + 51380224;
    let y1: felt252 = 4294967296 + 32505856;
    let r = Fixed { enc: 4294967296 + 1048576 };

    if op == 0 { // bare loop
        while i != n {
            i += 1;
        }
    } else if op == 1 {
        // point baseline
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
        // two-point baseline
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let q = Point { x: Fixed { enc: x1 + i.into() }, y: Fixed { enc: y1 + i.into() } };
            acc += p.x.enc + q.y.enc;
            i += 1;
        }
    } else if op == 4 {
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            match cell_of(g, p) {
                Option::Some((cx, cy)) => { acc += cx.into() + cy.into(); },
                Option::None => {},
            }
            i += 1;
        }
    } else if op == 5 {
        while i != n {
            acc += cell_index(g, i % 32, i % 27).into();
            i += 1;
        }
    } else if op == 6 {
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let b = box_around(p, r);
            match cells_of_box(g, b) {
                Option::Some(range) => { acc += range.x0.into() + range.y1.into(); },
                Option::None => {},
            }
            i += 1;
        }
    } else if op == 7 {
        // the whole "which cells does this mobj touch" preamble of P_TryMove
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let b = box_around(p, r);
            match cells_of_box(g, b) {
                Option::Some(range) => {
                    let count = range_len(range);
                    let mut k: u32 = 0;
                    while k != count {
                        let (cx, cy) = range_cell(range, k);
                        acc += cell_index(g, cx, cy).into();
                        k += 1;
                    }
                },
                Option::None => {},
            }
            i += 1;
        }
    } else if op == 8 {
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let q = Point { x: Fixed { enc: x1 + i.into() }, y: Fixed { enc: y1 + i.into() } };
            match walk_start(g, p, q) {
                Option::Some(w) => { acc += w.tx + w.ty; },
                Option::None => {},
            }
            i += 1;
        }
    } else if op == 9 {
        // a full walk across the grid
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let q = Point { x: Fixed { enc: x1 + i.into() }, y: Fixed { enc: y1 + i.into() } };
            match walk_start(g, p, q) {
                Option::Some(w) => {
                    let mut walk: Walk = w;
                    loop {
                        match walk_next(ref walk) {
                            Option::Some((cx, cy)) => { acc += cx.into() + cy.into(); },
                            Option::None => { break; },
                        }
                    }
                },
                Option::None => {},
            }
            i += 1;
        }
    } else if op == 10 {
        // R2-A10: the open-coded loop over one cell's list
        while i != n {
            let (from, to) = list_range(@l, i % 16);
            let mut k = from;
            while k != to {
                acc += list_item(@l, k).into();
                k += 1;
            }
            i += 1;
        }
    } else if op == 11 {
        // the same through the visitor
        while i != n {
            let mut v = Sum { total: 0 };
            for_each_in_cell(@l, i % 16, ref v);
            acc += v.total.into();
            i += 1;
        }
    } else if op == 12 {
        // the cell index arithmetic the two ops above share
        while i != n {
            acc += (i % 16).into();
            i += 1;
        }
    } else if op == 14 {
        // baseline of op 5: the two modulos that vary the cell coordinates
        while i != n {
            acc += (i % 32).into() + (i % 27).into();
            i += 1;
        }
    } else if op == 13 {
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let q = Point { x: Fixed { enc: p.x.enc + CELL_RAW * 3 }, y: p.y };
            match walk_start(g, p, q) {
                Option::Some(w) => {
                    let mut walk: Walk = w;
                    loop {
                        match walk_next(ref walk) {
                            Option::Some((cx, _)) => { acc += cx.into(); },
                            Option::None => { break; },
                        }
                    }
                },
                Option::None => {},
            }
            i += 1;
        }
    }
    acc
}

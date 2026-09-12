// SPDX-License-Identifier: Apache-2.0
//! Step-cost benchmark for the `bsp` crate, over the same 63-node tree the
//! tests use (`tree.cairo`, written by `../../scripts/gen_vectors.py`).
//!
//! Differential measurement (S1 §3.1) with varying operands and a
//! per-operation baseline (`base` in `budgets.json`):
//!
//! * op 0 -- bare loop;
//! * op 1 -- point operand baseline;
//! * op 2 -- trace operand baseline (two points).

mod tree;
use bsp::{
    Nodes, SubsectorVisitor, child_box, cross_bsp, is_subsector, point_in_subsector, subsector_of,
    trace,
};
use fixed::Fixed;
use geom2d::Point;
use tree::{N_AB, N_BB, N_BBOX, N_CB, N_CHILD0, N_CHILD1, ROOT};

/// Counts visits and optionally stops after `limit` of them.
#[derive(Drop)]
struct Counter {
    count: u32,
    limit: u32,
}

impl CounterVisitor of SubsectorVisitor<Counter> {
    fn visit(ref self: Counter, subsector: u32) -> bool {
        self.count += subsector + 1;
        self.count < self.limit
    }
}

fn nodes() -> Nodes {
    Nodes {
        ab: N_AB.span(),
        bb: N_BB.span(),
        cb: N_CB.span(),
        child0: N_CHILD0.span(),
        child1: N_CHILD1.span(),
        bbox: N_BBOX.span(),
    }
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    let nodes = nodes();
    // A point near the centre of the map, and a second one 300 units away.
    let x0: felt252 = 4294967296 + 3407872;
    let y0: felt252 = 4294967296 - 5242880;
    let x1: felt252 = 4294967296 - 15728640;
    let y1: felt252 = 4294967296 + 19660800;

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
        // trace operand baseline
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let q = Point { x: Fixed { enc: x1 + i.into() }, y: Fixed { enc: y1 + i.into() } };
            acc += p.x.enc + q.y.enc;
            i += 1;
        }
    } else if op == 3 {
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let q = Point { x: Fixed { enc: x1 + i.into() }, y: Fixed { enc: y1 + i.into() } };
            let tr = trace(p, q);
            acc += tr.rhs1 + tr.rhs2;
            i += 1;
        }
    } else if op == 4 {
        // the 6-level descent
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            acc += point_in_subsector(@nodes, ROOT, p).into();
            i += 1;
        }
    } else if op == 5 {
        // a full crossing, ~11 subsectors visited
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let q = Point { x: Fixed { enc: x1 + i.into() }, y: Fixed { enc: y1 + i.into() } };
            let mut v = Counter { count: 0, limit: 0xFFFFFFFF };
            cross_bsp(@nodes, ROOT, trace(p, q), ref v);
            acc += v.count.into();
            i += 1;
        }
    } else if op == 6 {
        // stopped at the first subsector, the P_CheckSight "blocked" case
        while i != n {
            let p = Point { x: Fixed { enc: x0 + i.into() }, y: Fixed { enc: y0 + i.into() } };
            let q = Point { x: Fixed { enc: x1 + i.into() }, y: Fixed { enc: y1 + i.into() } };
            let mut v = Counter { count: 0, limit: 1 };
            cross_bsp(@nodes, ROOT, trace(p, q), ref v);
            acc += v.count.into();
            i += 1;
        }
    } else if op == 7 {
        while i != n {
            let b = child_box(@nodes, i % 63, 0);
            acc += b.left.enc + b.top.enc;
            i += 1;
        }
    } else if op == 8 {
        while i != n {
            let c = 0x80000000 + i;
            if is_subsector(c) {
                acc += subsector_of(c).into();
            }
            i += 1;
        }
    }
    acc
}

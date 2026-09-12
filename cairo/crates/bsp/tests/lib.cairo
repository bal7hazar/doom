// SPDX-License-Identifier: Apache-2.0
//! Integration tests: the parts of the public API a consumer can exercise
//! from **outside** the crate.
//!
//! `scarb test` computes gas for the integration target even though the
//! workspace sets `enable-gas = false`, and Cairo lowers both `while` and
//! recursion into recursive functions, whose cost computation then fails
//! with "found an unexpected cycle during cost computation". That rules out
//! calling `point_in_subsector` (a loop) or `cross_bsp` (a recursion) from
//! this target: both are covered by the unit tests in `src/tests.cairo`,
//! which run in the gas-less unit-test target. What is left here is the
//! encoding and the data accessors -- enough to catch a public API that
//! stopped compiling for an external consumer.

use bsp::{Nodes, SUBSECTOR_FLAG, SubsectorVisitor, child_box, is_subsector, subsector_of, trace};
use fixed::from_units;
use geom2d::{Point, SIDE_BACK, SIDE_FRONT, half_plane, hoist};

/// The visitor a consumer writes; instantiating it here proves the trait is
/// implementable from outside the crate.
#[derive(Drop)]
struct FirstTwo {
    seen: Array<u32>,
}

impl FirstTwoVisitor of SubsectorVisitor<FirstTwo> {
    fn visit(ref self: FirstTwo, subsector: u32) -> bool {
        self.seen.append(subsector);
        self.seen.len() != 2
    }
}

fn pt(x: felt252, y: felt252) -> Point {
    Point { x: from_units(x), y: from_units(y) }
}

#[test]
fn test_child_ids_and_boxes_from_outside_the_crate() {
    let hp = half_plane(pt(0, -64), pt(0, 64));
    let ab = array![hp.ab];
    let bb = array![hp.bb];
    let cb = array![hp.cb];
    let c0 = array![SUBSECTOR_FLAG];
    let c1 = array![SUBSECTOR_FLAG + 1];
    let bbox = array![
        from_units(0).enc, from_units(-64).enc, from_units(64).enc, from_units(64).enc,
        from_units(-64).enc, from_units(-64).enc, from_units(0).enc, from_units(64).enc,
    ];
    let nodes = Nodes {
        ab: ab.span(),
        bb: bb.span(),
        cb: cb.span(),
        child0: c0.span(),
        child1: c1.span(),
        bbox: bbox.span(),
    };
    assert(is_subsector(SUBSECTOR_FLAG + 3), 'a leaf id');
    assert(!is_subsector(3), 'a node id');
    assert(subsector_of(SUBSECTOR_FLAG + 3) == 3, 'the leaf number');
    let front = child_box(@nodes, 0, SIDE_FRONT);
    let back = child_box(@nodes, 0, SIDE_BACK);
    assert(front.left == from_units(0), 'the front half is east');
    assert(back.right == from_units(0), 'the back half is west');
}

#[test]
fn test_a_trace_hoists_both_endpoints() {
    let a = pt(-32, 0);
    let b = pt(32, 0);
    let tr = trace(a, b);
    assert(tr.rhs1 == hoist(a), 'first endpoint hoisted');
    assert(tr.rhs2 == hoist(b), 'second endpoint hoisted');
    assert(tr.p1 == a && tr.p2 == b, 'endpoints kept');
    // The visitor type above is instantiated so that the trait bound is
    // exercised from an external crate.
    let mut v = FirstTwo { seen: array![] };
    assert(v.visit(7), 'the first visit continues');
    assert(!v.visit(8), 'the second one stops');
    assert(v.seen.len() == 2, 'both recorded');
}

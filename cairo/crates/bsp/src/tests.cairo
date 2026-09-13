// SPDX-License-Identifier: Apache-2.0
//! Unit tests against a generated 63-node BSP tree: the descent on 1 000
//! points (142 of which land exactly on a partition line), the ray traversal
//! on 200 traces with their full visit order, the properties that tie the
//! two together, and the malformed-tree guards.

mod vectors;
use fixed::Fixed;
use geom2d::{Point, SIDE_BACK, SIDE_FRONT, bbox_reject, box_around};
use vectors::{
    N_AB, N_BB, N_BBOX, N_CB, N_CHILD0, N_CHILD1, PT_SS, PT_X, PT_Y, ROOT, TR_SS, TR_START, TR_X1,
    TR_X2, TR_Y1, TR_Y2,
};
use super::{
    Nodes, SUBSECTOR_FLAG, SubsectorVisitor, child_box, cross_bsp, is_subsector, point_in_subsector,
    point_in_subsector_total, subsector_of, trace,
};

/// A visitor that records every subsector it is shown and stops after
/// `limit` of them, which is how `P_CheckSight` stops on the first blocking
/// subsector.
#[derive(Drop)]
struct Collector {
    seen: Array<u32>,
    limit: u32,
}

impl CollectorVisitor of SubsectorVisitor<Collector> {
    fn visit(ref self: Collector, subsector: u32) -> bool {
        self.seen.append(subsector);
        self.seen.len() != self.limit
    }
}

fn tree() -> Nodes {
    Nodes {
        ab: N_AB.span(),
        bb: N_BB.span(),
        cb: N_CB.span(),
        child0: N_CHILD0.span(),
        child1: N_CHILD1.span(),
        bbox: N_BBOX.span(),
    }
}

fn pt_enc(x: felt252, y: felt252) -> Point {
    Point { x: Fixed { enc: x }, y: Fixed { enc: y } }
}

fn pt(x: felt252, y: felt252) -> Point {
    Point { x: fixed::from_units(x), y: fixed::from_units(y) }
}

// ---------------------------------------------------------------------------
// Child encoding
// ---------------------------------------------------------------------------

#[test]
fn test_child_encoding() {
    assert(!is_subsector(0), 'node 0 is a node');
    assert(!is_subsector(SUBSECTOR_FLAG - 1), 'the last node is a node');
    assert(is_subsector(SUBSECTOR_FLAG), 'the flag marks a leaf');
    assert(subsector_of(SUBSECTOR_FLAG) == 0, 'first subsector');
    assert(subsector_of(SUBSECTOR_FLAG + 681) == 681, 'subsector 681');
}

// ---------------------------------------------------------------------------
// Descent
// ---------------------------------------------------------------------------

#[test]
fn test_point_in_subsector_matches_1000_reference_points() {
    let nodes = tree();
    let x = PT_X.span();
    let y = PT_Y.span();
    let ss = PT_SS.span();
    assert(ss.len() == 1000, '1000 points');
    let root: u32 = ROOT;
    let mut i: u32 = 0;
    while i != 1000 {
        let got = point_in_subsector(@nodes, root, pt_enc(*x.at(i), *y.at(i)));
        assert(got == *ss.at(i), 'descent matches');
        i += 1;
    }
}

#[test]
fn test_point_in_subsector_total_agrees_with_the_checked_descent() {
    let nodes = tree();
    let x = PT_X.span();
    let y = PT_Y.span();
    let root: u32 = ROOT;
    let mut i: u32 = 0;
    while i != 1000 {
        let p = pt_enc(*x.at(i), *y.at(i));
        assert(
            point_in_subsector_total(@nodes, root, p) == point_in_subsector(@nodes, root, p),
            'total == checked',
        );
        i += 1;
    }
}

#[test]
fn test_point_in_subsector_total_stops_on_a_cycle() {
    // The same one-node cycle the checked descent panics on: the total
    // form ends at subsector 0 instead.
    let ab = array![131072_felt252];
    let bb = array![131072_felt252];
    let cb = array![1125899906842624_felt252];
    let c0 = array![0_u32];
    let c1 = array![0_u32];
    let bbox = array![0_felt252, 0, 0, 0, 0, 0, 0, 0];
    let nodes = Nodes {
        ab: ab.span(),
        bb: bb.span(),
        cb: cb.span(),
        child0: c0.span(),
        child1: c1.span(),
        bbox: bbox.span(),
    };
    assert(point_in_subsector_total(@nodes, 0, pt(1, 1)) == 0, 'total ends at 0');
}

#[test]
fn test_the_subsector_of_a_point_has_a_box_that_contains_it() {
    // Property tying the descent to the stored child boxes: at every level
    // the chosen child's box must contain the point. Checked here on the
    // last level, which is enough to catch a swapped child0/child1.
    let nodes = tree();
    let x = PT_X.span();
    let y = PT_Y.span();
    let mut i: u32 = 0;
    while i != 200 {
        let p = pt_enc(*x.at(i), *y.at(i));
        // Walk by hand to find the node whose child is the leaf.
        let mut current: u32 = ROOT;
        let mut parent: u32 = ROOT;
        let mut side: u8 = SIDE_FRONT;
        while !is_subsector(current) {
            parent = current;
            let s = geom2d::point_side_at(
                nodes.ab, nodes.bb, nodes.cb, current, p, geom2d::hoist(p),
            );
            side = s;
            current =
                if s == SIDE_FRONT {
                    *nodes.child0.at(current)
                } else {
                    *nodes.child1.at(current)
                };
        }
        let b = child_box(@nodes, parent, side);
        // A degenerate box around the point overlaps the child box unless
        // the point is on the box's boundary, which a partition line makes
        // possible; a one-unit box is the tolerance.
        let around = box_around(p, fixed::FRACUNIT);
        assert(!bbox_reject(around, b), 'leaf box contains the point');
        i += 1;
    }
}

#[test]
#[should_panic(expected: 'bsp: cycle or oob')]
fn test_a_cyclic_tree_panics_instead_of_looping() {
    // A single node whose two children point back at itself.
    let ab = array![131072_felt252];
    let bb = array![131072_felt252];
    let cb = array![1125899906842624_felt252];
    let c0 = array![0_u32];
    let c1 = array![0_u32];
    let bbox = array![0_felt252, 0, 0, 0, 0, 0, 0, 0];
    let nodes = Nodes {
        ab: ab.span(),
        bb: bb.span(),
        cb: cb.span(),
        child0: c0.span(),
        child1: c1.span(),
        bbox: bbox.span(),
    };
    point_in_subsector(@nodes, 0, pt(1, 1));
}

// ---------------------------------------------------------------------------
// Ray traversal
// ---------------------------------------------------------------------------

#[test]
fn test_cross_bsp_visits_the_reference_subsectors_in_order() {
    let nodes = tree();
    let x1 = TR_X1.span();
    let y1 = TR_Y1.span();
    let x2 = TR_X2.span();
    let y2 = TR_Y2.span();
    let start = TR_START.span();
    let flat = TR_SS.span();
    assert(x1.len() == 200, '200 traces');
    let mut t: u32 = 0;
    while t != 200 {
        let tr = trace(pt_enc(*x1.at(t), *y1.at(t)), pt_enc(*x2.at(t), *y2.at(t)));
        let mut collector = Collector { seen: array![], limit: 0xFFFFFFFF };
        let finished = cross_bsp(@nodes, ROOT, tr, ref collector);
        assert(finished, 'a full crossing finishes');
        let from = *start.at(t);
        let to = *start.at(t + 1);
        assert(collector.seen.len() == to - from, 'same number of subsectors');
        let mut k: u32 = 0;
        while k != to - from {
            assert(*collector.seen.at(k) == *flat.at(from + k), 'same subsector, same order');
            k += 1;
        }
        t += 1;
    }
}

#[test]
fn test_the_first_subsector_visited_is_the_one_containing_the_origin() {
    let nodes = tree();
    let x1 = TR_X1.span();
    let y1 = TR_Y1.span();
    let x2 = TR_X2.span();
    let y2 = TR_Y2.span();
    let mut t: u32 = 0;
    while t != 100 {
        let p1 = pt_enc(*x1.at(t), *y1.at(t));
        let tr = trace(p1, pt_enc(*x2.at(t), *y2.at(t)));
        let mut collector = Collector { seen: array![], limit: 1 };
        let finished = cross_bsp(@nodes, ROOT, tr, ref collector);
        assert(!finished, 'stopping is reported');
        assert(collector.seen.len() == 1, 'stopped after one visit');
        assert(*collector.seen.at(0) == point_in_subsector(@nodes, ROOT, p1), 'origin first');
        t += 1;
    }
}

#[test]
fn test_reversing_a_trace_reverses_the_visit_order() {
    let nodes = tree();
    let x1 = TR_X1.span();
    let y1 = TR_Y1.span();
    let x2 = TR_X2.span();
    let y2 = TR_Y2.span();
    let mut t: u32 = 0;
    while t != 50 {
        let a = pt_enc(*x1.at(t), *y1.at(t));
        let b = pt_enc(*x2.at(t), *y2.at(t));
        let mut forward = Collector { seen: array![], limit: 0xFFFFFFFF };
        cross_bsp(@nodes, ROOT, trace(a, b), ref forward);
        let mut backward = Collector { seen: array![], limit: 0xFFFFFFFF };
        cross_bsp(@nodes, ROOT, trace(b, a), ref backward);
        let n = forward.seen.len();
        assert(backward.seen.len() == n, 'same length both ways');
        let mut k: u32 = 0;
        while k != n {
            assert(*forward.seen.at(k) == *backward.seen.at(n - 1 - k), 'reversed order');
            k += 1;
        }
        t += 1;
    }
}

#[test]
fn test_a_degenerate_trace_visits_only_its_own_subsector() {
    let nodes = tree();
    let p = pt(100, -250);
    let mut collector = Collector { seen: array![], limit: 0xFFFFFFFF };
    let finished = cross_bsp(@nodes, ROOT, trace(p, p), ref collector);
    assert(finished, 'finished');
    assert(collector.seen.len() == 1, 'one subsector');
    assert(*collector.seen.at(0) == point_in_subsector(@nodes, ROOT, p), 'its own subsector');
}

#[test]
fn test_a_trace_along_a_partition_line_still_terminates() {
    // Both endpoints exactly on a partition: `divline_side` answers
    // SIDE_CROSS for both, which Doom folds into the front side.
    let nodes = tree();
    let x = PT_X.span();
    let y = PT_Y.span();
    // Index 7 is one of the generated "exactly on a partition" points.
    let a = pt_enc(*x.at(7), *y.at(7));
    let b = pt_enc(*x.at(14), *y.at(14));
    let mut collector = Collector { seen: array![], limit: 0xFFFFFFFF };
    let finished = cross_bsp(@nodes, ROOT, trace(a, b), ref collector);
    assert(finished, 'finished');
    assert(collector.seen.len() != 0, 'visited something');
}

#[test]
fn test_child_box_reads_both_children() {
    let nodes = tree();
    let front = child_box(@nodes, ROOT, SIDE_FRONT);
    let back = child_box(@nodes, ROOT, SIDE_BACK);
    // The root's two children partition the map, so their boxes touch but do
    // not overlap: `bbox_reject` must reject the pair.
    assert(bbox_reject(front, back), 'the two halves do not overlap');
    assert(front.left != back.left || front.bottom != back.bottom, 'two different boxes');
}

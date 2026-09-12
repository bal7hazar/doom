// SPDX-License-Identifier: Apache-2.0
//! Binary space partition: descent to a leaf, and the ray traversal
//! `P_CheckSight` is built on.
//!
//! # Data, not ownership
//!
//! The crate never owns a level. A [`Nodes`] is a bundle of **spans over
//! planar arrays** that `doom_map` (or `tools/wad`) generates: the three
//! biased half-plane coefficients of each node's partition line, the two
//! child ids, and the two child bounding boxes. S1 §5.3 and §5.9: one array
//! per field for data read tens of times per tic, never a packed record; and
//! `child0` / `child1` in two separate arrays, with the "this is a leaf" bit
//! tested by a `u32` comparison against [`SUBSECTOR_FLAG`] rather than a
//! bitwise mask (57 steps per masked iteration against 14 in pure felt,
//! S1 §5.1 / decision A7).
//!
//! # Why the descent is the thing to avoid
//!
//! S1 §5.6 measured `point_in_subsector` at **1 014 steps** on E1M1
//! (681 nodes, ~10 levels) and §5.5 found it to be **35 % of an optimized
//! tic**. The crate is written so that the descent is as cheap as it can be
//! -- the point's hoisted term is computed once, before the loop, so each
//! level costs one three-array read plus one `felt_ge` -- but the real fix
//! is not to descend at all: R2-A9 (the `blockmap` cell to subsector
//! accelerator) answers in one read, and this crate's descent is what it
//! falls back to. `blockmap::PackedLists` carries that accelerator.

use geom2d::{Box, Point, SIDE_CROSS, SIDE_FRONT, divline_side, hoist, point_side_at};

/// A child id at or above this value is a **subsector** (leaf), not a node.
///
/// Doom packs the flag in bit 15 of a `uint16` (`NF_SUBSECTOR = 0x8000`);
/// the generator re-encodes it in bit 31 of a `u32` so that a level may have
/// more than 32 767 nodes without ambiguity.
pub const SUBSECTOR_FLAG: u32 = 0x80000000;

/// Planar arrays describing one BSP tree.
///
/// * `ab`, `bb`, `cb` -- `geom2d::HalfPlane` coefficients of each node's
///   partition line, biased the same way `geom2d::half_plane` biases them;
/// * `child0` -- the **front** child (`R_PointOnSide` returns 0), `child1`
///   the back one, each either a node index or `SUBSECTOR_FLAG | subsector`;
/// * `bbox` -- 8 felts per node: the front child's box
///   (left, bottom, right, top) then the back child's, in the `fixed`
///   encoding. Used by callers that cull with `geom2d::bbox_reject`; the
///   descent itself never reads it.
#[derive(Copy, Drop)]
pub struct Nodes {
    pub ab: Span<felt252>,
    pub bb: Span<felt252>,
    pub cb: Span<felt252>,
    pub child0: Span<u32>,
    pub child1: Span<u32>,
    pub bbox: Span<felt252>,
}

/// A ray, with both endpoints' hoisted terms precomputed: the traversal
/// tests both against every node it visits, so hoisting them once saves a
/// `geom2d::hoist` per level.
#[derive(Copy, Drop)]
pub struct Trace {
    pub p1: Point,
    pub rhs1: felt252,
    pub p2: Point,
    pub rhs2: felt252,
}

/// Build a [`Trace`] from its two endpoints (hoists both terms).
///
/// **Measured: 12 steps** (two `geom2d::hoist`).
pub fn trace(p1: Point, p2: Point) -> Trace {
    Trace { p1, rhs1: hoist(p1), p2, rhs2: hoist(p2) }
}

/// `true` if `child` designates a subsector rather than a node.
///
/// **Measured: 10 steps, 2 range checks** (with [`subsector_of`], 18 for
/// the pair).
pub fn is_subsector(child: u32) -> bool {
    child >= SUBSECTOR_FLAG
}

/// The subsector id inside a leaf child id (the caller has checked
/// [`is_subsector`]).
///
/// **Measured: 8 steps, 1 range check.**
pub fn subsector_of(child: u32) -> u32 {
    child - SUBSECTOR_FLAG
}

/// The bounding box of `node`'s child on `side` (0 front, 1 back).
///
/// **Measured: 96 steps, 11 range checks** (four `Span` indexes at 14
/// steps each, plus the index arithmetic).
pub fn child_box(nodes: @Nodes, node: u32, side: u8) -> Box {
    let base = node * 8 + if side == SIDE_FRONT {
        0
    } else {
        4
    };
    Box {
        left: fixed::Fixed { enc: *(*nodes.bbox).at(base) },
        bottom: fixed::Fixed { enc: *(*nodes.bbox).at(base + 1) },
        right: fixed::Fixed { enc: *(*nodes.bbox).at(base + 2) },
        top: fixed::Fixed { enc: *(*nodes.bbox).at(base + 3) },
    }
}

/// Descend to the subsector containing `p` (Doom's `R_PointInSubsector`).
///
/// `root` is the id of the root **node** (Doom uses `numnodes - 1`). A point
/// exactly on a partition line goes to the back child, the same way every
/// other side test in this workspace resolves ties.
///
/// Panics if the tree is malformed (more hops than there are nodes, i.e. a
/// cycle or an out-of-range child) rather than looping forever.
///
/// **Measured: 631 steps for a 6-level descent, i.e. 105 per level** --
/// the same per-level cost S1 §5.6 measured on E1M1 (1 014 steps over ~10
/// levels). Hoisting the point term saves only 3 steps per level: **the
/// descent is dominated by array indexing**, 4 `Span` reads per level at 14
/// steps each (three coefficients and one child), plus the 11-step
/// comparison and the loop's own bookkeeping. There is no cheaper way to
/// descend; the way out is not to descend (R2-A9).
pub fn point_in_subsector(nodes: @Nodes, root: u32, p: Point) -> u32 {
    let rhs = hoist(p);
    let ab = *nodes.ab;
    let bb = *nodes.bb;
    let cb = *nodes.cb;
    let mut current = root;
    let mut hops: u32 = 0;
    let max_hops = ab.len() + 1;
    loop {
        if is_subsector(current) {
            break subsector_of(current);
        }
        assert(hops != max_hops, 'bsp: cycle or oob');
        hops += 1;
        let side = point_side_at(ab, bb, cb, current, p, rhs);
        current =
            if side == SIDE_FRONT {
                *(*nodes.child0).at(current)
            } else {
                *(*nodes.child1).at(current)
            };
    }
}

/// What a ray traversal does at each subsector it reaches.
///
/// `doom_physics` implements it once for `P_CheckSight` (does any two-sided
/// line of this subsector block the sight line?) and once for
/// `P_PathTraverse` (hitscan). Returning `false` stops the traversal
/// immediately, which is what makes an early "blocked" answer cheap.
pub trait SubsectorVisitor<T> {
    fn visit(ref self: T, subsector: u32) -> bool;
}

/// Walk every subsector the segment `trace.p1 -> trace.p2` crosses, in order
/// from `p1`, calling `visitor` on each; stop as soon as a visit returns
/// `false`. Returns `true` if the whole segment was crossed without a visit
/// refusing -- exactly Doom's `P_CrossBSPNode`.
///
/// The generic parameter is monomorphized once per visitor type (~60-77
/// words of bytecode each, S1 §5.9), so keep the number of distinct visitors
/// small: two are planned (sight and hitscan).
///
/// **Measured: 2 016 steps for a full crossing of the 63-node test tree**
/// (4 subsectors visited, 7 nodes descended twice) and **642 steps when the
/// first visited subsector stops the traversal** -- which is the case
/// `P_CheckSight` hits whenever the sight line is blocked early, and the
/// reason the visitor returns a `bool` instead of collecting.
pub fn cross_bsp<T, impl V: SubsectorVisitor<T>, +Drop<T>>(
    nodes: @Nodes, root: u32, tr: Trace, ref visitor: T,
) -> bool {
    let budget = (*nodes.ab).len() + 1;
    cross_node::<T, V>(nodes, root, tr, ref visitor, budget)
}

/// The recursive half of [`cross_bsp`]. `budget` bounds the depth so that a
/// malformed tree panics instead of recursing forever.
fn cross_node<T, impl V: SubsectorVisitor<T>, +Drop<T>>(
    nodes: @Nodes, num: u32, tr: Trace, ref visitor: T, budget: u32,
) -> bool {
    if is_subsector(num) {
        return visitor.visit(subsector_of(num));
    }
    assert(budget != 0, 'bsp: cycle or oob');
    let hp = geom2d::HalfPlane {
        ab: *(*nodes.ab).at(num), bb: *(*nodes.bb).at(num), cb: *(*nodes.cb).at(num),
    };
    // Doom folds "exactly on the partition" into the front side.
    let raw_side = divline_side(hp, tr.p1, tr.rhs1);
    let side = if raw_side == SIDE_CROSS {
        SIDE_FRONT
    } else {
        raw_side
    };
    let (near, far) = if side == SIDE_FRONT {
        (*(*nodes.child0).at(num), *(*nodes.child1).at(num))
    } else {
        (*(*nodes.child1).at(num), *(*nodes.child0).at(num))
    };
    // Cross the side the ray starts on first, so subsectors are visited in
    // order of increasing distance from p1.
    if !cross_node::<T, V>(nodes, near, tr, ref visitor, budget - 1) {
        return false;
    }
    // If the far endpoint is on the same side, the partition is not crossed.
    if side == divline_side(hp, tr.p2, tr.rhs2) {
        return true;
    }
    cross_node::<T, V>(nodes, far, tr, ref visitor, budget - 1)
}

#[cfg(test)]
mod tests;

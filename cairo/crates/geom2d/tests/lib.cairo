// SPDX-License-Identifier: Apache-2.0
//! Integration tests: the public API as an external consumer sees it.
//!
//! Must stay **loop-free** (see `src/tests.cairo` for why).

use fixed::{Fixed, from_units};
use geom2d::{
    Box, DivLine, HalfPlane, Point, SIDE_BACK, SIDE_CROSS, SIDE_FRONT, approx_distance, bbox_reject,
    box_around, box_of_segment, box_on_line_side, diagonal, divline_side, half_plane, hoist,
    intercept_fraction, point_side, point_side_alone,
};

fn pt(x: felt252, y: felt252) -> Point {
    Point { x: from_units(x), y: from_units(y) }
}

#[test]
fn test_a_consumer_can_build_and_use_a_half_plane() {
    // The wall of a corridor running west to east, and a player north of it.
    let wall: HalfPlane = half_plane(pt(0, 0), pt(128, 0));
    let player: Point = pt(64, 32);
    let rhs = hoist(player);
    assert(point_side(wall, player, rhs) == SIDE_BACK, 'north of the wall');
    assert(point_side_alone(wall, pt(64, -32)) == SIDE_FRONT, 'south of it');
    assert(divline_side(wall, pt(64, 0), hoist(pt(64, 0))) == SIDE_CROSS, 'exactly on it');
    assert(diagonal(pt(0, 0), pt(128, 0)) == 0, 'horizontal is not diagonal');

    // The player's 16-unit box does not reach the wall's own box.
    let tmbox: Box = box_around(player, from_units(16));
    let wallbox: Box = box_of_segment(pt(0, 0), pt(128, 0));
    assert(bbox_reject(tmbox, wallbox), 'box rejects a far wall');
    // Walking into it, the box straddles the line.
    let touching = box_around(pt(64, 8), from_units(16));
    assert(!bbox_reject(touching, wallbox), 'box reaches the wall');
    assert(box_on_line_side(wall, 0, touching) == SIDE_CROSS, 'the box straddles it');
}

#[test]
fn test_distances_and_intercepts_from_outside() {
    assert(approx_distance(from_units(3), from_units(4)) == Fixed { enc: 4295327744 }, '3-4-5');
    let ray = DivLine { x: from_units(0), y: from_units(0), dx: from_units(64), dy: from_units(0) };
    let parallel = DivLine {
        x: from_units(0), y: from_units(8), dx: from_units(64), dy: from_units(0),
    };
    assert(intercept_fraction(ray, parallel) == fixed::ZERO, 'parallel gives zero');
}

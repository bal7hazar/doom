// SPDX-License-Identifier: Apache-2.0

use bam::{ANG90, Angle};
use fixed::Fixed;

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Point {
    pub x: Fixed,
    pub y: Fixed,
}

/// Sign of the cross product `(b - a) x (p - a)`: `1` if `p` is on one side
/// of the line `a -> b`, `-1` on the other side, `0` if exactly collinear.
pub fn point_on_side(p: Point, a: Point, b: Point) -> i64 {
    let abx: i64 = b.x.raw - a.x.raw;
    let aby: i64 = b.y.raw - a.y.raw;
    let apx: i64 = p.x.raw - a.x.raw;
    let apy: i64 = p.y.raw - a.y.raw;
    let cross: i128 = (abx.into() * apy.into()) - (aby.into() * apx.into());
    if cross > 0 {
        1
    } else if cross < 0 {
        -1
    } else {
        0
    }
}

/// Coarse octant (0..7, 45 degrees each) classification of the direction
/// from `from` to `to`, expressed as a `bam::Angle` (multiple of 45
/// degrees). Octant 0 covers [0, 45), 1 covers [45, 90), etc.
pub fn point_to_octant(from: Point, to: Point) -> Angle {
    let dx: i64 = to.x.raw - from.x.raw;
    let dy: i64 = to.y.raw - from.y.raw;

    let octant: u32 = if dx >= 0 && dy >= 0 {
        if dx >= dy {
            0
        } else {
            1
        }
    } else if dx < 0 && dy >= 0 {
        let adx = -dx;
        if adx < dy {
            2
        } else {
            3
        }
    } else if dx < 0 && dy < 0 {
        let adx = -dx;
        let ady = -dy;
        if adx >= ady {
            4
        } else {
            5
        }
    } else {
        let ady = -dy;
        if dx < ady {
            6
        } else {
            7
        }
    };

    let ang45: Angle = ANG90 / 2;
    octant * ang45
}

#[cfg(test)]
mod tests {
    use fixed::from_int;
    use super::{Point, point_on_side, point_to_octant};

    fn pt(x: i64, y: i64) -> Point {
        Point { x: from_int(x), y: from_int(y) }
    }

    #[test]
    fn test_point_on_side_reference() {
        // Horizontal line from (0,0) to (10,0): points above are on one
        // side, points below on the other, points on the line are zero.
        let a = pt(0, 0);
        let b = pt(10, 0);
        assert(point_on_side(pt(5, 5), a, b) > 0, 'above line');
        assert(point_on_side(pt(5, -5), a, b) < 0, 'below line');
        assert(point_on_side(pt(5, 0), a, b) == 0, 'on line');
    }

    #[test]
    fn test_point_on_side_antisymmetric() {
        let a = pt(0, 0);
        let b = pt(10, 0);
        let p = pt(5, 5);
        // Swapping the line endpoints flips the sign.
        assert(point_on_side(p, a, b) == -point_on_side(p, b, a), 'antisymmetric');
    }

    #[test]
    fn test_octant_cardinal_directions() {
        let origin = pt(0, 0);
        assert(point_to_octant(origin, pt(10, 0)) == 0, 'east is octant 0');
        assert(point_to_octant(origin, pt(-10, 10)) == 3 * (0x40000000_u32 / 2), 'nw is octant 3');
        assert(point_to_octant(origin, pt(-10, -10)) == 4 * (0x40000000_u32 / 2), 'sw is octant 4');
        assert(point_to_octant(origin, pt(10, -10)) == 7 * (0x40000000_u32 / 2), 'se is octant 7');
    }

    #[test]
    fn test_octant_scale_invariant() {
        // Property: only the direction matters, not the magnitude.
        let origin = pt(0, 0);
        let small = point_to_octant(origin, pt(3, 1));
        let large = point_to_octant(origin, pt(30, 10));
        assert(small == large, 'scale invariant');
    }
}

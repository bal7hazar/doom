// SPDX-License-Identifier: GPL-2.0-or-later

use doom_map::{Level, is_line_blocking};
use doom_things::MobjType;
use fixed::Fixed;
use geom2d::{Point, point_on_side};

/// The radius a mover of `kind` occupies (delegates to `doom_things`'s
/// static catalogue; not yet used for collision, see README).
pub fn mover_radius(kind: MobjType) -> Fixed {
    doom_things::info_of(kind).radius
}

/// Whether the straight step from `from` to `to` crosses any blocking line
/// of `level` (a zero-radius simplification of `P_TryMove`'s core check).
pub fn can_move(level: @Level, from: Point, to: Point) -> bool {
    let mut i: u32 = 0;
    let blocked = loop {
        if i == level.lines.len() {
            break false;
        }
        if is_line_blocking(level, i) {
            let line = *level.lines.at(i);
            let side_from = point_on_side(from, line.a, line.b);
            let side_to = point_on_side(to, line.a, line.b);
            let side_a = point_on_side(line.a, from, to);
            let side_b = point_on_side(line.b, from, to);
            if side_from != side_to && side_a != side_b {
                break true;
            }
        }
        i += 1;
    };
    !blocked
}

#[cfg(test)]
mod tests {
    use doom_map::sample_level;
    use fixed::from_int;
    use geom2d::Point;
    use super::can_move;

    fn pt(x: i64, y: i64) -> Point {
        Point { x: from_int(x), y: from_int(y) }
    }

    #[test]
    fn test_crossing_blocking_line_is_rejected() {
        let level = sample_level();
        // The sample line runs from (0,0) to (64,0); this step crosses it.
        assert(!can_move(@level, pt(32, -10), pt(32, 10)), 'crossing is blocked');
    }

    #[test]
    fn test_move_not_crossing_any_line_is_allowed() {
        let level = sample_level();
        assert(can_move(@level, pt(32, 10), pt(32, 20)), 'clear move is allowed');
    }

    #[test]
    fn test_can_move_is_symmetric() {
        let level = sample_level();
        let a = pt(32, -10);
        let b = pt(32, 10);
        assert(can_move(@level, a, b) == can_move(@level, b, a), 'symmetric verdict');
    }
}

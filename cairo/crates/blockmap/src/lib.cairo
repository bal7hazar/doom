// SPDX-License-Identifier: Apache-2.0

use geom2d::Point;

#[derive(Copy, Drop, Serde)]
pub struct BlockMap {
    /// Raw 16.16 fixed coordinate of the grid's bottom-left corner.
    pub origin_x: i64,
    pub origin_y: i64,
    /// Raw 16.16 fixed size of one square cell (must be > 0).
    pub block_size: i64,
    pub width: u32,
    pub height: u32,
}

/// Locate the cell containing `p`, or `Option::None` if `p` falls outside
/// the blockmap's bounding box.
pub fn try_block_of(bm: BlockMap, p: Point) -> Option<(u32, u32)> {
    let dx: i64 = p.x.raw - bm.origin_x;
    let dy: i64 = p.y.raw - bm.origin_y;
    if dx < 0 || dy < 0 {
        return Option::None;
    }
    let cx: i64 = dx / bm.block_size;
    let cy: i64 = dy / bm.block_size;
    let cx_u: u32 = cx.try_into().unwrap();
    let cy_u: u32 = cy.try_into().unwrap();
    if cx_u >= bm.width || cy_u >= bm.height {
        return Option::None;
    }
    Option::Some((cx_u, cy_u))
}

/// Linear storage index for cell `(cx, cy)` in a `width`-wide grid.
pub fn cell_index(bm: BlockMap, cx: u32, cy: u32) -> u32 {
    cy * bm.width + cx
}

#[cfg(test)]
mod tests {
    use fixed::from_int;
    use geom2d::Point;
    use super::{BlockMap, cell_index, try_block_of};

    fn sample_bm() -> BlockMap {
        BlockMap { origin_x: 0, origin_y: 0, block_size: from_int(128).raw, width: 4, height: 4 }
    }

    fn pt(x: i64, y: i64) -> Point {
        Point { x: from_int(x), y: from_int(y) }
    }

    #[test]
    fn test_block_of_origin() {
        let bm = sample_bm();
        assert(try_block_of(bm, pt(0, 0)) == Option::Some((0, 0)), 'origin is cell 0,0');
    }

    #[test]
    fn test_block_of_inside_grid() {
        let bm = sample_bm();
        // 130 units in: still cell 1 (128 units per cell).
        assert(try_block_of(bm, pt(130, 130)) == Option::Some((1, 1)), 'second cell');
    }

    #[test]
    fn test_block_of_outside_grid_is_none() {
        let bm = sample_bm();
        assert(try_block_of(bm, pt(-1, 0)) == Option::None, 'negative x is out of bounds');
        assert(try_block_of(bm, pt(0, 10000)) == Option::None, 'far y is out of bounds');
    }

    #[test]
    fn test_cell_index_injective_on_a_row() {
        let bm = sample_bm();
        assert(cell_index(bm, 0, 0) != cell_index(bm, 1, 0), 'distinct cells, same row');
        assert(cell_index(bm, 0, 0) != cell_index(bm, 0, 1), 'distinct cells, same column');
        assert(cell_index(bm, 2, 1) == 1 * 4 + 2, 'matches row-major formula');
    }
}

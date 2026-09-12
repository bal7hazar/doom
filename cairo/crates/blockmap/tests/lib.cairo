// SPDX-License-Identifier: Apache-2.0
//! Integration tests: the loop-free part of the public API, as an external
//! consumer sees it.
//!
//! `scarb test` computes gas for this target even though the workspace sets
//! `enable-gas = false`, and Cairo lowers `while` into recursive functions,
//! whose cost computation then fails. `for_each_in_cell` and a full walk
//! therefore live in the unit tests (`src/tests.cairo`); what is here is the
//! geometry and the list accessors.

use blockmap::{
    CELL_RAW, CELL_UNITS, CellRange, Grid, PackedLists, cell_index, cell_of, cells_of_box,
    list_item, list_range, range_cell, range_len, walk_next, walk_start,
};
use fixed::from_units;
use geom2d::{Point, box_around};

fn grid() -> Grid {
    Grid { origin_x: from_units(-1024), origin_y: from_units(-1024), columns: 32, rows: 27 }
}

fn pt(x: felt252, y: felt252) -> Point {
    Point { x: from_units(x), y: from_units(y) }
}

#[test]
fn test_grid_geometry_from_outside_the_crate() {
    let g = grid();
    assert(CELL_UNITS == 128, '128 map units per cell');
    assert(CELL_RAW == 128 * 65536, 'and 2^23 raw units');
    assert(cell_of(g, pt(-1024, -1024)) == Option::Some((0, 0)), 'the origin cell');
    assert(cell_of(g, pt(0, 0)) == Option::Some((8, 8)), 'the middle of the map');
    assert(cell_of(g, pt(-1025, 0)) == Option::None, 'west of the grid');
    assert(cell_index(g, 8, 8) == 8 * 32 + 8, 'row-major index');

    // Cell (8, 8) spans [0, 128) on both axes, so its centre is (64, 64).
    let range = cells_of_box(g, box_around(pt(64, 64), from_units(16))).unwrap();
    assert(range == CellRange { x0: 8, y0: 8, x1: 8, y1: 8 }, 'a small box is one cell');
    assert(range_len(range) == 1, 'one cell');
    assert(range_cell(range, 0) == (8, 8), 'that cell');
    // A box straddling the x = 0 boundary covers two columns.
    let wide = cells_of_box(g, box_around(pt(-1, 64), from_units(16))).unwrap();
    assert(wide == CellRange { x0: 7, y0: 8, x1: 8, y1: 8 }, 'two columns');
    assert(range_len(wide) == 2, 'two cells');
    assert(range_cell(wide, 1) == (8, 8), 'the second of them');
}

#[test]
fn test_packed_lists_and_a_first_walk_step_from_outside() {
    let start: Array<u32> = array![0, 2, 2, 5];
    let items: Array<u32> = array![11, 22, 33, 44, 55];
    let lists = PackedLists { start: start.span(), items: items.span() };
    assert(list_range(@lists, 0) == (0, 2), 'cell 0 holds two entries');
    assert(list_range(@lists, 1) == (2, 2), 'cell 1 is empty');
    assert(list_range(@lists, 2) == (2, 5), 'cell 2 holds three');
    assert(list_item(@lists, 0) == 11 && list_item(@lists, 4) == 55, 'the entries');

    let g = grid();
    let mut walk = walk_start(g, pt(0, 0), pt(300, 0)).unwrap();
    assert(walk_next(ref walk) == Option::Some((8, 8)), 'starts in its own cell');
    assert(walk_next(ref walk) == Option::Some((9, 8)), 'then steps east');
    assert(walk_start(g, pt(-2000, 0), pt(0, 0)).is_none(), 'no walk from outside');
}

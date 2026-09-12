// SPDX-License-Identifier: Apache-2.0
//! Unit tests: generated reference vectors for `cell_of`, `cells_of_box` and
//! the segment walk, the packed-list iteration, and the properties and edge
//! cases of a grid that a mobj can walk off.

mod vectors;
use fixed::Fixed;
use geom2d::{Box, Point};
use vectors::{
    BX_B, BX_L, BX_OK, BX_R, BX_T, BX_X0, BX_X1, BX_Y0, BX_Y1, COLUMNS, CO_CX, CO_CY, CO_OK, CO_X,
    CO_Y, ORIGIN_X_ENC, ORIGIN_Y_ENC, PL_ITEMS, PL_START, ROWS, WK_CELLS, WK_START, WK_X1, WK_X2,
    WK_Y1, WK_Y2,
};
use super::{
    CELL_RAW, CellRange, Grid, ItemVisitor, PackedLists, Walk, cell_index, cell_of, cells_of_box,
    for_each_in_cell, list_item, list_range, range_cell, range_len, walk_next, walk_start,
};

#[derive(Drop)]
struct Collector {
    seen: Array<u32>,
    limit: u32,
}

impl CollectorVisitor of ItemVisitor<Collector> {
    fn visit(ref self: Collector, item: u32) -> bool {
        self.seen.append(item);
        self.seen.len() != self.limit
    }
}

fn grid() -> Grid {
    Grid {
        origin_x: Fixed { enc: ORIGIN_X_ENC },
        origin_y: Fixed { enc: ORIGIN_Y_ENC },
        columns: COLUMNS,
        rows: ROWS,
    }
}

fn lists() -> PackedLists {
    PackedLists { start: PL_START.span(), items: PL_ITEMS.span() }
}

fn pt_enc(x: felt252, y: felt252) -> Point {
    Point { x: Fixed { enc: x }, y: Fixed { enc: y } }
}

/// Collect a whole walk into an array (tests only: the crate itself never
/// materializes one).
fn walk_all(g: Grid, p1: Point, p2: Point) -> Array<(u32, u32)> {
    let mut out = array![];
    match walk_start(g, p1, p2) {
        Option::Some(w) => {
            let mut walk: Walk = w;
            loop {
                match walk_next(ref walk) {
                    Option::Some(c) => { out.append(c); },
                    Option::None => { break; },
                }
            }
        },
        Option::None => {},
    }
    out
}

// ---------------------------------------------------------------------------
// cell_of
// ---------------------------------------------------------------------------

#[test]
fn test_cell_of_matches_1000_reference_points() {
    let g = grid();
    let x = CO_X.span();
    let y = CO_Y.span();
    let ok = CO_OK.span();
    let cx = CO_CX.span();
    let cy = CO_CY.span();
    assert(ok.len() == 1000, '1000 points');
    let mut i: u32 = 0;
    let mut outside: u32 = 0;
    while i != 1000 {
        let got = cell_of(g, pt_enc(*x.at(i), *y.at(i)));
        if *ok.at(i) == 0 {
            outside += 1;
            assert(got == Option::None, 'outside the grid');
        } else {
            assert(got == Option::Some((*cx.at(i), *cy.at(i))), 'the right cell');
        }
        i += 1;
    }
    assert(outside > 300, 'enough points outside');
}

#[test]
fn test_cell_of_edge_cases() {
    let g = grid();
    let ox = ORIGIN_X_ENC;
    let oy = ORIGIN_Y_ENC;
    assert(cell_of(g, pt_enc(ox, oy)) == Option::Some((0, 0)), 'the origin corner');
    assert(cell_of(g, pt_enc(ox - 1, oy)) == Option::None, 'one ulp west');
    assert(cell_of(g, pt_enc(ox, oy - 1)) == Option::None, 'one ulp south');
    // The boundary belongs to the cell above/right of it.
    assert(cell_of(g, pt_enc(ox + CELL_RAW - 1, oy)) == Option::Some((0, 0)), 'last ulp of cell 0');
    assert(cell_of(g, pt_enc(ox + CELL_RAW, oy)) == Option::Some((1, 0)), 'first ulp of cell 1');
    // The far corner, and one ulp past it.
    let last_x = ox + COLUMNS.into() * CELL_RAW - 1;
    let last_y = oy + ROWS.into() * CELL_RAW - 1;
    assert(cell_of(g, pt_enc(last_x, last_y)) == Option::Some((COLUMNS - 1, ROWS - 1)), 'far cell');
    assert(cell_of(g, pt_enc(last_x + 1, last_y)) == Option::None, 'one ulp too far east');
    assert(cell_of(g, pt_enc(last_x, last_y + 1)) == Option::None, 'one ulp too far north');
}

#[test]
fn test_cell_index_is_injective() {
    let g = grid();
    assert(cell_index(g, 0, 0) == 0, 'first cell');
    assert(cell_index(g, 1, 0) == 1, 'second column');
    assert(cell_index(g, 0, 1) == COLUMNS, 'second row');
    assert(cell_index(g, COLUMNS - 1, ROWS - 1) == COLUMNS * ROWS - 1, 'last cell');
    // Row-major and injective over the whole grid.
    let mut seen_max: u32 = 0;
    let mut cy: u32 = 0;
    while cy != ROWS {
        let mut cx: u32 = 0;
        while cx != COLUMNS {
            let idx = cell_index(g, cx, cy);
            assert(idx == cy * COLUMNS + cx, 'row-major');
            if idx > seen_max {
                seen_max = idx;
            }
            cx += 1;
        }
        cy += 1;
    }
    assert(seen_max == COLUMNS * ROWS - 1, 'covers every index');
}

// ---------------------------------------------------------------------------
// cells_of_box
// ---------------------------------------------------------------------------

#[test]
fn test_cells_of_box_matches_400_reference_boxes() {
    let g = grid();
    let l = BX_L.span();
    let b = BX_B.span();
    let r = BX_R.span();
    let t = BX_T.span();
    let ok = BX_OK.span();
    let x0 = BX_X0.span();
    let y0 = BX_Y0.span();
    let x1 = BX_X1.span();
    let y1 = BX_Y1.span();
    assert(ok.len() == 400, '400 boxes');
    let mut i: u32 = 0;
    let mut outside: u32 = 0;
    while i != 400 {
        let box = Box {
            left: Fixed { enc: *l.at(i) },
            bottom: Fixed { enc: *b.at(i) },
            right: Fixed { enc: *r.at(i) },
            top: Fixed { enc: *t.at(i) },
        };
        let got = cells_of_box(g, box);
        if *ok.at(i) == 0 {
            outside += 1;
            assert(got == Option::None, 'the box misses the grid');
        } else {
            let expected = CellRange { x0: *x0.at(i), y0: *y0.at(i), x1: *x1.at(i), y1: *y1.at(i) };
            assert(got == Option::Some(expected), 'the right cell range');
        }
        i += 1;
    }
    assert(outside > 50, 'enough boxes outside');
}

#[test]
fn test_a_cell_range_contains_the_cells_of_the_boxs_corners() {
    // Property: whenever a corner is inside the grid, its cell is inside the
    // returned range.
    let g = grid();
    let l = BX_L.span();
    let b = BX_B.span();
    let r = BX_R.span();
    let t = BX_T.span();
    let mut i: u32 = 0;
    while i != 400 {
        let box = Box {
            left: Fixed { enc: *l.at(i) },
            bottom: Fixed { enc: *b.at(i) },
            right: Fixed { enc: *r.at(i) },
            top: Fixed { enc: *t.at(i) },
        };
        match cells_of_box(g, box) {
            Option::Some(range) => {
                assert(range.x0 <= range.x1 && range.y0 <= range.y1, 'a well-formed range');
                assert(range.x1 < COLUMNS && range.y1 < ROWS, 'clamped to the grid');
                match cell_of(g, Point { x: box.left, y: box.bottom }) {
                    Option::Some((
                        cx, cy,
                    )) => {
                        assert(cx >= range.x0 && cx <= range.x1, 'corner x in range');
                        assert(cy >= range.y0 && cy <= range.y1, 'corner y in range');
                    },
                    Option::None => {},
                }
            },
            Option::None => {},
        }
        i += 1;
    }
}

#[test]
fn test_range_enumeration() {
    let r = CellRange { x0: 2, y0: 3, x1: 4, y1: 5 };
    assert(range_len(r) == 9, '3 by 3 cells');
    assert(range_cell(r, 0) == (2, 3), 'first cell');
    assert(range_cell(r, 1) == (3, 3), 'row-major');
    assert(range_cell(r, 3) == (2, 4), 'second row');
    assert(range_cell(r, 8) == (4, 5), 'last cell');
    // Every index lands inside the range, and no two indices collide.
    let single = CellRange { x0: 7, y0: 7, x1: 7, y1: 7 };
    assert(range_len(single) == 1, 'a single cell');
    assert(range_cell(single, 0) == (7, 7), 'that cell');
    let mut k: u32 = 0;
    let mut sum: u32 = 0;
    while k != range_len(r) {
        let (cx, cy) = range_cell(r, k);
        assert(cx >= r.x0 && cx <= r.x1 && cy >= r.y0 && cy <= r.y1, 'inside the range');
        sum += cx * 100 + cy;
        k += 1;
    }
    assert(sum == 2736, 'each cell exactly once');
}

// ---------------------------------------------------------------------------
// Packed lists
// ---------------------------------------------------------------------------

#[test]
fn test_list_range_and_items_match_the_packed_arrays() {
    let l = lists();
    let start = PL_START.span();
    let items = PL_ITEMS.span();
    assert(start.len() == COLUMNS * ROWS + 1, 'one offset per cell plus one');
    let mut cell: u32 = 0;
    let mut total: u32 = 0;
    while cell != COLUMNS * ROWS {
        let (from, to) = list_range(@l, cell);
        assert(from == *start.at(cell), 'the start offset');
        assert(to == *start.at(cell + 1), 'the end offset');
        assert(to >= from, 'a well-formed slice');
        let mut i = from;
        while i != to {
            assert(list_item(@l, i) == *items.at(i), 'the right item');
            i += 1;
        }
        total += to - from;
        cell += 1;
    }
    assert(total == items.len(), 'every entry belongs to a cell');
}

#[test]
fn test_for_each_in_cell_visits_the_same_items_in_order() {
    let l = lists();
    let mut cell: u32 = 0;
    let mut non_empty: u32 = 0;
    while cell != 200 {
        let (from, to) = list_range(@l, cell);
        let mut collector = Collector { seen: array![], limit: 0xFFFFFFFF };
        let finished = for_each_in_cell(@l, cell, ref collector);
        assert(finished, 'nothing stopped it');
        assert(collector.seen.len() == to - from, 'as many items');
        let mut k: u32 = 0;
        while k != to - from {
            assert(*collector.seen.at(k) == list_item(@l, from + k), 'same order');
            k += 1;
        }
        if to != from {
            non_empty += 1;
        }
        cell += 1;
    }
    assert(non_empty > 100, 'enough non-empty cells');
}

#[test]
fn test_for_each_in_cell_stops_early() {
    let l = lists();
    // Find a cell with at least two entries.
    let mut cell: u32 = 0;
    let found = loop {
        let (from, to) = list_range(@l, cell);
        if to - from >= 2 {
            break cell;
        }
        cell += 1;
    };
    let mut collector = Collector { seen: array![], limit: 1 };
    let finished = for_each_in_cell(@l, found, ref collector);
    assert(!finished, 'the visitor stopped it');
    assert(collector.seen.len() == 1, 'only one item seen');
    let (from, _) = list_range(@l, found);
    assert(*collector.seen.at(0) == list_item(@l, from), 'the first item');
}

#[test]
fn test_an_empty_cell_visits_nothing() {
    let l = lists();
    let mut cell: u32 = 0;
    let empty = loop {
        let (from, to) = list_range(@l, cell);
        if to == from {
            break cell;
        }
        cell += 1;
    };
    let mut collector = Collector { seen: array![], limit: 0xFFFFFFFF };
    assert(for_each_in_cell(@l, empty, ref collector), 'an empty cell finishes');
    assert(collector.seen.len() == 0, 'nothing visited');
}

// ---------------------------------------------------------------------------
// Walking a segment
// ---------------------------------------------------------------------------

#[test]
fn test_walk_matches_200_reference_segments() {
    let g = grid();
    let x1 = WK_X1.span();
    let y1 = WK_Y1.span();
    let x2 = WK_X2.span();
    let y2 = WK_Y2.span();
    let start = WK_START.span();
    let flat = WK_CELLS.span();
    assert(x1.len() == 200, '200 segments');
    let mut t: u32 = 0;
    while t != 200 {
        let cells = walk_all(g, pt_enc(*x1.at(t), *y1.at(t)), pt_enc(*x2.at(t), *y2.at(t)));
        let from = *start.at(t);
        let to = *start.at(t + 1);
        assert(cells.len() * 2 == to - from, 'the same number of cells');
        let mut k: u32 = 0;
        while k != cells.len() {
            let (cx, cy) = *cells.at(k);
            assert(cx == *flat.at(from + k * 2), 'the same column');
            assert(cy == *flat.at(from + k * 2 + 1), 'the same row');
            k += 1;
        }
        t += 1;
    }
}

#[test]
fn test_a_walk_starts_where_the_ray_does_and_stays_on_the_grid() {
    let g = grid();
    let x1 = WK_X1.span();
    let y1 = WK_Y1.span();
    let x2 = WK_X2.span();
    let y2 = WK_Y2.span();
    let mut t: u32 = 0;
    while t != 100 {
        let p1 = pt_enc(*x1.at(t), *y1.at(t));
        let cells = walk_all(g, p1, pt_enc(*x2.at(t), *y2.at(t)));
        assert(cells.len() != 0, 'at least one cell');
        assert(*cells.at(0) == cell_of(g, p1).unwrap(), 'starts at the rays cell');
        let mut k: u32 = 0;
        while k != cells.len() {
            let (cx, cy) = *cells.at(k);
            assert(cx < COLUMNS && cy < ROWS, 'inside the grid');
            if k != 0 {
                // Consecutive cells are orthogonally adjacent: exactly one
                // axis changes, by exactly one.
                let (px, py) = *cells.at(k - 1);
                let dx = if cx >= px {
                    cx - px
                } else {
                    px - cx
                };
                let dy = if cy >= py {
                    cy - py
                } else {
                    py - cy
                };
                assert(dx + dy == 1, 'one step at a time');
            }
            k += 1;
        }
        t += 1;
    }
}

#[test]
fn test_walk_edge_cases() {
    let g = grid();
    let ox = ORIGIN_X_ENC;
    let oy = ORIGIN_Y_ENC;
    let inside = pt_enc(ox + CELL_RAW * 3 + 12345, oy + CELL_RAW * 2 + 6789);
    // A degenerate ray yields exactly its own cell.
    let same = walk_all(g, inside, inside);
    assert(same.len() == 1, 'one cell');
    assert(*same.at(0) == (3, 2), 'its own cell');
    // A ray that starts outside the grid has no walk at all.
    assert(walk_start(g, pt_enc(ox - 1, oy), inside).is_none(), 'starts outside');
    // Straight east across three cells.
    let east = walk_all(g, inside, pt_enc(ox + CELL_RAW * 5 + 1, oy + CELL_RAW * 2 + 6789));
    assert(east.len() == 3, 'three cells east');
    assert(*east.at(0) == (3, 2) && *east.at(2) == (5, 2), 'from column 3 to 5');
    // Straight south across two cells.
    let south = walk_all(g, inside, pt_enc(ox + CELL_RAW * 3 + 12345, oy + CELL_RAW + 1));
    assert(south.len() == 2, 'two cells south');
    assert(*south.at(1) == (3, 1), 'down one row');
    // A ray aimed off the grid stops at the border instead of running away.
    let out = walk_all(g, inside, pt_enc(ox + CELL_RAW * 100, oy + CELL_RAW * 2 + 6789));
    assert(out.len() == COLUMNS - 3, 'stops at the last column');
    let (lx, _) = *out.at(out.len() - 1);
    assert(lx == COLUMNS - 1, 'the last column');
}

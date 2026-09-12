//! Blockmap: cell lookup, bbox cell iteration, and a cell walk along a ray.
//!
//! Cell lists are emitted sorted and deduplicated by the extractor.  The
//! remaining duplication is *across* cells when a bbox spans several of them;
//! Doom solves it with `validcount`.  `collect_lines` implements both the
//! naive version (a line touched by k cells is tested k times) and the
//! deduplicated version, so R2-A5 can be priced.

use crate::fixed::felt_ge;
use crate::geom::Bbox;
use crate::mapdata::{
    BM_COLS, BM_COUNT, BM_LINES, BM_ORIGX, BM_ORIGY, BM_ROWS, BM_START,
};

/// 128 map units in 16.16.
pub const MAPBLOCKSIZE: u128 = 8388608;

/// Column/row of a biased fixed coordinate; clamped to the grid.
pub fn cell_x(x: felt252) -> u32 {
    if !felt_ge(x, BM_ORIGX) {
        return 0;
    }
    let d: u128 = (x - BM_ORIGX).try_into().unwrap();
    let c: u32 = (d / MAPBLOCKSIZE).try_into().unwrap();
    if c >= BM_COLS {
        BM_COLS - 1
    } else {
        c
    }
}

pub fn cell_y(y: felt252) -> u32 {
    if !felt_ge(y, BM_ORIGY) {
        return 0;
    }
    let d: u128 = (y - BM_ORIGY).try_into().unwrap();
    let c: u32 = (d / MAPBLOCKSIZE).try_into().unwrap();
    if c >= BM_ROWS {
        BM_ROWS - 1
    } else {
        c
    }
}

/// Append the lines of one cell to `out`, optionally skipping lines already
/// present (linear scan; the list is short -- 4.2 entries on average on E1M1).
fn push_cell(ref out: Array<felt252>, cx: u32, cy: u32, dedup: bool) {
    let cell = cy * BM_COLS + cx;
    let start: felt252 = *BM_START.span().at(cell);
    let count: felt252 = *BM_COUNT.span().at(cell);
    let s: u32 = start.try_into().unwrap();
    let n: u32 = count.try_into().unwrap();
    let lines = BM_LINES.span();
    let mut i: u32 = 0;
    while i != n {
        let li = *lines.at(s + i);
        if dedup {
            let mut j: u32 = 0;
            let mut seen = false;
            let cur = out.span();
            while j != cur.len() {
                if *cur.at(j) == li {
                    seen = true;
                    break;
                }
                j += 1;
            }
            if !seen {
                out.append(li);
            }
        } else {
            out.append(li);
        }
        i += 1;
    }
}

/// All blockmap lines touching `bx`.
pub fn collect_bbox(bx: Bbox, dedup: bool) -> Array<felt252> {
    let x0 = cell_x(bx.l);
    let x1 = cell_x(bx.r);
    let y0 = cell_y(bx.b);
    let y1 = cell_y(bx.t);
    let mut out: Array<felt252> = array![];
    let mut cy = y0;
    while cy <= y1 {
        let mut cx = x0;
        while cx <= x1 {
            push_cell(ref out, cx, cy, dedup);
            cx += 1;
        }
        cy += 1;
    }
    out
}

/// Cells crossed by the segment (x0,y0)-(x1,y1), Bresenham-free: the cell
/// indices are interpolated with `max(|dcx|, |dcy|) + 1` samples.  Good enough
/// for a cost spike; the real `blockmap` crate should use Doom's exact
/// P_PathTraverse DDA so the set of cells matches the C code.
pub fn collect_ray(
    x0: felt252, y0: felt252, x1: felt252, y1: felt252, dedup: bool,
) -> Array<felt252> {
    let cx0 = cell_x(x0);
    let cy0 = cell_y(y0);
    let cx1 = cell_x(x1);
    let cy1 = cell_y(y1);
    let dx = if cx1 >= cx0 {
        cx1 - cx0
    } else {
        cx0 - cx1
    };
    let dy = if cy1 >= cy0 {
        cy1 - cy0
    } else {
        cy0 - cy1
    };
    let n = if dx >= dy {
        dx
    } else {
        dy
    };
    let mut out: Array<felt252> = array![];
    let mut k: u32 = 0;
    while k <= n {
        let cx = if n == 0 {
            cx0
        } else if cx1 >= cx0 {
            cx0 + (dx * k) / n
        } else {
            cx0 - (dx * k) / n
        };
        let cy = if n == 0 {
            cy0
        } else if cy1 >= cy0 {
            cy0 + (dy * k) / n
        } else {
            cy0 - (dy * k) / n
        };
        push_cell(ref out, cx, cy, dedup);
        k += 1;
    }
    out
}

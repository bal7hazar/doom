//! R_PointInSubsector via the generated NODES tree.

use crate::blockmap::{cell_x, cell_y};
use crate::geom::{hoist, node_side_six, node_side_three};
use crate::mapdata::{BIGC, BM_CELL_SECTOR, BM_COLS, N_C0, N_C1, ROOT_NODE, SS_SECTOR};

const SUBSECTOR_BIT: u32 = 0x8000;

/// Descend the BSP to the subsector containing (x, y).  `three` selects the
/// 3-array half-plane representation (R2-A4) over the 6-array baseline.
pub fn point_in_subsector(x: felt252, y: felt252, three: bool) -> u32 {
    let h = hoist(x, y, BIGC);
    let c0 = N_C0.span();
    let c1 = N_C1.span();
    let mut n: u32 = ROOT_NODE;
    let mut out: u32 = 0;
    loop {
        if n >= SUBSECTOR_BIT {
            out = n - SUBSECTOR_BIT;
            break;
        }
        let side = if three {
            node_side_three(n, x, y, h)
        } else {
            node_side_six(n, x, y)
        };
        // Doom: side 0 => front child (children[0]).
        let nxt: felt252 = if side == 0 {
            *c0.at(n)
        } else {
            *c1.at(n)
        };
        n = nxt.try_into().unwrap();
    }
    out
}

/// Sector containing (x, y).
pub fn sector_at(x: felt252, y: felt252, three: bool) -> u32 {
    let ss = point_in_subsector(x, y, three);
    let s: felt252 = *SS_SECTOR.span().at(ss);
    s.try_into().unwrap()
}

/// Sector containing (x, y), skipping the BSP when the blockmap cell holding
/// the point contains no linedef: such a cell lies entirely inside one sector,
/// so the answer was precomputed by the extractor.  Two array reads instead of
/// a ten-level descent.
pub fn sector_at_fast(x: felt252, y: felt252, three: bool, fast: bool) -> u32 {
    if fast {
        let cell = cell_y(y) * BM_COLS + cell_x(x);
        let c: felt252 = *BM_CELL_SECTOR.span().at(cell);
        if c != 65535 {
            return c.try_into().unwrap();
        }
    }
    sector_at(x, y, three)
}

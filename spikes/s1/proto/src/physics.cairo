//! P_TryMove-lite, PIT_CheckLine-lite and a P_PathTraverse-lite hitscan.
//!
//! No sliding: a blocked move stops the mobj, as specified for the spike.

use crate::blockmap::{collect_bbox, collect_ray};
use crate::bsp::sector_at_fast;
use crate::fixed::{Sf, felt_ge, felt_sub};
use crate::geom::{Bbox, box_crosses_six, box_crosses_three, box_hoist, bbox_reject};
use crate::mapdata::{
    BIGC, L_AB, L_BACK, L_BB, L_BLOCKING, L_CB, L_DIAG, L_FRONT, L_TWOSIDED, L_V1X, L_V1Y, L_V2X,
    L_V2Y, S_CEIL, S_FLOOR,
};
use crate::mobj::{MAX_STEP, MOBJ_HEIGHT, Opts};

#[derive(Copy, Drop)]
pub struct MoveResult {
    pub ok: bool,
    pub sector: u32,
    pub floorz: felt252,
}

/// PIT_CheckLine-lite for a single linedef already known to straddle the box.
fn check_line_blocks(li: u32, newfloor: felt252) -> bool {
    if *L_TWOSIDED.span().at(li) == 0 {
        return true;
    }
    if *L_BLOCKING.span().at(li) == 1 {
        return true;
    }
    let fs: felt252 = *L_FRONT.span().at(li);
    let bs: felt252 = *L_BACK.span().at(li);
    let fsu: u32 = fs.try_into().unwrap();
    let bsu: u32 = bs.try_into().unwrap();
    let ffl = *S_FLOOR.span().at(fsu);
    let fce = *S_CEIL.span().at(fsu);
    let bfl = *S_FLOOR.span().at(bsu);
    let bce = *S_CEIL.span().at(bsu);
    let lowceil = if felt_ge(fce, bce) {
        bce
    } else {
        fce
    };
    let highfloor = if felt_ge(ffl, bfl) {
        ffl
    } else {
        bfl
    };
    // opening too low to walk through
    if !felt_ge(lowceil, highfloor + MOBJ_HEIGHT) {
        return true;
    }
    // step too high
    if felt_ge(highfloor, newfloor + MAX_STEP) {
        return true;
    }
    false
}

/// P_TryMove-lite.  Returns whether the position (nx, ny) is reachable, plus
/// the sector and floor height there.
pub fn try_move(nx: felt252, ny: felt252, radius: felt252, opts: Opts) -> MoveResult {
    let bx = Bbox { l: nx - radius, r: nx + radius, b: ny - radius, t: ny + radius };
    let sec = sector_at_fast(nx, ny, opts.three, opts.fastsector);
    let newfloor = *S_FLOOR.span().at(sec);

    let lines = collect_bbox(bx, opts.dedup);
    let h = box_hoist(bx, BIGC);
    let ab = L_AB.span();
    let bb = L_BB.span();
    let cb = L_CB.span();
    let dg = L_DIAG.span();

    let mut ok = true;
    let mut i: u32 = 0;
    let s = lines.span();
    let n = s.len();
    while i != n {
        let lf: felt252 = *s.at(i);
        let li: u32 = lf.try_into().unwrap();
        i += 1;
        // The bbox test is NOT an optimisation: `box_crosses_*` tests the
        // *infinite* line, so a segment whose extension crosses the box has to
        // be discarded by comparing bounding boxes.  Doom does bbox first
        // because comparisons are free in C.  In Cairo a comparison costs more
        // than a multiplication, and `box_crosses_*` already rejects most
        // lines, so the cheaper order is half-plane first, bbox second.
        // `opts.bboxreject` restores Doom's order for the measurement.
        if opts.bboxreject {
            if bbox_reject(li, bx) {
                continue;
            }
            let crosses = if opts.three {
                box_crosses_three(*ab.at(li), *bb.at(li), *cb.at(li), *dg.at(li), bx, h)
            } else {
                box_crosses_six(li, *dg.at(li), bx)
            };
            if !crosses {
                continue;
            }
        } else {
            let crosses = if opts.three {
                box_crosses_three(*ab.at(li), *bb.at(li), *cb.at(li), *dg.at(li), bx, h)
            } else {
                box_crosses_six(li, *dg.at(li), bx)
            };
            if !crosses {
                continue;
            }
            if bbox_reject(li, bx) {
                continue;
            }
        }
        if check_line_blocks(li, newfloor) {
            ok = false;
            break;
        }
    }
    MoveResult { ok, sector: sec, floorz: newfloor }
}

/// Sign of the cross product of the ray (x0,y0)->(dx,dy) with the point (px,py),
/// entirely in magnitude/sign form: no division, no negative felt.
fn ray_side(dx: Sf, dy: Sf, x0: felt252, y0: felt252, px: felt252, py: felt252) -> u32 {
    let ux = felt_sub(px, x0);
    let uy = felt_sub(py, y0);
    // cross = dx*uy - dy*ux
    let a = dx.m * uy.m;
    let an = if dx.neg == uy.neg {
        0_u32
    } else {
        1_u32
    };
    let b = dy.m * ux.m;
    let bn = if dy.neg == ux.neg {
        0_u32
    } else {
        1_u32
    };
    // sign of (a with sign an) - (b with sign bn)
    if an == 0 && bn == 1 {
        return 1;
    }
    if an == 1 && bn == 0 {
        return 0;
    }
    if an == 0 {
        if felt_ge(a, b) {
            1
        } else {
            0
        }
    } else if felt_ge(b, a) {
        1
    } else {
        0
    }
}

/// Does the segment (x0,y0)-(x1,y1) cross linedef `li`?
pub fn seg_crosses_line(
    li: u32, x0: felt252, y0: felt252, x1: felt252, y1: felt252, opts: Opts,
) -> bool {
    // endpoints of the segment on opposite sides of the line
    let bxa = Bbox { l: x0, r: x0, b: y0, t: y0 };
    let bxb = Bbox { l: x1, r: x1, b: y1, t: y1 };
    let ha = box_hoist(bxa, BIGC);
    let hb = box_hoist(bxb, BIGC);
    let ab = *L_AB.span().at(li);
    let bb = *L_BB.span().at(li);
    let cb = *L_CB.span().at(li);
    let s0 = felt_ge(ab * y0 + bb * x0 + cb, ha.lt);
    let s1 = felt_ge(ab * y1 + bb * x1 + cb, hb.lt);
    if s0 == s1 {
        return false;
    }
    let _ = opts;
    // endpoints of the line on opposite sides of the segment
    let dx = felt_sub(x1, x0);
    let dy = felt_sub(y1, y0);
    let v1x = *L_V1X.span().at(li);
    let v1y = *L_V1Y.span().at(li);
    let v2x = *L_V2X.span().at(li);
    let v2y = *L_V2Y.span().at(li);
    ray_side(dx, dy, x0, y0, v1x, v1y) != ray_side(dx, dy, x0, y0, v2x, v2y)
}

/// P_PathTraverse-lite: walk the blockmap cells along the shot and return the
/// index of the first blocking linedef found, or `NUM_LINES` for "no hit".
pub fn path_traverse(
    x0: felt252, y0: felt252, x1: felt252, y1: felt252, opts: Opts,
) -> u32 {
    let lines = collect_ray(x0, y0, x1, y1, opts.dedup);
    let s = lines.span();
    let n = s.len();
    let mut i: u32 = 0;
    let mut hit: u32 = 0xFFFF;
    while i != n {
        let lf: felt252 = *s.at(i);
        let li: u32 = lf.try_into().unwrap();
        i += 1;
        // only solid or explicitly blocking lines stop a hitscan
        if *L_TWOSIDED.span().at(li) == 1 && *L_BLOCKING.span().at(li) == 0 {
            continue;
        }
        if seg_crosses_line(li, x0, y0, x1, y1, opts) {
            hit = li;
            break;
        }
    }
    hit
}

// SPDX-License-Identifier: GPL-2.0-only
//! `P_CheckSight` (`p_sight.c`): REJECT first, then the vanilla slope /
//! opening test on every two-sided line the sight line crosses, with a
//! one-sided line blocking outright.
//!
//! # The candidate lines come from the blockmap, not from the SEGS
//!
//! Doom walks the BSP (`P_CrossBSPNode`) and tests the SEGS of every
//! subsector the trace crosses. `doom_map` compiles no SEGS in (they are
//! renderer data), so the crate walks the **blockmap ray** instead
//! (`ray::Cursor`) and tests every linedef of every cell the trace crosses.
//! The two visit the same set of crossed linedefs, and the verdict is a pure
//! function of that set: `topslope`/`bottomslope` only ever narrow, so the
//! final `topslope <= bottomslope` does not depend on the order, and a
//! one-sided line or a closed opening blocks whatever else is crossed. A
//! linedef in two visited cells is tested twice (S1 §7 rejects cross-cell
//! deduplication at 4.6× the cost); the second test only re-narrows to the
//! same slopes. `scripts/model.py` cross-checks an exact transcription of
//! this walk against a float transcription of Doom's BSP walk on every
//! emitted pair. S1 §7 recommended exactly this ("ligne de vue par rayon
//! blockmap plutôt que par traversée BSP").
//!
//! # R2-A3 cache
//!
//! [`check_sight_cached`] keeps the verdict on the looker for `ttl` tics as
//! long as the target has not changed sector, so an awake monster re-asks
//! the expensive question at most once per `ttl` tics.

use doom_map::{ML_TWOSIDED, reject_of};
use fixed::{BIAS, Fixed, felt_ge_narrow, to_u128};
use geom2d::Point;
use super::maputl::{add32, inc, line_box_misses, line_hp, line_opening, line_sides, rd, rd32};
use super::mobj::{Mobj, has};
use super::ray::{
    Trace, crosses_sight, crossing_fraction, ray_advance, ray_cell, ray_start, trace_of,
};
use super::world::{Level, World, level_of};

/// `t1->z + t1->height - (t1->height >> 2)`: the eyes of the looker.
fn sight_z(t: @Mobj) -> Fixed {
    let h = to_u128(*t.height.enc - BIAS); // heights are positive
    let quarter: felt252 = (h / 4).into();
    Fixed { enc: *t.z.enc + *t.height.enc - BIAS - quarter }
}

/// `P_CheckSight`: can `t1` see `t2`?
///
/// **Measured on E1M1**: ~300 steps when REJECT answers, and a few thousand
/// for a traversal, growing with the number of lines in the cells the trace
/// crosses (see the README's table).
pub fn check_sight(w: World, t1: @Mobj, t2: @Mobj) -> bool {
    // REJECT first, always (R2-A2: ×24.7 on E1M1).
    if reject_of(w.map.reject, w.map.reject_stride, w.map.pow2, *t1.sector, *t2.sector) {
        return false;
    }
    let sightz = sight_z(t1);
    // Slopes are `dz / frac`, i.e. the height difference scaled to the whole
    // trace; Doom keeps them as fixed_t and divides by the crossing fraction.
    let top = fixed::sub(fixed::add(*t2.z, *t2.height), sightz);
    let bottom = fixed::sub(*t2.z, sightz);
    sight_trace(
        level_of(w),
        Point { x: *t1.x, y: *t1.y },
        Point { x: *t2.x, y: *t2.y },
        sightz,
        top,
        bottom,
    )
}

/// The traversal: every cell of the ray, every line of the cell.
fn sight_trace(lv: Level, p1: Point, p2: Point, sightz: Fixed, top: Fixed, bottom: Fixed) -> bool {
    let grid = lv.hot.unbox().grid;
    let mut cur = match ray_start(grid, p1, p2) {
        Option::Some(c) => c,
        Option::None => { return false; },
    };
    let tr = trace_of(p1, p2);
    let mut top = top;
    let mut bottom = bottom;
    loop {
        let cell = match ray_cell(cur, grid) {
            Option::Some(c) => c,
            Option::None => { break true; },
        };
        let (blocked, t, b) = sight_cell(lv, tr, cell, sightz, top, bottom);
        if blocked {
            break false;
        }
        top = t;
        bottom = b;
        ray_advance(ref cur, grid.columns, grid.rows);
    }
}

/// `P_CrossSubsector`'s test on every line of `cell`: `(blocked, topslope,
/// bottomslope)`.
fn sight_cell(
    lv: Level, tr: Box<Trace>, cell: u32, sightz: Fixed, top: Fixed, bottom: Fixed,
) -> (bool, Fixed, Fixed) {
    let bm_start = lv.hot.unbox().bm_start;
    let mut j = rd32(bm_start, cell);
    let end = rd32(bm_start, inc(cell));
    let mut top = top;
    let mut bottom = bottom;
    let blocked = loop {
        if j == end {
            break false;
        }
        let map = lv.hot.unbox();
        let line = rd32(map.bm_items, j);
        j = inc(j);
        let packed_box = rd(map.l_box, line);
        if line_box_misses(packed_box, tr.unbox().tb) {
            continue;
        }
        let hp = line_hp(map.l_ab, map.l_bb, map.l_cb, line);
        let lbox = match crosses_sight(tr, hp, packed_box) {
            Option::Some(b) => b,
            Option::None => { continue; },
        };
        let (flags, front, back) = line_sides(rd(map.l_packed, line));
        if !has(flags, ML_TWOSIDED) {
            break true; // stop
        }
        let o = line_opening(lv.floor, lv.ceil, front, back);
        if !o.floors_differ && !o.ceilings_differ {
            continue; // no wall to block sight with
        }
        if felt_ge_narrow(o.bottom.enc, o.top.enc) {
            break true; // quick test for totally closed doors
        }
        let frac = crossing_fraction(tr, hp, lbox);
        if frac.enc == BIAS {
            continue; // parallel (cannot happen for a crossed line)
        }
        if o.floors_differ {
            let slope = fixed::div(fixed::sub(o.bottom, sightz), frac);
            if fixed::gt(slope, bottom) {
                bottom = slope;
            }
        }
        if o.ceilings_differ {
            let slope = fixed::div(fixed::sub(o.top, sightz), frac);
            if fixed::lt(slope, top) {
                top = slope;
            }
        }
        if fixed::le(top, bottom) {
            break true; // stop
        }
    };
    (blocked, top, bottom)
}

/// [`check_sight`] behind the R2-A3 cache on `looker`: while
/// `tic < looker.sight_expires` and `target.sector == looker.sight_sector`
/// the stored verdict is returned; otherwise the sight line is traced and
/// the verdict kept for `ttl` tics.
pub fn check_sight_cached(w: World, ref looker: Mobj, target: @Mobj, tic: u32, ttl: u32) -> bool {
    let fresh = tic < looker.sight_expires && *target.sector == looker.sight_sector;
    let ok = if fresh {
        looker.sight_ok
    } else {
        check_sight(w, @looker, target)
    };
    if !fresh {
        looker.sight_ok = ok;
        looker.sight_sector = *target.sector;
        looker.sight_expires = add32(tic, ttl);
    }
    ok
}

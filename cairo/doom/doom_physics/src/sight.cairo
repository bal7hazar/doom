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
//! (`ray::Ray`) and tests every linedef of every cell the trace crosses.
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
use fixed::{BIAS, Fixed, felt_ge};
use geom2d::Point;
use super::maputl::{line_flags, line_hp, line_meta, line_opening};
use super::mobj::{Mobj, has};
use super::ray::{crosses_sight, crossing_fraction, ray_advance, ray_cell, ray_start};
use super::world::World;

/// `t1->z + t1->height - (t1->height >> 2)`: the eyes of the looker.
fn sight_z(t: @Mobj) -> Fixed {
    let h: u128 = (*t.height.enc - BIAS).try_into().unwrap(); // heights are positive
    let quarter: felt252 = (h / 4).into();
    Fixed { enc: *t.z.enc + *t.height.enc - BIAS - quarter }
}

/// `P_CheckSight`: can `t1` see `t2`?
///
/// **Measured on E1M1**: ~110 steps when REJECT answers, and ~2 000 to
/// ~9 000 for a traversal, growing with the number of lines in the cells the
/// trace crosses (see the README's table).
pub fn check_sight(w: World, t1: @Mobj, t2: @Mobj) -> bool {
    // REJECT first, always (R2-A2: ×24.7 on E1M1).
    if reject_of(w.map.reject, w.map.reject_stride, w.map.pow2, *t1.sector, *t2.sector) {
        return false;
    }
    let p1 = Point { x: *t1.x, y: *t1.y };
    let p2 = Point { x: *t2.x, y: *t2.y };
    let grid = w.map.grid;
    let mut ray = match ray_start(grid, p1, p2) {
        Option::Some(r) => r,
        Option::None => { return false; },
    };
    let sightz = sight_z(t1);
    // Slopes are `dz / frac`, i.e. the height difference scaled to the whole
    // trace; Doom keeps them as fixed_t and divides by the crossing fraction.
    let mut top = fixed::sub(fixed::add(*t2.z, *t2.height), sightz);
    let mut bottom = fixed::sub(*t2.z, sightz);

    let l_ab = w.map.l_ab;
    let l_bb = w.map.l_bb;
    let l_cb = w.map.l_cb;
    let l_box = w.map.l_box;
    let l_packed = w.map.l_packed;
    let bm_start = w.map.bm_start;
    let bm_items = w.map.bm_items;
    let floor = w.floor;
    let ceil = w.ceil;
    let mut visible = true;
    loop {
        let cell = match ray_cell(@ray, grid) {
            Option::Some(c) => c,
            Option::None => { break; },
        };
        let mut j = *bm_start.at(cell);
        let end = *bm_start.at(cell + 1);
        let mut blocked = false;
        while j != end {
            let line = *bm_items.at(j);
            j += 1;
            let hp = line_hp(l_ab, l_bb, l_cb, line);
            let lbox = match crosses_sight(@ray, hp, l_box, line) {
                Option::Some(b) => b,
                Option::None => { continue; },
            };
            let packed = *l_packed.at(line);
            if !has(line_flags(packed), ML_TWOSIDED) {
                blocked = true; // stop
                break;
            }
            let meta = line_meta(packed);
            let o = line_opening(floor, ceil, meta.front, meta.back);
            if !o.floors_differ && !o.ceilings_differ {
                continue; // no wall to block sight with
            }
            if felt_ge(o.bottom.enc, o.top.enc) {
                blocked = true; // quick test for totally closed doors
                break;
            }
            let frac = crossing_fraction(@ray, hp, lbox);
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
                blocked = true; // stop
                break;
            }
        }
        if blocked {
            visible = false;
            break;
        }
        ray_advance(ref ray);
    }
    visible
}

/// [`check_sight`] behind the R2-A3 cache on `looker`: while
/// `tic < looker.sight_expires` and `target.sector == looker.sight_sector`
/// the stored verdict is returned; otherwise the sight line is traced and
/// the verdict kept for `ttl` tics.
pub fn check_sight_cached(w: World, ref looker: Mobj, target: @Mobj, tic: u32, ttl: u32) -> bool {
    if tic < looker.sight_expires && *target.sector == looker.sight_sector {
        return looker.sight_ok;
    }
    let ok = check_sight(w, @looker, target);
    looker.sight_ok = ok;
    looker.sight_sector = *target.sector;
    looker.sight_expires = tic + ttl;
    ok
}

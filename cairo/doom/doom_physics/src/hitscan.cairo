// SPDX-License-Identifier: GPL-2.0-only
//! `P_PathTraverse` (`p_maputl.c`) and the hitscan attacks built on it,
//! `P_AimLineAttack` / `P_LineAttack` (`p_map.c`).
//!
//! # Intercepts, cell by cell
//!
//! Doom collects every crossing along the trace, sorts by fraction, then
//! walks the sorted list (`P_TraverseIntercepts`). The blockmap ray visits
//! cells nearest first, so the same order comes cheaper **per cell**: the
//! ray's segment inside cell `k` spans the fractions `[entry_k, entry_k+1)`,
//! and a line listed in the cell is crossed *in this cell* exactly when its
//! `P_InterceptVector` fraction lies in that span — otherwise it is crossed
//! in another cell that also lists it (a blockmap lists a line in every cell
//! it passes through), and is processed there. Each cell's few crossings
//! (plus the things whose centre is in the cell, as Doom finds them) are
//! sorted and handed to a [`Traverser`], and the walk stops as soon as a
//! visit returns `false` — at the first wall, for a typical room shot.
//! This replaces a global sort (O(n²) on a long trace: 22 000 steps of
//! sorting alone for a 1 700-unit shot down E1M1's hall) with a handful of
//! comparisons per cell.
//!
//! Puffs and blood are **events**, not mobjs: the [`Hit`] carries the point
//! where `P_SpawnPuff`/`P_SpawnBlood` would have put one, for the caller to
//! hand to the renderer. Spawning them as mobjs would cost a `locate`
//! (~700 steps) plus a slot and four state transitions each, for a purely
//! visual effect that the simulation never reads back.

use bam::Angle;
use doom_map::ML_TWOSIDED;
use fixed::{BIAS, Fixed, felt_ge};
use geom2d::{DivLine, Point, intercept_fraction};
use super::grid::{ThingGrid, things_in};
use super::maputl::{line_flags, line_hp, line_meta, line_opening};
use super::mobj::{MF_NOBLOOD, MF_SHOOTABLE, Mobj, NO_MOBJ, has};
use super::ray::{
    crosses, crossing_fraction, ray_advance, ray_cell, ray_next_entry, ray_start, trace_side,
};
use super::world::World;

/// `MISSILERANGE` — 32 × 64 units, `P_LineAttack`'s range for guns.
pub const MISSILERANGE: Fixed = Fixed { enc: BIAS + 32 * 64 * 65536 };
/// `MELEERANGE` — 64 units.
pub const MELEERANGE: Fixed = Fixed { enc: BIAS + 64 * 65536 };
/// `16 * 64` units, `P_GunShot`'s auto-aim range.
pub const AIMRANGE: Fixed = Fixed { enc: BIAS + 16 * 64 * 65536 };
/// `100 * FRACUNIT / 160`: the auto-aim cone's half-height slope.
const AIM_SLOPE: felt252 = 40960;

/// One crossing along the trace: a line or a thing, at `frac`.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct Intercept {
    pub frac: Fixed,
    pub is_line: bool,
    pub id: u32,
}

/// What a traversal does at each intercept, nearest first. Returning
/// `false` stops the traversal (`PTR_*Traverse`'s convention).
pub trait Traverser<T> {
    fn line(ref self: T, line: u32, frac: Fixed) -> bool;
    fn thing(ref self: T, idx: u32, frac: Fixed) -> bool;
}

/// `(frac, is_line, id)` order: `a` strictly before `b`.
fn before(a: Intercept, b: Intercept) -> bool {
    if a.frac == b.frac {
        if a.is_line == b.is_line {
            a.id < b.id
        } else {
            a.is_line
        }
    } else {
        fixed::lt(a.frac, b.frac)
    }
}

/// The nearest intercept of `list` after `prev` (`None`: the nearest of
/// all) — `P_TraverseIntercepts`'s "pick the closest remaining", on the
/// short per-cell batch.
fn next_intercept(list: Span<Intercept>, prev: Option<Intercept>) -> Option<Intercept> {
    let n = list.len();
    let mut best: Option<Intercept> = Option::None;
    let mut k: u32 = 0;
    while k != n {
        let it = *list.at(k);
        k += 1;
        let after_prev = match prev {
            Option::Some(p) => before(p, it),
            Option::None => true,
        };
        if !after_prev {
            continue;
        }
        best = match best {
            Option::Some(b) => if before(it, b) {
                Option::Some(it)
            } else {
                Option::Some(b)
            },
            Option::None => Option::Some(it),
        };
    }
    best
}

/// `P_PathTraverse` with `PT_ADDLINES` (and `PT_ADDTHINGS` when
/// `add_things`): visit every crossing along `p1 -> p2` with `0 <= frac <
/// 1`, nearest first, until `visitor` refuses. `shooter` is skipped among
/// the things. Returns `true` when the whole trace was walked.
pub fn traverse<T, impl V: Traverser<T>, +Drop<T>>(
    w: World,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    p1: Point,
    p2: Point,
    add_things: bool,
    shooter: u32,
    ref visitor: T,
) -> bool {
    let grid = w.map.grid;
    let mut ray = match ray_start(grid, p1, p2) {
        Option::Some(r) => r,
        Option::None => { return true; },
    };
    let l_ab = w.map.l_ab;
    let l_bb = w.map.l_bb;
    let l_cb = w.map.l_cb;
    let l_box = w.map.l_box;
    let bm_start = w.map.bm_start;
    let bm_items = w.map.bm_items;
    // The thing test crosses the trace with the box diagonal facing it.
    let tracepositive = fixed::is_neg(ray.dl.dx) == fixed::is_neg(ray.dl.dy);
    let mut walked = true;
    loop {
        let cell = match ray_cell(@ray, grid) {
            Option::Some(c) => c,
            Option::None => { break; },
        };
        let entry = ray.entry;
        let mut exit = ray_next_entry(@ray);
        if fixed::gt(exit, fixed::FRACUNIT) {
            exit = fixed::FRACUNIT;
        }
        let mut batch: Array<Intercept> = array![];
        // Lines crossed inside this cell's span of the trace.
        let mut j = *bm_start.at(cell);
        let end = *bm_start.at(cell + 1);
        while j != end {
            let line = *bm_items.at(j);
            j += 1;
            let hp = line_hp(l_ab, l_bb, l_cb, line);
            let lbox = match crosses(@ray, hp, l_box, line) {
                Option::Some(b) => b,
                Option::None => { continue; },
            };
            let frac = crossing_fraction(@ray, hp, lbox);
            if !fixed::ge(frac, entry) || !fixed::lt(frac, exit) {
                continue; // crossed in another cell, or behind the source
            }
            batch.append(Intercept { frac, is_line: true, id: line });
        }
        // Things whose centre is in this cell.
        if add_things {
            let list = things_in(ref g, cell);
            let n = list.len();
            let mut k: u32 = 0;
            while k != n {
                let idx = *list.at(k);
                k += 1;
                if idx == shooter {
                    continue;
                }
                let t = mobjs.at(idx);
                let r = *t.radius;
                let (c1, c2) = if tracepositive {
                    (
                        Point { x: fixed::sub(*t.x, r), y: fixed::add(*t.y, r) },
                        Point { x: fixed::add(*t.x, r), y: fixed::sub(*t.y, r) },
                    )
                } else {
                    (
                        Point { x: fixed::sub(*t.x, r), y: fixed::sub(*t.y, r) },
                        Point { x: fixed::add(*t.x, r), y: fixed::add(*t.y, r) },
                    )
                };
                if trace_side(@ray.dl, c1) == trace_side(@ray.dl, c2) {
                    continue; // the diagonal isn't crossed
                }
                let dl = DivLine {
                    x: c1.x, y: c1.y, dx: fixed::sub(c2.x, c1.x), dy: fixed::sub(c2.y, c1.y),
                };
                let frac = intercept_fraction(ray.dl, dl);
                if fixed::is_neg(frac) || !fixed::lt(frac, fixed::FRACUNIT) {
                    continue;
                }
                batch.append(Intercept { frac, is_line: false, id: idx });
            }
        }
        // Visit the cell's crossings in order.
        let items = batch.span();
        let mut prev: Option<Intercept> = Option::None;
        let mut stopped = false;
        loop {
            let it = match next_intercept(items, prev) {
                Option::Some(i) => i,
                Option::None => { break; },
            };
            prev = Option::Some(it);
            let go_on = if it.is_line {
                visitor.line(it.id, it.frac)
            } else {
                visitor.thing(it.id, it.frac)
            };
            if !go_on {
                stopped = true;
                break;
            }
        }
        if stopped {
            walked = false;
            break;
        }
        ray_advance(ref ray);
    }
    walked
}

/// A traverser that only collects (tests, tools): every intercept, in
/// visiting order.
#[derive(Drop)]
struct Collector {
    out: Array<Intercept>,
}

impl CollectorTraverser of Traverser<Collector> {
    fn line(ref self: Collector, line: u32, frac: Fixed) -> bool {
        self.out.append(Intercept { frac, is_line: true, id: line });
        true
    }
    fn thing(ref self: Collector, idx: u32, frac: Fixed) -> bool {
        self.out.append(Intercept { frac, is_line: false, id: idx });
        true
    }
}

/// Every crossing along `p1 -> p2`, in the order [`traverse`] visits them.
pub fn path_traverse(
    w: World,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    p1: Point,
    p2: Point,
    add_things: bool,
    shooter: u32,
) -> Array<Intercept> {
    let mut c = Collector { out: array![] };
    traverse(w, mobjs, ref g, p1, p2, add_things, shooter, ref c);
    c.out
}

/// The end of a trace of `range` at `angle` from `p`.
fn trace_end(p: Point, angle: Angle, range: Fixed) -> Point {
    let (s, c) = bam::sin_cos(angle);
    Point { x: fixed::add(p.x, fixed::mul(range, c)), y: fixed::add(p.y, fixed::mul(range, s)) }
}

/// `t1->z + (t1->height >> 1) + 8 * FRACUNIT`: the gun's height.
fn shoot_z(t: @Mobj) -> Fixed {
    let h: u128 = (*t.height.enc - BIAS).try_into().unwrap();
    let half: felt252 = (h / 2).into();
    Fixed { enc: *t.z.enc + half + 8 * 65536 }
}

// ---------------------------------------------------------------------------
// P_AimLineAttack
// ---------------------------------------------------------------------------

/// `P_AimLineAttack`'s answer.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct Aim {
    /// The slope to shoot at (`0` when nothing was found).
    pub slope: Fixed,
    /// `linetarget`, or [`NO_MOBJ`].
    pub target: u32,
}

/// `PTR_AimTraverse`'s state.
#[derive(Drop)]
struct Aimer {
    mobjs: Span<Mobj>,
    l_packed: Span<felt252>,
    floor: Span<felt252>,
    ceil: Span<felt252>,
    shootz: Fixed,
    range: Fixed,
    topslope: Fixed,
    bottomslope: Fixed,
    aim: Aim,
}

impl AimerTraverser of Traverser<Aimer> {
    fn line(ref self: Aimer, line: u32, frac: Fixed) -> bool {
        let packed = *self.l_packed.at(line);
        if !has(line_flags(packed), ML_TWOSIDED) {
            return false; // stop
        }
        let meta = line_meta(packed);
        let o = line_opening(self.floor, self.ceil, meta.front, meta.back);
        if felt_ge(o.bottom.enc, o.top.enc) {
            return false; // stop
        }
        let dist = fixed::mul(self.range, frac);
        if o.floors_differ {
            let slope = fixed::div(fixed::sub(o.bottom, self.shootz), dist);
            if fixed::gt(slope, self.bottomslope) {
                self.bottomslope = slope;
            }
        }
        if o.ceilings_differ {
            let slope = fixed::div(fixed::sub(o.top, self.shootz), dist);
            if fixed::lt(slope, self.topslope) {
                self.topslope = slope;
            }
        }
        !fixed::le(self.topslope, self.bottomslope) // stop once the cone closes
    }

    fn thing(ref self: Aimer, idx: u32, frac: Fixed) -> bool {
        let t = self.mobjs.at(idx);
        if !has(*t.flags, MF_SHOOTABLE) {
            return true; // corpse or something
        }
        let dist = fixed::mul(self.range, frac);
        let mut thingtopslope = fixed::div(
            fixed::sub(fixed::add(*t.z, *t.height), self.shootz), dist,
        );
        if fixed::lt(thingtopslope, self.bottomslope) {
            return true; // shot over the thing
        }
        let mut thingbottomslope = fixed::div(fixed::sub(*t.z, self.shootz), dist);
        if fixed::gt(thingbottomslope, self.topslope) {
            return true; // shot under the thing
        }
        // This thing can be hit!
        if fixed::gt(thingtopslope, self.topslope) {
            thingtopslope = self.topslope;
        }
        if fixed::lt(thingbottomslope, self.bottomslope) {
            thingbottomslope = self.bottomslope;
        }
        self
            .aim =
                Aim {
                    slope: super::movement::half_of(fixed::add(thingtopslope, thingbottomslope)),
                    target: idx,
                };
        false // don't go any farther
    }
}

/// `P_AimLineAttack`: the first shootable thing inside the auto-aim cone
/// along `angle` within `distance`, and the slope to it.
pub fn aim_line_attack(
    w: World, mobjs: Span<Mobj>, ref g: ThingGrid, shooter: u32, angle: Angle, distance: Fixed,
) -> Aim {
    let t1 = mobjs.at(shooter);
    let p1 = Point { x: *t1.x, y: *t1.y };
    let p2 = trace_end(p1, angle, distance);
    let mut aimer = Aimer {
        mobjs,
        l_packed: w.map.l_packed,
        floor: w.floor,
        ceil: w.ceil,
        shootz: shoot_z(t1),
        range: distance,
        topslope: Fixed { enc: BIAS + AIM_SLOPE },
        bottomslope: Fixed { enc: BIAS - AIM_SLOPE },
        aim: Aim { slope: fixed::ZERO, target: NO_MOBJ },
    };
    traverse(w, mobjs, ref g, p1, p2, true, shooter, ref aimer);
    aimer.aim
}

// ---------------------------------------------------------------------------
// P_LineAttack
// ---------------------------------------------------------------------------

/// What a `P_LineAttack` hit.
#[derive(Copy, Drop, PartialEq, Debug)]
pub enum Hit {
    /// Nothing within range.
    Nothing,
    /// A wall or a closed/slope-blocking two-sided line: `(line, puff at)`.
    Wall: (u32, Point, Fixed),
    /// A shootable thing: `(thing, blood at)` — or a puff when the thing has
    /// `MF_NOBLOOD`. The caller applies `damage_mobj(thing, shooter,
    /// shooter, damage)`.
    Thing: (u32, Point, Fixed),
}

/// `PTR_ShootTraverse`'s state.
#[derive(Drop)]
struct Shooter {
    mobjs: Span<Mobj>,
    l_packed: Span<felt252>,
    floor: Span<felt252>,
    ceil: Span<felt252>,
    dl: DivLine,
    shootz: Fixed,
    range: Fixed,
    slope: Fixed,
    hit: Hit,
}

/// The point at `frac` along a divline.
fn point_along(dl: DivLine, frac: Fixed) -> Point {
    Point {
        x: fixed::add(dl.x, fixed::mul(dl.dx, frac)), y: fixed::add(dl.y, fixed::mul(dl.dy, frac)),
    }
}

impl ShooterTraverser of Traverser<Shooter> {
    fn line(ref self: Shooter, line: u32, frac: Fixed) -> bool {
        let packed = *self.l_packed.at(line);
        let mut hitline = !has(line_flags(packed), ML_TWOSIDED);
        if !hitline {
            let meta = line_meta(packed);
            let o = line_opening(self.floor, self.ceil, meta.front, meta.back);
            let dist = fixed::mul(self.range, frac);
            if o.floors_differ
                && fixed::gt(fixed::div(fixed::sub(o.bottom, self.shootz), dist), self.slope) {
                hitline = true;
            } else if o.ceilings_differ
                && fixed::lt(fixed::div(fixed::sub(o.top, self.shootz), dist), self.slope) {
                hitline = true;
            }
        }
        if !hitline {
            return true; // shot continues
        }
        // Hit line: the puff is pulled back 4 units along the trace.
        let back = fixed::sub(frac, fixed::div(Fixed { enc: BIAS + 4 * 65536 }, self.range));
        let z = fixed::add(self.shootz, fixed::mul(self.slope, fixed::mul(back, self.range)));
        self.hit = Hit::Wall((line, point_along(self.dl, back), z));
        false
    }

    fn thing(ref self: Shooter, idx: u32, frac: Fixed) -> bool {
        let t = self.mobjs.at(idx);
        if !has(*t.flags, MF_SHOOTABLE) {
            return true;
        }
        let dist = fixed::mul(self.range, frac);
        let thingtopslope = fixed::div(fixed::sub(fixed::add(*t.z, *t.height), self.shootz), dist);
        if fixed::lt(thingtopslope, self.slope) {
            return true; // shot over the thing
        }
        let thingbottomslope = fixed::div(fixed::sub(*t.z, self.shootz), dist);
        if fixed::gt(thingbottomslope, self.slope) {
            return true; // shot under the thing
        }
        // Hit thing: the blood is pulled back 10 units along the trace.
        let back = fixed::sub(frac, fixed::div(Fixed { enc: BIAS + 10 * 65536 }, self.range));
        let z = fixed::add(self.shootz, fixed::mul(self.slope, fixed::mul(back, self.range)));
        self.hit = Hit::Thing((idx, point_along(self.dl, back), z));
        false
    }
}

/// `P_LineAttack`: shoot from `shooter` along `angle` at `slope`, up to
/// `distance`. Damage is not applied here (the target is another mobj);
/// the [`Hit`] says where it lands. Special lines the shot crosses
/// (`P_ShootSpecialLine`, the gun-activated switches) are not reported —
/// none of E1M1's specials is gun-activated.
///
/// Doom skips the puff when the wall's ceiling is the sky; `doom_map`
/// carries no flat names, so a puff is reported there too (visual only).
pub fn line_attack(
    w: World,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    shooter: u32,
    angle: Angle,
    distance: Fixed,
    slope: Fixed,
) -> Hit {
    let t1 = mobjs.at(shooter);
    let p1 = Point { x: *t1.x, y: *t1.y };
    let p2 = trace_end(p1, angle, distance);
    let mut s = Shooter {
        mobjs,
        l_packed: w.map.l_packed,
        floor: w.floor,
        ceil: w.ceil,
        dl: DivLine { x: p1.x, y: p1.y, dx: fixed::sub(p2.x, p1.x), dy: fixed::sub(p2.y, p1.y) },
        shootz: shoot_z(t1),
        range: distance,
        slope,
        hit: Hit::Nothing,
    };
    traverse(w, mobjs, ref g, p1, p2, true, shooter, ref s);
    s.hit
}

/// Whether a [`Hit::Thing`] shows blood (a puff otherwise, `MF_NOBLOOD`).
pub fn bleeds(t: @Mobj) -> bool {
    !has(*t.flags, MF_NOBLOOD)
}

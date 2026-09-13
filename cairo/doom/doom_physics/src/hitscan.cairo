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
//! The collection of a cell's intercepts ([`cell_intercepts`]) is one
//! concrete function; only the short dispatch loop of [`traverse`] is
//! generic over the traverser (S7: the whole walk used to be monomorphised
//! once per traverser).
//!
//! Puffs and blood are **events**, not mobjs: the [`Hit`] carries the point
//! where `P_SpawnPuff`/`P_SpawnBlood` would have put one, for the caller to
//! hand to the renderer. Spawning them as mobjs would cost a `locate`
//! (~700 steps) plus a slot and four state transitions each, for a purely
//! visual effect that the simulation never reads back.

use bam::Angle;
use core::num::traits::WrappingAdd;
use doom_map::ML_TWOSIDED;
use fixed::{BIAS, Fixed, felt_ge_narrow, to_u128};
use geom2d::{DivLine, Point, intercept_fraction};
use super::grid::{ThingGrid, things_in};
use super::maputl::{inc, line_box_misses, line_hp, line_opening, line_sides, opaque_zero, rd, rd32};
use super::mobj::{MF_NOBLOOD, MF_SHOOTABLE, Mobj, NO_MOBJ, has};
use super::ray::{
    Cursor, Trace, crosses, crossing_fraction, ray_advance, ray_cell, ray_next_entry, ray_start,
    trace_of, trace_side,
};
use super::world::{Level, World, level_of};

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

/// The nearest intercept of `list` not yet `taken` (a bit per position:
/// the batch of one cell holds a handful) — `P_TraverseIntercepts`'s "pick
/// the closest remaining". Returns its position bit and the intercept.
fn next_intercept(mut list: Span<Intercept>, taken: u32) -> Option<(u32, Intercept)> {
    let mut best: Option<(u32, Intercept)> = Option::None;
    let mut bit: u32 = inc(opaque_zero(taken));
    while let Option::Some(item) = list.pop_front() {
        let it = *item;
        let this = bit;
        bit = bit.wrapping_add(bit);
        if taken & this != 0 {
            continue;
        }
        best = match best {
            Option::Some((b_bit, b)) => if before(it, b) {
                Option::Some((this, it))
            } else {
                Option::Some((b_bit, b))
            },
            Option::None => Option::Some((this, it)),
        };
    }
    best
}

/// The lines of `cell` crossed inside the trace's span `[entry, exit)`
/// through it, appended to `batch`.
fn cell_lines(
    lv: Level, tr: Box<Trace>, cell: u32, entry: Fixed, exit: Fixed, ref batch: Array<Intercept>,
) {
    let bm_start = lv.hot.unbox().bm_start;
    let mut j = rd32(bm_start, cell);
    let end = rd32(bm_start, inc(cell));
    loop {
        if j == end {
            break;
        }
        let map = lv.hot.unbox();
        let line = rd32(map.bm_items, j);
        j = inc(j);
        let packed_box = rd(map.l_box, line);
        if line_box_misses(packed_box, tr.unbox().tb) {
            continue;
        }
        let hp = line_hp(map.l_ab, map.l_bb, map.l_cb, line);
        let lbox = match crosses(tr, hp, packed_box) {
            Option::Some(b) => b,
            Option::None => { continue; },
        };
        let frac = crossing_fraction(tr, hp, lbox);
        if !fixed::ge(frac, entry) || !fixed::lt(frac, exit) {
            continue; // crossed in another cell, or behind the source
        }
        batch.append(Intercept { frac, is_line: true, id: line });
    }
}

/// The things whose centre is in `cell` and whose box diagonal the trace
/// crosses (`PIT_AddThingIntercepts`), appended to `batch`.
fn cell_things(
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    tr: Box<Trace>,
    cell: u32,
    tracepositive: bool,
    shooter: u32,
    ref batch: Array<Intercept>,
) {
    let mut list = things_in(ref g, cell);
    loop {
        let idx = match list.pop_front() {
            Option::Some(i) => *i,
            Option::None => { break; },
        };
        if idx == shooter {
            continue;
        }
        let t = match mobjs.get(idx) {
            Option::Some(b) => b.unbox().as_snapshot().unbox(),
            Option::None => { continue; },
        };
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
        let dl = tr.unbox().dl;
        if trace_side(dl, c1) == trace_side(dl, c2) {
            continue; // the diagonal isn't crossed
        }
        let diag = DivLine {
            x: c1.x, y: c1.y, dx: fixed::sub(c2.x, c1.x), dy: fixed::sub(c2.y, c1.y),
        };
        let frac = intercept_fraction(dl, diag);
        if fixed::is_neg(frac) || !fixed::lt(frac, fixed::FRACUNIT) {
            continue;
        }
        batch.append(Intercept { frac, is_line: false, id: idx });
    }
}

/// Every intercept of the current cell of `cur`, unsorted.
fn cell_intercepts(
    lv: Level,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    tr: Box<Trace>,
    cur: Cursor,
    cell: u32,
    add_things: bool,
    tracepositive: bool,
    shooter: u32,
) -> Array<Intercept> {
    let mut batch: Array<Intercept> = array![];
    let mut exit = ray_next_entry(cur);
    if fixed::gt(exit, fixed::FRACUNIT) {
        exit = fixed::FRACUNIT;
    }
    cell_lines(lv, tr, cell, cur.entry, exit, ref batch);
    if add_things {
        cell_things(mobjs, ref g, tr, cell, tracepositive, shooter, ref batch);
    }
    batch
}

/// `P_PathTraverse` with `PT_ADDLINES` (and `PT_ADDTHINGS` when
/// `add_things`): visit every crossing along `p1 -> p2` with `0 <= frac <
/// 1`, nearest first, until `visitor` refuses. `shooter` is skipped among
/// the things. Returns `true` when the whole trace was walked.
pub fn traverse<T, impl V: Traverser<T>, +Drop<T>>(
    w: World,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    p1: Point,
    p2: Point,
    add_things: bool,
    shooter: u32,
    ref visitor: T,
) -> bool {
    traverse_in::<T, V>(level_of(w), mobjs, ref g, p1, p2, add_things, shooter, ref visitor)
}

/// [`traverse`] on a [`Level`].
pub fn traverse_in<T, impl V: Traverser<T>, +Drop<T>>(
    lv: Level,
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    p1: Point,
    p2: Point,
    add_things: bool,
    shooter: u32,
    ref visitor: T,
) -> bool {
    let grid = lv.hot.unbox().grid;
    let mut cur = match ray_start(grid, p1, p2) {
        Option::Some(r) => r,
        Option::None => { return true; },
    };
    let tr = trace_of(p1, p2);
    // The thing test crosses the trace with the box diagonal facing it.
    let dl = tr.unbox().dl;
    let tracepositive = fixed::is_neg(dl.dx) == fixed::is_neg(dl.dy);
    loop {
        let cell = match ray_cell(cur, grid) {
            Option::Some(c) => c,
            Option::None => { break true; },
        };
        let batch = cell_intercepts(
            lv, mobjs, ref g, tr, cur, cell, add_things, tracepositive, shooter,
        );
        // Visit the cell's crossings in order.
        let items = batch.span();
        let mut taken: u32 = opaque_zero(items.len());
        let stopped = loop {
            let (bit, it) = match next_intercept(items, taken) {
                Option::Some(i) => i,
                Option::None => { break false; },
            };
            taken = taken | bit;
            let go_on = if it.is_line {
                visitor.line(it.id, it.frac)
            } else {
                visitor.thing(it.id, it.frac)
            };
            if !go_on {
                break true;
            }
        };
        if stopped {
            break false;
        }
        ray_advance(ref cur, grid.columns, grid.rows);
    }
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
    mobjs: Span<Box<Mobj>>,
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
    let two: NonZero<u128> = 2;
    let (h, _) = DivRem::div_rem(to_u128(*t.height.enc - BIAS), two);
    let half: felt252 = h.into();
    Fixed { enc: *t.z.enc + half + 8 * 65536 }
}

/// What both attacks' traversers read at every intercept, behind one
/// pointer.
#[derive(Copy, Drop)]
struct ShotCtx {
    lv: Level,
    mobjs: Span<Box<Mobj>>,
    tr: Box<Trace>,
}

/// `P_LineOpening` of `line` from its packed felt, or `None` for a one-sided
/// line.
fn opening_of(ctx: Box<ShotCtx>, line: u32) -> Option<super::maputl::Opening> {
    let c = ctx.unbox();
    let (flags, front, back) = line_sides(rd(c.lv.hot.unbox().l_packed, line));
    if !has(flags, ML_TWOSIDED) {
        return Option::None;
    }
    Option::Some(line_opening(c.lv.floor, c.lv.ceil, front, back))
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
#[derive(Copy, Drop)]
struct Aimer {
    ctx: Box<ShotCtx>,
    shootz: Fixed,
    range: Fixed,
    topslope: Fixed,
    bottomslope: Fixed,
    aim: Aim,
}

impl AimerTraverser of Traverser<Aimer> {
    fn line(ref self: Aimer, line: u32, frac: Fixed) -> bool {
        let o = match opening_of(self.ctx, line) {
            Option::Some(o) => o,
            Option::None => { return false; } // stop
        };
        if felt_ge_narrow(o.bottom.enc, o.top.enc) {
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
        let t = match self.ctx.unbox().mobjs.get(idx) {
            Option::Some(b) => b.unbox().as_snapshot().unbox(),
            Option::None => { return true; },
        };
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
    w: World, mobjs: Span<Box<Mobj>>, ref g: ThingGrid, shooter: u32, angle: Angle, distance: Fixed,
) -> Aim {
    let lv = level_of(w);
    let t1 = match mobjs.get(shooter) {
        Option::Some(b) => b.unbox().as_snapshot().unbox(),
        Option::None => { return Aim { slope: fixed::ZERO, target: NO_MOBJ }; },
    };
    let p1 = Point { x: *t1.x, y: *t1.y };
    let p2 = trace_end(p1, angle, distance);
    let tr = trace_of(p1, p2);
    let mut aimer = Aimer {
        ctx: BoxTrait::new(ShotCtx { lv, mobjs, tr }),
        shootz: shoot_z(t1),
        range: distance,
        topslope: Fixed { enc: BIAS + AIM_SLOPE },
        bottomslope: Fixed { enc: BIAS - AIM_SLOPE },
        aim: Aim { slope: fixed::ZERO, target: NO_MOBJ },
    };
    traverse_in(lv, mobjs, ref g, p1, p2, true, shooter, ref aimer);
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
#[derive(Copy, Drop)]
struct Shooter {
    ctx: Box<ShotCtx>,
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

/// Where a shot that stops at `frac`, pulled back by `pullback` units,
/// lands: `(point, z)`.
fn impact(
    ctx: Box<ShotCtx>, shootz: Fixed, range: Fixed, slope: Fixed, frac: Fixed, pullback: Fixed,
) -> (Point, Fixed) {
    let back = fixed::sub(frac, fixed::div(pullback, range));
    let z = fixed::add(shootz, fixed::mul(slope, fixed::mul(back, range)));
    (point_along(ctx.unbox().tr.unbox().dl, back), z)
}

impl ShooterTraverser of Traverser<Shooter> {
    fn line(ref self: Shooter, line: u32, frac: Fixed) -> bool {
        let hitline = match opening_of(self.ctx, line) {
            Option::None => true,
            Option::Some(o) => {
                let dist = fixed::mul(self.range, frac);
                if o.floors_differ
                    && fixed::gt(fixed::div(fixed::sub(o.bottom, self.shootz), dist), self.slope) {
                    true
                } else if o.ceilings_differ
                    && fixed::lt(fixed::div(fixed::sub(o.top, self.shootz), dist), self.slope) {
                    true
                } else {
                    false
                }
            },
        };
        if !hitline {
            return true; // shot continues
        }
        // Hit line: the puff is pulled back 4 units along the trace.
        let (p, z) = impact(
            self.ctx, self.shootz, self.range, self.slope, frac, Fixed { enc: BIAS + 4 * 65536 },
        );
        self.hit = Hit::Wall((line, p, z));
        false
    }

    fn thing(ref self: Shooter, idx: u32, frac: Fixed) -> bool {
        let t = match self.ctx.unbox().mobjs.get(idx) {
            Option::Some(b) => b.unbox().as_snapshot().unbox(),
            Option::None => { return true; },
        };
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
        let (p, z) = impact(
            self.ctx, self.shootz, self.range, self.slope, frac, Fixed { enc: BIAS + 10 * 65536 },
        );
        self.hit = Hit::Thing((idx, p, z));
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
    mobjs: Span<Box<Mobj>>,
    ref g: ThingGrid,
    shooter: u32,
    angle: Angle,
    distance: Fixed,
    slope: Fixed,
) -> Hit {
    let lv = level_of(w);
    let t1 = match mobjs.get(shooter) {
        Option::Some(b) => b.unbox().as_snapshot().unbox(),
        Option::None => { return Hit::Nothing; },
    };
    let p1 = Point { x: *t1.x, y: *t1.y };
    let p2 = trace_end(p1, angle, distance);
    let tr = trace_of(p1, p2);
    let mut s = Shooter {
        ctx: BoxTrait::new(ShotCtx { lv, mobjs, tr }),
        shootz: shoot_z(t1),
        range: distance,
        slope,
        hit: Hit::Nothing,
    };
    traverse_in(lv, mobjs, ref g, p1, p2, true, shooter, ref s);
    s.hit
}

/// Whether a [`Hit::Thing`] shows blood (a puff otherwise, `MF_NOBLOOD`).
pub fn bleeds(t: @Mobj) -> bool {
    !has(*t.flags, MF_NOBLOOD)
}

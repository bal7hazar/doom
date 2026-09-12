// SPDX-License-Identifier: GPL-2.0-only
//! Movement clipping and integration: `P_CheckPosition`, `P_TryMove`,
//! `P_SlideMove` (`p_map.c`) and `P_XYMovement`, `P_ZMovement` (`p_mobj.c`).
//!
//! Cross-mobj effects are **not** applied here: a mobj is a value the caller
//! owns, and the list is an `Array` with no random write. Instead the move
//! reports what it touched as [`MoveEvent`]s — a special line crossed, an
//! item touched, a thing a missile hit — and `doom_game` applies them. What
//! `P_TryMove` reads about *other* things comes from the `Span<Mobj>` of the
//! tic's starting state.

use blockmap::{CELL_RAW, CellRange, Grid, cell_index, cells_of_box, range_cell, range_len};
use doom_map::{ML_BLOCKING, ML_BLOCKMONSTERS, ML_TWOSIDED, NO_SECTOR};
use doom_things::tables::KIND_PLAYER;
use fixed::{BIAS, FRACUNIT_RAW, Fixed, felt_ge};
use geom2d::{Box, Point, SIDE_BACK, SIDE_CROSS, box_around, box_on_line_side, hoist, point_side};
use super::grid::{ThingGrid, things_in};
use super::maputl::{line_box_rejects, line_diagonal, line_hp, line_meta, line_opening};
use super::mobj::{
    MF_CORPSE, MF_DROPOFF, MF_FLOAT, MF_INFLOAT, MF_MISSILE, MF_NOCLIP, MF_NOGRAVITY, MF_PICKUP,
    MF_SHOOTABLE, MF_SKULLFLY, MF_SOLID, MF_SPECIAL, MF_TELEPORT, Mobj, NO_CELL, NO_MOBJ, has,
    without,
};
use super::position::{Location, place, subsector_from_root, subsector_in_cell};
use super::ray::{crosses, crossing_fraction, ray_advance, ray_cell, ray_start};
use super::world::World;

/// `MAXSTEP` — 24 units.
pub const MAXSTEP: Fixed = Fixed { enc: BIAS + 24 * 65536 };
/// `MAXRADIUS` — 32 units, the widening of the thing search box.
pub const MAXRADIUS: Fixed = Fixed { enc: BIAS + 32 * 65536 };
/// `FRICTION` — `0xe800`.
pub const FRICTION: Fixed = Fixed { enc: BIAS + 0xe800 };
/// `STOPSPEED` — `0x1000`.
pub const STOPSPEED: felt252 = 0x1000;
/// `MAXMOVE` — 30 units.
pub const MAXMOVE: felt252 = 30 * 65536;
/// `MAXMOVE / 2`, the threshold above which a move is done in halves.
const HALF_MAXMOVE: felt252 = 15 * 65536;
/// `GRAVITY` — one unit per tic squared.
pub const GRAVITY: felt252 = 65536;
/// `FLOATSPEED` — 4 units.
pub const FLOATSPEED: felt252 = 4 * 65536;
/// "No opening folded yet": a height above / below any map height.
const OPEN_HIGH: felt252 = BIAS + 0x7FFF0000;
const OPEN_LOW: felt252 = BIAS - 0x7FFF0000;
/// Largest number of straddled special lines a move remembers (Doom's
/// `MAXSPECIALCROSS` is 8; four is the most any move on E1M1 can straddle).
pub const MAX_SPECIAL_CROSS: u32 = 4;

/// Why a move was refused.
#[derive(Copy, Drop, PartialEq, Debug)]
pub enum Blocker {
    Nothing,
    /// A one-sided, `ML_BLOCKING` or `ML_BLOCKMONSTERS` line.
    Line: u32,
    /// A solid thing (or, for a missile, the thing it hit).
    Thing: u32,
    /// `tmceilingz - tmfloorz < height`: the thing does not fit.
    Fit,
    /// `tmceilingz - z < height`: it must lower itself first.
    Ceiling,
    /// `tmfloorz - z > MAXSTEP`: too high a step.
    Step,
    /// `tmfloorz - tmdropoffz > MAXSTEP`: a monster refusing a ledge.
    Dropoff,
}

/// What a move touched, for `doom_game` to apply.
#[derive(Copy, Drop, PartialEq, Debug)]
pub enum MoveEvent {
    /// A special line was crossed: `(line, side the thing came from)` —
    /// `P_CrossSpecialLine(line, oldside, thing)`.
    CrossSpecial: (u32, u8),
    /// An `MF_SPECIAL` thing was touched by a picker-up:
    /// `P_TouchSpecialThing(item, toucher)`.
    Touch: u32,
    /// A missile hit a shootable thing: `P_DamageMobj(thing, missile,
    /// missile.target, (P_Random() % 8 + 1) * info.damage)`.
    MissileHit: u32,
}

/// `P_CheckPosition`'s answer.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct Check {
    pub ok: bool,
    pub blocker: Blocker,
    /// `tmfloorz`, `tmceilingz`, `tmdropoffz`.
    pub floorz: Fixed,
    pub ceilingz: Fixed,
    pub dropoffz: Fixed,
    /// Where the tested point lies (reused by `try_move`, so that a move
    /// locates once where Doom locates twice).
    pub loc: Location,
    /// Special lines the box straddles (`spechit`), up to
    /// [`MAX_SPECIAL_CROSS`].
    pub nspec: u32,
    pub spec0: u32,
    pub spec1: u32,
    pub spec2: u32,
    pub spec3: u32,
}

/// `P_TryMove`'s answer.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct Verdict {
    pub ok: bool,
    /// Doom's `floatok`: the thing fits between floor and ceiling at the
    /// target, even if the move was refused for another reason.
    pub floatok: bool,
    pub blocker: Blocker,
}

/// The cell of `p`, knowing the (clamped) cell range its box covers: one
/// comparison per axis instead of `blockmap::cell_of`'s two divisions, plus
/// a bounds test when the range touches the grid's edge. `None` when the
/// point itself is off the grid although its box still reaches it.
fn cell_in_range(g: Grid, r: CellRange, p: Point) -> Option<u32> {
    let cx = if r.x1 == r.x0 {
        r.x0
    } else if felt_ge(p.x.enc, g.origin_x.enc + r.x1.into() * CELL_RAW) {
        r.x1
    } else {
        r.x0
    };
    let cy = if r.y1 == r.y0 {
        r.y0
    } else if felt_ge(p.y.enc, g.origin_y.enc + r.y1.into() * CELL_RAW) {
        r.y1
    } else {
        r.y0
    };
    if cx == 0 && !felt_ge(p.x.enc, g.origin_x.enc) {
        return Option::None;
    }
    if cx + 1 == g.columns && felt_ge(p.x.enc, g.origin_x.enc + g.columns.into() * CELL_RAW) {
        return Option::None;
    }
    if cy == 0 && !felt_ge(p.y.enc, g.origin_y.enc) {
        return Option::None;
    }
    if cy + 1 == g.rows && felt_ge(p.y.enc, g.origin_y.enc + g.rows.into() * CELL_RAW) {
        return Option::None;
    }
    Option::Some(cell_index(g, cx, cy))
}

/// Widen a cell range by `MAXRADIUS` on every side it can grow into: the
/// thing search box of `P_CheckPosition`, for one comparison per side.
fn widen(g: Grid, b: Box, r: CellRange) -> CellRange {
    let x0 = if r.x0 != 0
        && !felt_ge(b.left.enc - MAXRADIUS.enc + BIAS, g.origin_x.enc + r.x0.into() * CELL_RAW) {
        r.x0 - 1
    } else {
        r.x0
    };
    let x1 = if r.x1
        + 1 != g.columns
            && felt_ge(
                b.right.enc + MAXRADIUS.enc - BIAS, g.origin_x.enc + (r.x1 + 1).into() * CELL_RAW,
            ) {
        r.x1 + 1
    } else {
        r.x1
    };
    let y0 = if r.y0 != 0
        && !felt_ge(b.bottom.enc - MAXRADIUS.enc + BIAS, g.origin_y.enc + r.y0.into() * CELL_RAW) {
        r.y0 - 1
    } else {
        r.y0
    };
    let y1 = if r.y1
        + 1 != g.rows
            && felt_ge(
                b.top.enc + MAXRADIUS.enc - BIAS, g.origin_y.enc + (r.y1 + 1).into() * CELL_RAW,
            ) {
        r.y1 + 1
    } else {
        r.y1
    };
    CellRange { x0, y0, x1, y1 }
}

/// `PIT_CheckThing` over every thing in `cell`. Returns the blocking thing,
/// or `NO_MOBJ`.
fn check_things_in_cell(
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    cell: u32,
    mo: @Mobj,
    me: u32,
    x: Fixed,
    y: Fixed,
    ref events: Array<MoveEvent>,
) -> u32 {
    let list = things_in(ref g, cell);
    let n = list.len();
    let tmflags = *mo.flags;
    let missile = has(tmflags, MF_MISSILE);
    let mut k: u32 = 0;
    let mut blocker = NO_MOBJ;
    while k != n {
        let idx = *list.at(k);
        k += 1;
        if idx == me {
            continue;
        }
        let other = mobjs.at(idx);
        let oflags = *other.flags;
        if !has(oflags, MF_SOLID + MF_SPECIAL + MF_SHOOTABLE) {
            continue;
        }
        let blockdist = fixed::add(*other.radius, *mo.radius);
        // |other.x - x| >= blockdist  <=>  not (x - bd < other.x < x + bd)
        let ox = *other.x.enc;
        let oy = *other.y.enc;
        if felt_ge(ox, x.enc + blockdist.enc - BIAS) || felt_ge(x.enc - blockdist.enc + BIAS, ox) {
            continue;
        }
        if felt_ge(oy, y.enc + blockdist.enc - BIAS) || felt_ge(y.enc - blockdist.enc + BIAS, oy) {
            continue;
        }
        if missile {
            // Over or under it: no hit.
            if felt_ge(*mo.z.enc, *other.z.enc + *other.height.enc - BIAS + 1) {
                continue;
            }
            if felt_ge(*other.z.enc, *mo.z.enc + *mo.height.enc - BIAS + 1) {
                continue;
            }
            let target = *mo.target;
            if target != NO_MOBJ && *mobjs.at(target).kind == *other.kind {
                if idx == target {
                    continue; // don't hit the shooter
                }
                if *other.kind != KIND_PLAYER {
                    // Explode, but do no damage: monsters do not hurt
                    // their own kind (let players missile other monsters).
                    blocker = idx;
                    break;
                }
            }
            if !has(oflags, MF_SHOOTABLE) {
                if has(oflags, MF_SOLID) {
                    blocker = idx;
                    break;
                }
                continue;
            }
            events.append(MoveEvent::MissileHit(idx));
            blocker = idx;
            break;
        }
        if has(oflags, MF_SPECIAL) {
            if has(tmflags, MF_PICKUP) {
                events.append(MoveEvent::Touch(idx));
            }
            if has(oflags, MF_SOLID) {
                blocker = idx;
                break;
            }
            continue;
        }
        if has(oflags, MF_SOLID) {
            blocker = idx;
            break;
        }
    }
    blocker
}

/// `P_CheckPosition`: can `mo` stand at `(x, y)`, and what is under and
/// above it there.
///
/// Things first, then lines, in Doom's order; within a line, `bbox_reject`
/// first then `P_BoxOnLineSide`, the order S1 §5.7 measured as 346 steps/tic
/// cheaper *and* which is a correctness requirement (the half-plane
/// predicate is about the infinite line). No allocation on the path (R2-A10):
/// the cell lists are read in place, events are appended only when
/// something is touched.
pub fn check_position(
    w: World,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    mo: @Mobj,
    me: u32,
    x: Fixed,
    y: Fixed,
    ref events: Array<MoveEvent>,
) -> Check {
    let p = Point { x, y };
    let grid = w.map.grid;
    let tmbox = box_around(p, *mo.radius);
    let tmflags = *mo.flags;

    // The cell range of the box; the BSP descent for the destination sector
    // is deferred (see below).
    let range = cells_of_box(grid, tmbox);
    let unlocated = Location { cell: NO_CELL, subsector: 0, sector: 0 };
    let mut result = Check {
        ok: true,
        blocker: Blocker::Nothing,
        floorz: fixed::ZERO,
        ceilingz: fixed::ZERO,
        dropoffz: fixed::ZERO,
        loc: unlocated,
        nspec: 0,
        spec0: 0,
        spec1: 0,
        spec2: 0,
        spec3: 0,
    };
    if has(tmflags, MF_NOCLIP) {
        let loc = locate_in(w, grid, range, p);
        result.loc = loc;
        result.floorz = Fixed { enc: *w.floor.at(loc.sector) };
        result.dropoffz = result.floorz;
        result.ceilingz = Fixed { enc: *w.ceil.at(loc.sector) };
        return result;
    }
    let r = match range {
        Option::Some(r) => r,
        Option::None => {
            let loc = locate_in(w, grid, range, p);
            result.loc = loc;
            result.floorz = Fixed { enc: *w.floor.at(loc.sector) };
            result.dropoffz = result.floorz;
            result.ceilingz = Fixed { enc: *w.ceil.at(loc.sector) };
            return result;
        },
    };

    // Things, over the box widened by MAXRADIUS.
    let wide = widen(grid, tmbox, r);
    let wn = range_len(wide);
    let mut k: u32 = 0;
    while k != wn {
        let (cx, cy) = range_cell(wide, k);
        let hit = check_things_in_cell(
            mobjs, ref g, cell_index(grid, cx, cy), mo, me, x, y, ref events,
        );
        if hit != NO_MOBJ {
            result.ok = false;
            result.blocker = Blocker::Thing(hit);
            return result;
        }
        k += 1;
    }

    // Lines, over the box itself. Spans hoisted once (D24). The openings of
    // the straddled lines are folded on their own (min/max are order-free)
    // and combined with the destination sector's heights afterwards.
    let l_ab = w.map.l_ab;
    let l_bb = w.map.l_bb;
    let l_cb = w.map.l_cb;
    let l_box = w.map.l_box;
    let l_packed = w.map.l_packed;
    let bm_start = w.map.bm_start;
    let bm_items = w.map.bm_items;
    let floor = w.floor;
    let ceil = w.ceil;
    let missile = has(tmflags, MF_MISSILE);
    let player = *mo.kind == KIND_PLAYER;
    let mut straddled = false;
    let mut open_top = Fixed { enc: OPEN_HIGH };
    let mut open_bottom = Fixed { enc: OPEN_LOW };
    let mut open_low = Fixed { enc: OPEN_HIGH };
    let n = range_len(r);
    let mut k: u32 = 0;
    while k != n {
        let (cx, cy) = range_cell(r, k);
        k += 1;
        let cell = cell_index(grid, cx, cy);
        let mut j = *bm_start.at(cell);
        let end = *bm_start.at(cell + 1);
        while j != end {
            let line = *bm_items.at(j);
            j += 1;
            if line_box_rejects(*l_box.at(line), tmbox) {
                continue;
            }
            let hp = line_hp(l_ab, l_bb, l_cb, line);
            if box_on_line_side(hp, line_diagonal(hp), tmbox) != SIDE_CROSS {
                continue;
            }
            // A line has been straddled: the cold fields matter now.
            straddled = true;
            let meta = line_meta(*l_packed.at(line));
            if meta.back == NO_SECTOR {
                result.ok = false;
                result.blocker = Blocker::Line(line);
                return result;
            }
            if !missile {
                if has(meta.flags, ML_BLOCKING) {
                    result.ok = false;
                    result.blocker = Blocker::Line(line);
                    return result;
                }
                if !player && has(meta.flags, ML_BLOCKMONSTERS) {
                    result.ok = false;
                    result.blocker = Blocker::Line(line);
                    return result;
                }
            }
            let o = line_opening(floor, ceil, meta.front, meta.back);
            if fixed::lt(o.top, open_top) {
                open_top = o.top;
            }
            if fixed::gt(o.bottom, open_bottom) {
                open_bottom = o.bottom;
            }
            if fixed::lt(o.lowfloor, open_low) {
                open_low = o.lowfloor;
            }
            // A line in two visited cells is seen twice (no `validcount`,
            // S1 §7): the height folds are idempotent, the special list is
            // deduplicated here so that a special never fires twice.
            if meta.special != 0 {
                let seen = (result.nspec > 0 && result.spec0 == line)
                    || (result.nspec > 1 && result.spec1 == line)
                    || (result.nspec > 2 && result.spec2 == line)
                    || (result.nspec > 3 && result.spec3 == line);
                if !seen {
                    if result.nspec == 0 {
                        result.spec0 = line;
                    } else if result.nspec == 1 {
                        result.spec1 = line;
                    } else if result.nspec == 2 {
                        result.spec2 = line;
                    } else if result.nspec == 3 {
                        result.spec3 = line;
                    }
                    result.nspec += 1;
                }
            }
        }
    }

    // Where the target point is. A step shorter than the radius that
    // straddles no line cannot have crossed one, so the sector is the one
    // the thing is already in: the BSP descent (~700-1 500 steps, the most
    // expensive part of a move) is only paid when a line was straddled or
    // the step is long (a missile).
    let short_step = !felt_ge(fixed::magnitude(fixed::sub(x, *mo.x)), *mo.radius.enc - BIAS)
        && !felt_ge(fixed::magnitude(fixed::sub(y, *mo.y)), *mo.radius.enc - BIAS);
    let loc = if !straddled && short_step && *mo.cell != NO_CELL {
        match cell_in_range(grid, r, p) {
            Option::Some(cell) => Location { cell, subsector: *mo.subsector, sector: *mo.sector },
            Option::None => locate_in(w, grid, range, p),
        }
    } else {
        locate_in(w, grid, range, p)
    };
    result.loc = loc;
    let floorz = Fixed { enc: *floor.at(loc.sector) };
    let ceilingz = Fixed { enc: *ceil.at(loc.sector) };
    result.floorz = if fixed::gt(open_bottom, floorz) {
        open_bottom
    } else {
        floorz
    };
    result.ceilingz = if fixed::lt(open_top, ceilingz) {
        open_top
    } else {
        ceilingz
    };
    result.dropoffz = if fixed::lt(open_low, floorz) {
        open_low
    } else {
        floorz
    };
    result
}

/// `R_PointInSubsector` at `p`, starting from `CELL_NODE` when the point
/// is on the grid (its cell is taken from the box's range) and from the root
/// otherwise.
fn locate_in(w: World, grid: Grid, range: Option<CellRange>, p: Point) -> Location {
    let cell = match range {
        Option::Some(r) => cell_in_range(grid, r, p),
        Option::None => Option::None,
    };
    match cell {
        Option::Some(cell) => {
            let subsector = subsector_in_cell(@w.map, cell, p);
            Location { cell, subsector, sector: *w.map.ss_sector.at(subsector) }
        },
        Option::None => {
            let subsector = subsector_from_root(@w.map, p);
            Location { cell: NO_CELL, subsector, sector: *w.map.ss_sector.at(subsector) }
        },
    }
}

/// `P_TryMove`: attempt to move `mo` to `(x, y)`, moving it (and relinking
/// it) on success and reporting the special lines it crossed.
pub fn try_move(
    w: World,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref mo: Mobj,
    me: u32,
    x: Fixed,
    y: Fixed,
    ref events: Array<MoveEvent>,
) -> Verdict {
    let c = check_position(w, mobjs, ref g, @mo, me, x, y, ref events);
    if !c.ok {
        return Verdict { ok: false, floatok: false, blocker: c.blocker };
    }
    let flags = mo.flags;
    if !has(flags, MF_NOCLIP) {
        if fixed::lt(fixed::sub(c.ceilingz, c.floorz), mo.height) {
            return Verdict { ok: false, floatok: false, blocker: Blocker::Fit };
        }
        if !has(flags, MF_TELEPORT) {
            if fixed::lt(fixed::sub(c.ceilingz, mo.z), mo.height) {
                return Verdict { ok: false, floatok: true, blocker: Blocker::Ceiling };
            }
            if fixed::gt(fixed::sub(c.floorz, mo.z), MAXSTEP) {
                return Verdict { ok: false, floatok: true, blocker: Blocker::Step };
            }
        }
        if !has(flags, MF_DROPOFF + MF_FLOAT)
            && fixed::gt(fixed::sub(c.floorz, c.dropoffz), MAXSTEP) {
            return Verdict { ok: false, floatok: true, blocker: Blocker::Dropoff };
        }
    }

    // The move is ok: relink the thing at its new position.
    let oldx = mo.x;
    let oldy = mo.y;
    mo.floorz = c.floorz;
    mo.ceilingz = c.ceilingz;
    mo.x = x;
    mo.y = y;
    place(ref g, ref mo, me, c.loc);

    // Any special lines whose side changed were crossed.
    if c.nspec != 0 && !has(flags, MF_TELEPORT + MF_NOCLIP) {
        let old = Point { x: oldx, y: oldy };
        let new = Point { x, y };
        let rhs_old = hoist(old);
        let rhs_new = hoist(new);
        let mut k: u32 = 0;
        let count = if c.nspec > MAX_SPECIAL_CROSS {
            MAX_SPECIAL_CROSS
        } else {
            c.nspec
        };
        while k != count {
            let line = if k == 0 {
                c.spec0
            } else if k == 1 {
                c.spec1
            } else if k == 2 {
                c.spec2
            } else {
                c.spec3
            };
            k += 1;
            let hp = line_hp(w.map.l_ab, w.map.l_bb, w.map.l_cb, line);
            let side = point_side(hp, new, rhs_new);
            let oldside = point_side(hp, old, rhs_old);
            if side != oldside {
                events.append(MoveEvent::CrossSpecial((line, oldside)));
            }
        }
    }
    Verdict { ok: true, floatok: true, blocker: Blocker::Nothing }
}

// ---------------------------------------------------------------------------
// P_SlideMove
// ---------------------------------------------------------------------------

/// "No blocking line found yet" (`bestslidefrac == FRACUNIT + 1`).
const NO_SLIDE: u32 = 0xFFFF;

/// `PTR_SlideTraverse` over one trace: the nearest blocking line along
/// `p1 -> p2` for a thing of `mo`'s height standing at `mo.z`, folded into
/// `(best, bestline)`.
fn slide_traverse(w: World, mo: @Mobj, p1: Point, p2: Point, ref best: Fixed, ref bestline: u32) {
    let grid = w.map.grid;
    let mut ray = match ray_start(grid, p1, p2) {
        Option::Some(r) => r,
        Option::None => { return; },
    };
    let l_ab = w.map.l_ab;
    let l_bb = w.map.l_bb;
    let l_cb = w.map.l_cb;
    let l_box = w.map.l_box;
    let l_packed = w.map.l_packed;
    let bm_start = w.map.bm_start;
    let bm_items = w.map.bm_items;
    let floor = w.floor;
    let ceil = w.ceil;
    let mox = Point { x: *mo.x, y: *mo.y };
    let rhs_mo = hoist(mox);
    loop {
        let cell = match ray_cell(@ray, grid) {
            Option::Some(c) => c,
            Option::None => { break; },
        };
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
            let meta = line_meta(*l_packed.at(line));
            let blocking = if !has(meta.flags, ML_TWOSIDED) {
                // Don't hit the back side of a one-sided line.
                point_side(hp, mox, rhs_mo) != SIDE_BACK
            } else {
                let o = line_opening(floor, ceil, meta.front, meta.back);
                fixed::lt(fixed::sub(o.top, o.bottom), *mo.height)
                    || fixed::lt(fixed::sub(o.top, *mo.z), *mo.height)
                    || fixed::gt(fixed::sub(o.bottom, *mo.z), MAXSTEP)
            };
            if blocking {
                // Intercepts behind the source or past its end are never
                // traversed (`P_TraverseIntercepts` with `maxfrac = FRACUNIT`).
                let frac = crossing_fraction(@ray, hp, lbox);
                if !fixed::is_neg(frac) && fixed::lt(frac, best) {
                    best = frac;
                    bestline = line;
                }
            }
        }
        ray_advance(ref ray);
    }
}

/// `P_HitSlideLine`: clip `(tmx, tmy)` to slide along `line`.
fn hit_slide_line(w: World, mo: @Mobj, line: u32, ref tmx: Fixed, ref tmy: Fixed) {
    let hp = line_hp(w.map.l_ab, w.map.l_bb, w.map.l_cb, line);
    let (ldx, ldy) = super::maputl::line_delta(hp);
    if ldy.enc == BIAS {
        // ST_HORIZONTAL
        tmy = fixed::ZERO;
        return;
    }
    if ldx.enc == BIAS {
        // ST_VERTICAL
        tmx = fixed::ZERO;
        return;
    }
    let mox = Point { x: *mo.x, y: *mo.y };
    let side = point_side(hp, mox, hoist(mox));
    let mut lineangle = bam::point_to_angle(ldx, ldy);
    if side == SIDE_BACK {
        lineangle = bam::add(lineangle, bam::ANG180);
    }
    let moveangle = bam::point_to_angle(tmx, tmy);
    let mut deltaangle = bam::sub(moveangle, lineangle);
    if deltaangle > bam::ANG180 {
        deltaangle = bam::add(deltaangle, bam::ANG180);
    }
    let movelen = geom2d::approx_distance(tmx, tmy);
    let newlen = fixed::mul(movelen, bam::cosine(deltaangle));
    tmx = fixed::mul(newlen, bam::cosine(lineangle));
    tmy = fixed::mul(newlen, bam::sine(lineangle));
}

/// The `stairstep` fallback of `P_SlideMove`: try the y move alone, then the
/// x move alone.
fn stairstep(
    w: World,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref mo: Mobj,
    me: u32,
    ref events: Array<MoveEvent>,
) {
    let y = fixed::add(mo.y, mo.momy);
    if !try_move(w, mobjs, ref g, ref mo, me, mo.x, y, ref events).ok {
        let x = fixed::add(mo.x, mo.momx);
        try_move(w, mobjs, ref g, ref mo, me, x, mo.y, ref events);
    }
}

/// `P_SlideMove`, vanilla: up to three attempts, each tracing the three
/// leading corners of the thing's box along its momentum to find the nearest
/// blocking line, moving up to it, then clipping the momentum along the line
/// and trying the rest; the `stairstep` fallback (y alone, then x alone)
/// when no line is found.
///
/// **Measured ~4 300 steps** for a player hugging a wall on E1M1 (three
/// traces of one or two cells, two `try_move`s). [`slide_move_lite`] is the
/// documented cheaper fallback.
pub fn slide_move(
    w: World,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref mo: Mobj,
    me: u32,
    ref events: Array<MoveEvent>,
) {
    let mut hitcount: u32 = 0;
    loop {
        hitcount += 1;
        if hitcount == 3 {
            stairstep(w, mobjs, ref g, ref mo, me, ref events);
            break;
        }
        // Trace along the three leading corners.
        let (leadx, trailx) = if !fixed::is_neg(mo.momx) {
            (fixed::add(mo.x, mo.radius), fixed::sub(mo.x, mo.radius))
        } else {
            (fixed::sub(mo.x, mo.radius), fixed::add(mo.x, mo.radius))
        };
        let (leady, traily) = if !fixed::is_neg(mo.momy) {
            (fixed::add(mo.y, mo.radius), fixed::sub(mo.y, mo.radius))
        } else {
            (fixed::sub(mo.y, mo.radius), fixed::add(mo.y, mo.radius))
        };
        let mut best = fixed::FRACUNIT;
        let mut bestline: u32 = NO_SLIDE;
        let momx = mo.momx;
        let momy = mo.momy;
        slide_traverse(
            w,
            @mo,
            Point { x: leadx, y: leady },
            Point { x: fixed::add(leadx, momx), y: fixed::add(leady, momy) },
            ref best,
            ref bestline,
        );
        slide_traverse(
            w,
            @mo,
            Point { x: trailx, y: leady },
            Point { x: fixed::add(trailx, momx), y: fixed::add(leady, momy) },
            ref best,
            ref bestline,
        );
        slide_traverse(
            w,
            @mo,
            Point { x: leadx, y: traily },
            Point { x: fixed::add(leadx, momx), y: fixed::add(traily, momy) },
            ref best,
            ref bestline,
        );
        if bestline == NO_SLIDE {
            stairstep(w, mobjs, ref g, ref mo, me, ref events);
            break;
        }
        // Move up to the wall.
        best = Fixed { enc: best.enc - 0x800 };
        if fixed::gt(best, fixed::ZERO) {
            let newx = fixed::mul(momx, best);
            let newy = fixed::mul(momy, best);
            let x = fixed::add(mo.x, newx);
            let y = fixed::add(mo.y, newy);
            if !try_move(w, mobjs, ref g, ref mo, me, x, y, ref events).ok {
                stairstep(w, mobjs, ref g, ref mo, me, ref events);
                break;
            }
        }
        // Now slide along the wall with the rest of the momentum.
        let mut rest = Fixed { enc: BIAS + FRACUNIT_RAW - (best.enc - BIAS + 0x800) };
        if fixed::gt(rest, fixed::FRACUNIT) {
            rest = fixed::FRACUNIT;
        }
        if !fixed::gt(rest, fixed::ZERO) {
            break;
        }
        let mut tmx = fixed::mul(momx, rest);
        let mut tmy = fixed::mul(momy, rest);
        hit_slide_line(w, @mo, bestline, ref tmx, ref tmy);
        mo.momx = tmx;
        mo.momy = tmy;
        let x = fixed::add(mo.x, tmx);
        let y = fixed::add(mo.y, tmy);
        if try_move(w, mobjs, ref g, ref mo, me, x, y, ref events).ok {
            break;
        }
    }
}

/// The documented cheaper fallback: only `P_SlideMove`'s `stairstep` (the
/// y move alone, then the x move alone), which is what vanilla does when no
/// blocking line is found by the traces. Two `try_move`s, no traversal, no
/// division; a thing sliding along an axis-aligned wall behaves exactly as
/// in vanilla, one along a diagonal wall stops instead of gliding.
pub fn slide_move_lite(
    w: World,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref mo: Mobj,
    me: u32,
    ref events: Array<MoveEvent>,
) {
    stairstep(w, mobjs, ref g, ref mo, me, ref events);
}

// ---------------------------------------------------------------------------
// P_XYMovement / P_ZMovement
// ---------------------------------------------------------------------------

/// What `xy_movement` did beyond moving.
#[derive(Copy, Drop, PartialEq, Debug)]
pub enum XyOutcome {
    /// Moved (or stood still); friction applied as reported.
    Moved,
    /// A missile hit a wall or a thing: the caller explodes it
    /// (`P_ExplodeMissile`, see `spawn::explode_missile`).
    MissileHit: Blocker,
    /// Momentum fell below `STOPSPEED` with no player input: `momx = momy =
    /// 0`, and a player enters its idle state (`S_PLAY`).
    Stopped,
}

/// Clamp a momentum to `[-MAXMOVE, MAXMOVE]`.
fn clamp_move(m: Fixed) -> Fixed {
    if felt_ge(m.enc, BIAS + MAXMOVE + 1) {
        Fixed { enc: BIAS + MAXMOVE }
    } else if felt_ge(BIAS - MAXMOVE - 1, m.enc) {
        Fixed { enc: BIAS - MAXMOVE }
    } else {
        m
    }
}

/// `|m| > MAXMOVE / 2`.
fn big_move(m: Fixed) -> bool {
    felt_ge(fixed::magnitude(m), HALF_MAXMOVE + 1)
}

/// `|m| < STOPSPEED`.
fn below_stopspeed(m: Fixed) -> bool {
    !felt_ge(fixed::magnitude(m), STOPSPEED)
}

/// `P_XYMovement`: apply `momx`/`momy` through `try_move` (in halves when
/// large, as vanilla), slide a player along walls (`slide` picks the
/// vanilla or the lite slide), stop a missile, then apply friction on the
/// floor. `player_input` is Doom's `cmd.forwardmove || cmd.sidemove` test,
/// which keeps a walking player above `STOPSPEED`.
pub fn xy_movement(
    w: World,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref mo: Mobj,
    me: u32,
    player_input: bool,
    vanilla_slide: bool,
    ref events: Array<MoveEvent>,
) -> XyOutcome {
    let flags = mo.flags;
    if mo.momx.enc == BIAS && mo.momy.enc == BIAS {
        if has(flags, MF_SKULLFLY) {
            mo.flags = without(flags, MF_SKULLFLY);
            mo.momz = fixed::ZERO;
        }
        return XyOutcome::Moved;
    }
    let player = mo.kind == KIND_PLAYER;
    mo.momx = clamp_move(mo.momx);
    mo.momy = clamp_move(mo.momy);
    let mut xmove = mo.momx;
    let mut ymove = mo.momy;
    let mut outcome = XyOutcome::Moved;
    // Bounded: each pass halves or consumes the remaining move.
    let mut passes: u32 = 0;
    loop {
        passes += 1;
        let (ptryx, ptryy) = if big_move(xmove) || big_move(ymove) {
            // Halve by splitting sign and magnitude (never `/` on a felt).
            let hx = half_of(xmove);
            let hy = half_of(ymove);
            xmove = fixed::sub(xmove, hx);
            ymove = fixed::sub(ymove, hy);
            (fixed::add(mo.x, hx), fixed::add(mo.y, hy))
        } else {
            let p = (fixed::add(mo.x, xmove), fixed::add(mo.y, ymove));
            xmove = fixed::ZERO;
            ymove = fixed::ZERO;
            p
        };
        let v = try_move(w, mobjs, ref g, ref mo, me, ptryx, ptryy, ref events);
        if !v.ok {
            // Blocked move.
            if player {
                if vanilla_slide {
                    slide_move(w, mobjs, ref g, ref mo, me, ref events);
                } else {
                    slide_move_lite(w, mobjs, ref g, ref mo, me, ref events);
                }
            } else if has(flags, MF_MISSILE) {
                mo.momx = fixed::ZERO;
                mo.momy = fixed::ZERO;
                return XyOutcome::MissileHit(v.blocker);
            } else {
                mo.momx = fixed::ZERO;
                mo.momy = fixed::ZERO;
            }
            outcome = XyOutcome::Moved;
        }
        if (xmove.enc == BIAS && ymove.enc == BIAS) || passes == 4 {
            break;
        }
    }

    // Slow down.
    if has(flags, MF_MISSILE + MF_SKULLFLY) {
        return outcome; // no friction for missiles ever
    }
    if fixed::gt(mo.z, mo.floorz) {
        return outcome; // no friction when airborne
    }
    if has(flags, MF_CORPSE) {
        // Do not stop sliding if halfway off a step with some momentum.
        if !(below_stopspeed(mo.momx) && below_stopspeed(mo.momy)) {
            let sector_floor = Fixed { enc: *w.floor.at(mo.sector) };
            if mo.floorz != sector_floor {
                return outcome;
            }
        }
    }
    if below_stopspeed(mo.momx) && below_stopspeed(mo.momy) && !(player && player_input) {
        mo.momx = fixed::ZERO;
        mo.momy = fixed::ZERO;
        return XyOutcome::Stopped;
    }
    mo.momx = fixed::mul(mo.momx, FRICTION);
    mo.momy = fixed::mul(mo.momy, FRICTION);
    outcome
}

/// `m / 2` on a signed `Fixed` (C's `>> 1` on the raw value: floor).
pub fn half_of(m: Fixed) -> Fixed {
    let (neg, mag) = fixed::split(m);
    let u: u128 = mag.try_into().unwrap();
    if neg {
        // floor(-mag / 2) = -ceil(mag / 2)
        let h: felt252 = ((u + 1) / 2).into();
        Fixed { enc: BIAS - h }
    } else {
        let h: felt252 = (u / 2).into();
        Fixed { enc: BIAS + h }
    }
}

/// What `z_movement` reports.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct ZOutcome {
    /// A missile hit the floor or the ceiling: the caller explodes it.
    pub missile_hit: bool,
    /// A player landed hard (`momz < -GRAVITY * 8`): `deltaviewheight =
    /// momz >> 3` and the "oof" — the value is the landing `momz`.
    pub hard_landing: Fixed,
    /// The thing landed on the floor this tic (`z` clamped up to `floorz`).
    pub landed: bool,
}

/// `P_ZMovement`: gravity, floating toward the target, floor and ceiling
/// clamps. `target` is the mobj `mo.target` points at, for `MF_FLOAT`.
pub fn z_movement(ref mo: Mobj, target: Option<@Mobj>) -> ZOutcome {
    let mut out = ZOutcome { missile_hit: false, hard_landing: fixed::ZERO, landed: false };
    let flags = mo.flags;
    // Adjust height.
    mo.z = fixed::add(mo.z, mo.momz);
    if has(flags, MF_FLOAT) {
        match target {
            Option::Some(t) => {
                if !has(flags, MF_INFLOAT) {
                    let dist = geom2d::approx_distance(
                        fixed::sub(mo.x, *t.x), fixed::sub(mo.y, *t.y),
                    );
                    let delta = fixed::sub(fixed::add(*t.z, half_of(mo.height)), mo.z);
                    let three = Fixed { enc: 3 * delta.enc - 2 * BIAS };
                    if fixed::is_neg(delta) && fixed::lt(dist, fixed::neg(three)) {
                        mo.z = fixed::sub(mo.z, Fixed { enc: BIAS + FLOATSPEED });
                    } else if fixed::gt(delta, fixed::ZERO) && fixed::lt(dist, three) {
                        mo.z = fixed::add(mo.z, Fixed { enc: BIAS + FLOATSPEED });
                    }
                }
            },
            Option::None => {},
        }
    }
    // Clip movement.
    if fixed::le(mo.z, mo.floorz) {
        // Hit the floor.
        if fixed::is_neg(mo.momz) {
            if mo.kind == KIND_PLAYER && fixed::lt(mo.momz, Fixed { enc: BIAS - GRAVITY * 8 }) {
                out.hard_landing = mo.momz;
            }
            mo.momz = fixed::ZERO;
        }
        out.landed = mo.z != mo.floorz;
        mo.z = mo.floorz;
        if has(flags, MF_MISSILE) && !has(flags, MF_NOCLIP) {
            out.missile_hit = true;
            return out;
        }
    } else if !has(flags, MF_NOGRAVITY) {
        if mo.momz.enc == BIAS {
            mo.momz = Fixed { enc: BIAS - GRAVITY * 2 };
        } else {
            mo.momz = Fixed { enc: mo.momz.enc - GRAVITY };
        }
    }
    if fixed::gt(fixed::add(mo.z, mo.height), mo.ceilingz) {
        // Hit the ceiling.
        if fixed::gt(mo.momz, fixed::ZERO) {
            mo.momz = fixed::ZERO;
        }
        mo.z = fixed::sub(mo.ceilingz, mo.height);
        if has(flags, MF_SKULLFLY) {
            mo.momz = fixed::neg(mo.momz);
        }
        if has(flags, MF_MISSILE) && !has(flags, MF_NOCLIP) {
            out.missile_hit = true;
        }
    }
    out
}

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
//!
//! # Shape (S7)
//!
//! Every public function is a thin wrapper that turns its `World` into a
//! five-felt [`Level`] and calls an `_in` twin. The twins pass the moving
//! thing as the eleven fields `P_CheckPosition` reads ([`Mover`]) rather
//! than the 27-felt `Mobj`, keep every loop in its own small function with a
//! narrow return type and no panic site, and return from **one** place:
//! Cairo copies a function's return into every branch that reaches it, at
//! the return's full width each time, and a panic site costs that width
//! again (docs/spikes/S7.md §2). `P_XYMovement`'s passes and
//! `P_SlideMove`'s attempts are unrolled for the same reason.

use blockmap::{CELL_RAW, CellRange, Grid, cells_of_box};
use doom_map::{ML_BLOCKING, ML_BLOCKMONSTERS, ML_TWOSIDED, NO_SECTOR};
use doom_things::tables::KIND_PLAYER;
use fixed::{BIAS, FRACUNIT_RAW, Fixed, felt_ge_narrow, to_u128};
use geom2d::{
    Box as BBox, Point, SIDE_BACK, SIDE_CROSS, box_around, box_on_line_side, hoist, point_side,
};
use super::grid::{ThingGrid, things_in};
use super::maputl::{
    UnitBox, dec, inc, line_box_misses, line_box_rejects, line_diagonal, line_hp, line_meta,
    line_opening, rd, rd32, unit_box,
};
use super::mobj::{
    MF_CORPSE, MF_DROPOFF, MF_FLOAT, MF_INFLOAT, MF_MISSILE, MF_NOCLIP, MF_NOGRAVITY, MF_PICKUP,
    MF_SHOOTABLE, MF_SKULLFLY, MF_SOLID, MF_SPECIAL, MF_TELEPORT, Mobj, NO_CELL, NO_MOBJ, has,
    without,
};
use super::position::{Location, descend, move_cell};
use super::ray::{Trace, crosses, crossing_fraction, ray_advance, ray_cell, ray_start, trace_of};
use super::world::{Level, World, level_of};

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
/// "No blocking line" inside the line fold.
const NO_LINE: u32 = 0xFFFFFFFF;

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

/// The fields of the moving thing `P_CheckPosition` reads: eleven felts
/// where a `Mobj` is 27.
#[derive(Copy, Drop)]
pub struct Mover {
    pub x: Fixed,
    pub y: Fixed,
    pub z: Fixed,
    pub radius: Fixed,
    pub height: Fixed,
    pub flags: u32,
    pub kind: u32,
    pub target: u32,
    pub cell: u32,
    pub subsector: u32,
    pub sector: u32,
}

/// The [`Mover`] of a mobj.
#[inline(always)]
pub fn mover_of(m: @Mobj) -> Mover {
    Mover {
        x: *m.x,
        y: *m.y,
        z: *m.z,
        radius: *m.radius,
        height: *m.height,
        flags: *m.flags,
        kind: *m.kind,
        target: *m.target,
        cell: *m.cell,
        subsector: *m.subsector,
        sector: *m.sector,
    }
}

/// `cy * columns + cx` in the field: `blockmap::cell_index` without its
/// `u32` overflow checks.
#[inline(always)]
fn cell_at(g: Grid, cx: u32, cy: u32) -> u32 {
    let c: felt252 = cy.into() * g.columns.into() + cx.into();
    let r: Option<u32> = c.try_into();
    match r {
        Option::Some(v) => v,
        Option::None => 0,
    }
}

/// The cell of `p`, knowing the (clamped) cell range its box covers: one
/// comparison per axis instead of `blockmap::cell_of`'s two divisions, plus
/// a bounds test when the range touches the grid's edge. `None` when the
/// point itself is off the grid although its box still reaches it.
fn cell_in_range(g: Grid, r: CellRange, p: Point) -> Option<u32> {
    let cx = if r.x1 == r.x0 {
        r.x0
    } else if felt_ge_narrow(p.x.enc, g.origin_x.enc + r.x1.into() * CELL_RAW) {
        r.x1
    } else {
        r.x0
    };
    let cy = if r.y1 == r.y0 {
        r.y0
    } else if felt_ge_narrow(p.y.enc, g.origin_y.enc + r.y1.into() * CELL_RAW) {
        r.y1
    } else {
        r.y0
    };
    let off = (cx == 0 && !felt_ge_narrow(p.x.enc, g.origin_x.enc))
        || (inc(cx) == g.columns
            && felt_ge_narrow(p.x.enc, g.origin_x.enc + g.columns.into() * CELL_RAW))
        || (cy == 0 && !felt_ge_narrow(p.y.enc, g.origin_y.enc))
        || (inc(cy) == g.rows
            && felt_ge_narrow(p.y.enc, g.origin_y.enc + g.rows.into() * CELL_RAW));
    if off {
        Option::None
    } else {
        Option::Some(cell_at(g, cx, cy))
    }
}

/// Widen a cell range by `MAXRADIUS` on every side it can grow into: the
/// thing search box of `P_CheckPosition`, for one comparison per side.
fn widen(g: Grid, b: BBox, r: CellRange) -> CellRange {
    let x0 = if r.x0 != 0
        && !felt_ge_narrow(
            b.left.enc - MAXRADIUS.enc + BIAS, g.origin_x.enc + r.x0.into() * CELL_RAW,
        ) {
        dec(r.x0)
    } else {
        r.x0
    };
    let x1 = if inc(r.x1) != g.columns
        && felt_ge_narrow(
            b.right.enc + MAXRADIUS.enc - BIAS, g.origin_x.enc + inc(r.x1).into() * CELL_RAW,
        ) {
        inc(r.x1)
    } else {
        r.x1
    };
    let y0 = if r.y0 != 0
        && !felt_ge_narrow(
            b.bottom.enc - MAXRADIUS.enc + BIAS, g.origin_y.enc + r.y0.into() * CELL_RAW,
        ) {
        dec(r.y0)
    } else {
        r.y0
    };
    let y1 = if inc(r.y1) != g.rows
        && felt_ge_narrow(
            b.top.enc + MAXRADIUS.enc - BIAS, g.origin_y.enc + inc(r.y1).into() * CELL_RAW,
        ) {
        inc(r.y1)
    } else {
        r.y1
    };
    CellRange { x0, y0, x1, y1 }
}

// ---------------------------------------------------------------------------
// PIT_CheckThing
// ---------------------------------------------------------------------------

/// `PIT_CheckThing` over every thing in `cell`. Returns the blocking thing,
/// or `NO_MOBJ`.
fn check_things_in_cell(
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    cell: u32,
    mo: Mover,
    me: u32,
    x: Fixed,
    y: Fixed,
    ref events: Array<MoveEvent>,
) -> u32 {
    let mut list = things_in(ref g, cell);
    let tmflags = mo.flags;
    let missile = has(tmflags, MF_MISSILE);
    loop {
        let idx = match list.pop_front() {
            Option::Some(i) => *i,
            Option::None => { break NO_MOBJ; },
        };
        if idx == me {
            continue;
        }
        let other = match mobjs.get(idx) {
            Option::Some(b) => b.unbox(),
            Option::None => { continue; },
        };
        let oflags = *other.flags;
        if !has(oflags, MF_SOLID + MF_SPECIAL + MF_SHOOTABLE) {
            continue;
        }
        let blockdist = fixed::add(*other.radius, mo.radius);
        // |other.x - x| >= blockdist  <=>  not (x - bd < other.x < x + bd)
        let ox = *other.x.enc;
        let oy = *other.y.enc;
        if felt_ge_narrow(ox, x.enc + blockdist.enc - BIAS)
            || felt_ge_narrow(x.enc - blockdist.enc + BIAS, ox) {
            continue;
        }
        if felt_ge_narrow(oy, y.enc + blockdist.enc - BIAS)
            || felt_ge_narrow(y.enc - blockdist.enc + BIAS, oy) {
            continue;
        }
        if missile {
            // Over or under it: no hit.
            if felt_ge_narrow(mo.z.enc, *other.z.enc + *other.height.enc - BIAS + 1) {
                continue;
            }
            if felt_ge_narrow(*other.z.enc, mo.z.enc + mo.height.enc - BIAS + 1) {
                continue;
            }
            let target = mo.target;
            if target != NO_MOBJ {
                let target_kind = match mobjs.get(target) {
                    Option::Some(b) => *b.unbox().kind,
                    Option::None => NO_MOBJ,
                };
                if target_kind == *other.kind {
                    if idx == target {
                        continue; // don't hit the shooter
                    }
                    if *other.kind != KIND_PLAYER {
                        // Explode, but do no damage: monsters do not hurt
                        // their own kind (let players missile other monsters).
                        break idx;
                    }
                }
            }
            if !has(oflags, MF_SHOOTABLE) {
                if has(oflags, MF_SOLID) {
                    break idx;
                }
                continue;
            }
            events.append(MoveEvent::MissileHit(idx));
            break idx;
        }
        if has(oflags, MF_SPECIAL) {
            if has(tmflags, MF_PICKUP) {
                events.append(MoveEvent::Touch(idx));
            }
            if has(oflags, MF_SOLID) {
                break idx;
            }
            continue;
        }
        if has(oflags, MF_SOLID) {
            break idx;
        }
    }
}

/// `PIT_CheckThing` over every cell of `wide`, row-major: the blocking
/// thing, or `NO_MOBJ`.
fn things_in_range(
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    grid: Grid,
    wide: CellRange,
    mo: Mover,
    me: u32,
    x: Fixed,
    y: Fixed,
    ref events: Array<MoveEvent>,
) -> u32 {
    // One loop over the range, row-major, two carried counters and no
    // division (a nested loop is two loop functions, each re-pushing the
    // whole live set on entry and exit: measured ~250 steps for one cell).
    let mut cx = wide.x0;
    let mut cy = wide.y0;
    loop {
        if cy > wide.y1 {
            break NO_MOBJ;
        }
        let hit = check_things_in_cell(
            mobjs, ref g, cell_at(grid, cx, cy), mo, me, x, y, ref events,
        );
        if hit != NO_MOBJ {
            break hit;
        }
        if cx == wide.x1 {
            cx = wide.x0;
            cy = inc(cy);
        } else {
            cx = inc(cx);
        }
    }
}

// ---------------------------------------------------------------------------
// PIT_CheckLine
// ---------------------------------------------------------------------------

/// The fold of `PIT_CheckLine` over the straddled lines: the openings
/// (min/max are order-free), the number of straddled lines, the special
/// lines seen, and the blocking line if any.
#[derive(Copy, Drop)]
struct LineFold {
    blocker: u32,
    open_top: Fixed,
    open_bottom: Fixed,
    open_low: Fixed,
    straddled: u32,
    nspec: u32,
    spec0: u32,
    spec1: u32,
    spec2: u32,
    spec3: u32,
}

/// Nothing straddled yet.
fn empty_fold() -> LineFold {
    LineFold {
        blocker: NO_LINE,
        open_top: Fixed { enc: OPEN_HIGH },
        open_bottom: Fixed { enc: OPEN_LOW },
        open_low: Fixed { enc: OPEN_HIGH },
        straddled: 0,
        nspec: 0,
        spec0: 0,
        spec1: 0,
        spec2: 0,
        spec3: 0,
    }
}

/// `PIT_CheckLine` over every line of `cell`. Within a line, the box test
/// first then `P_BoxOnLineSide`, the order S1 §5.7 measured as 346 steps/tic
/// cheaper *and* which is a correctness requirement (the half-plane
/// predicate is about the infinite line).
fn lines_in_cell(
    lv: Level, cell: u32, tmbox: BBox, ub: UnitBox, missile: bool, player: bool, fold: LineFold,
) -> LineFold {
    let bm_start = lv.hot.unbox().bm_start;
    let mut j = rd32(bm_start, cell);
    let end = rd32(bm_start, inc(cell));
    let mut fold = fold;
    loop {
        if j == end {
            break;
        }
        let map = lv.hot.unbox();
        let line = rd32(map.bm_items, j);
        j = inc(j);
        if line_box_rejects(rd(map.l_box, line), ub) {
            continue;
        }
        let hp = line_hp(map.l_ab, map.l_bb, map.l_cb, line);
        if box_on_line_side(hp, line_diagonal(hp), tmbox) != SIDE_CROSS {
            continue;
        }
        // A line has been straddled: the cold fields matter now.
        fold.straddled = inc(fold.straddled);
        let meta = line_meta(rd(map.l_packed, line));
        if meta.back == NO_SECTOR {
            fold.blocker = line;
            break;
        }
        if !missile {
            if has(meta.flags, ML_BLOCKING) {
                fold.blocker = line;
                break;
            }
            if !player && has(meta.flags, ML_BLOCKMONSTERS) {
                fold.blocker = line;
                break;
            }
        }
        let o = line_opening(lv.floor, lv.ceil, meta.front, meta.back);
        if fixed::lt(o.top, fold.open_top) {
            fold.open_top = o.top;
        }
        if fixed::gt(o.bottom, fold.open_bottom) {
            fold.open_bottom = o.bottom;
        }
        if fixed::lt(o.lowfloor, fold.open_low) {
            fold.open_low = o.lowfloor;
        }
        // A line in two visited cells is seen twice (no `validcount`,
        // S1 §7): the height folds are idempotent, the special list is
        // deduplicated here so that a special never fires twice.
        if meta.special != 0 {
            let seen = (fold.nspec > 0 && fold.spec0 == line)
                || (fold.nspec > 1 && fold.spec1 == line)
                || (fold.nspec > 2 && fold.spec2 == line)
                || (fold.nspec > 3 && fold.spec3 == line);
            if !seen {
                if fold.nspec == 0 {
                    fold.spec0 = line;
                } else if fold.nspec == 1 {
                    fold.spec1 = line;
                } else if fold.nspec == 2 {
                    fold.spec2 = line;
                } else if fold.nspec == 3 {
                    fold.spec3 = line;
                }
                fold.nspec = inc(fold.nspec);
            }
        }
    }
    fold
}

/// `PIT_CheckLine` over every cell of `r`, row-major.
fn lines_in_range(
    lv: Level, grid: Grid, r: CellRange, tmbox: BBox, missile: bool, player: bool,
) -> LineFold {
    let ub = unit_box(tmbox);
    let mut fold = empty_fold();
    let mut cx = r.x0;
    let mut cy = r.y0;
    loop {
        if cy > r.y1 {
            break;
        }
        fold = lines_in_cell(lv, cell_at(grid, cx, cy), tmbox, ub, missile, player, fold);
        if fold.blocker != NO_LINE {
            break;
        }
        if cx == r.x1 {
            cx = r.x0;
            cy = inc(cy);
        } else {
            cx = inc(cx);
        }
    }
    fold
}

// ---------------------------------------------------------------------------
// P_CheckPosition
// ---------------------------------------------------------------------------

/// `P_CheckPosition`: can `mo` stand at `(x, y)`, and what is under and
/// above it there.
///
/// Things first, then lines, in Doom's order. No allocation on the path
/// (R2-A10): the cell lists are read in place, events are appended only
/// when something is touched.
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
    check_position_in(level_of(w), mobjs, ref g, mover_of(mo), me, x, y, ref events)
}

/// The things and the lines of `P_CheckPosition`, on a clipping thing whose
/// box covers `r`: the blocker (or `Nothing`) and the line fold.
#[inline(always)]
fn clip_against(
    lv: Level,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    grid: Grid,
    r: CellRange,
    tmbox: BBox,
    mo: Mover,
    me: u32,
    x: Fixed,
    y: Fixed,
    ref events: Array<MoveEvent>,
) -> (Blocker, LineFold) {
    // Things, over the box widened by MAXRADIUS.
    let hit = things_in_range(mobjs, ref g, grid, widen(grid, tmbox, r), mo, me, x, y, ref events);
    if hit != NO_MOBJ {
        return (Blocker::Thing(hit), empty_fold());
    }
    // Lines, over the box itself.
    let fold = lines_in_range(
        lv, grid, r, tmbox, has(mo.flags, MF_MISSILE), mo.kind == KIND_PLAYER,
    );
    if fold.blocker != NO_LINE {
        return (Blocker::Line(fold.blocker), fold);
    }
    (Blocker::Nothing, fold)
}

/// [`check_position`] on the narrow operands.
pub fn check_position_in(
    lv: Level,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    mo: Mover,
    me: u32,
    x: Fixed,
    y: Fixed,
    ref events: Array<MoveEvent>,
) -> Check {
    let p = Point { x, y };
    let grid = lv.hot.unbox().grid;
    let tmbox = box_around(p, mo.radius);
    // The cell range of the box; the BSP descent for the destination sector
    // is deferred (see below).
    let range = cells_of_box(grid, tmbox);
    let clipping = !has(mo.flags, MF_NOCLIP) && range.is_some();
    let (blocker, fold) = match range {
        Option::Some(r) => if clipping {
            clip_against(lv, mobjs, ref g, grid, r, tmbox, mo, me, x, y, ref events)
        } else {
            (Blocker::Nothing, empty_fold())
        },
        Option::None => (Blocker::Nothing, empty_fold()),
    };
    let ok = blocker == Blocker::Nothing;
    // Where the target point is. A step shorter than the radius that
    // straddles no line cannot have crossed one, so the sector is the one
    // the thing is already in: the BSP descent (~700-1 500 steps, the most
    // expensive part of a move) is only paid when a line was straddled or
    // the step is long (a missile). A refused position is not located.
    let short_step = !felt_ge_narrow(fixed::magnitude(fixed::sub(x, mo.x)), mo.radius.enc - BIAS)
        && !felt_ge_narrow(fixed::magnitude(fixed::sub(y, mo.y)), mo.radius.enc - BIAS);
    let cached = clipping && fold.straddled == 0 && short_step && mo.cell != NO_CELL;
    let loc = if !ok {
        Location { cell: NO_CELL, subsector: 0, sector: 0 }
    } else {
        locate_in(lv, grid, range, p, cached, mo.subsector, mo.sector)
    };
    let floorz = Fixed { enc: rd(lv.floor, loc.sector) };
    let ceilingz = Fixed { enc: rd(lv.ceil, loc.sector) };
    Check {
        ok,
        blocker,
        floorz: if ok && fixed::gt(fold.open_bottom, floorz) {
            fold.open_bottom
        } else if ok {
            floorz
        } else {
            fixed::ZERO
        },
        ceilingz: if ok && fixed::lt(fold.open_top, ceilingz) {
            fold.open_top
        } else if ok {
            ceilingz
        } else {
            fixed::ZERO
        },
        dropoffz: if ok && fixed::lt(fold.open_low, floorz) {
            fold.open_low
        } else if ok {
            floorz
        } else {
            fixed::ZERO
        },
        loc,
        nspec: fold.nspec,
        spec0: fold.spec0,
        spec1: fold.spec1,
        spec2: fold.spec2,
        spec3: fold.spec3,
    }
}

/// `R_PointInSubsector` at `p`: from the mover's cached sector when
/// `cached` and its cell can be told from the box's range, else the descent
/// from `CELL_NODE` when the point is on the grid and from the root
/// otherwise.
fn locate_in(
    lv: Level,
    grid: Grid,
    range: Option<CellRange>,
    p: Point,
    cached: bool,
    cached_subsector: u32,
    cached_sector: u32,
) -> Location {
    let cell = match range {
        Option::Some(r) => cell_in_range(grid, r, p),
        Option::None => Option::None,
    };
    let map = lv.hot.unbox();
    match cell {
        Option::Some(cell) => {
            if cached {
                Location { cell, subsector: cached_subsector, sector: cached_sector }
            } else {
                let subsector = descend(lv.hot, rd32(map.cell_node, cell), p);
                Location { cell, subsector, sector: rd32(map.ss_sector, subsector) }
            }
        },
        Option::None => {
            let subsector = descend(lv.hot, map.root, p);
            Location { cell: NO_CELL, subsector, sector: rd32(map.ss_sector, subsector) }
        },
    }
}

// ---------------------------------------------------------------------------
// P_TryMove
// ---------------------------------------------------------------------------

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
    let (b, v) = try_move_in(level_of(w), mobjs, ref g, BoxTrait::new(mo), me, x, y, ref events);
    mo = b.unbox();
    v
}

/// The height rules of `P_TryMove` on a `P_CheckPosition` answer.
#[inline(always)]
fn clip_verdict(c: Check, flags: u32, z: Fixed, height: Fixed) -> Verdict {
    if !c.ok {
        return Verdict { ok: false, floatok: false, blocker: c.blocker };
    }
    if has(flags, MF_NOCLIP) {
        return Verdict { ok: true, floatok: true, blocker: Blocker::Nothing };
    }
    if fixed::lt(fixed::sub(c.ceilingz, c.floorz), height) {
        return Verdict { ok: false, floatok: false, blocker: Blocker::Fit };
    }
    if !has(flags, MF_TELEPORT) {
        if fixed::lt(fixed::sub(c.ceilingz, z), height) {
            return Verdict { ok: false, floatok: true, blocker: Blocker::Ceiling };
        }
        if fixed::gt(fixed::sub(c.floorz, z), MAXSTEP) {
            return Verdict { ok: false, floatok: true, blocker: Blocker::Step };
        }
    }
    if !has(flags, MF_DROPOFF + MF_FLOAT) && fixed::gt(fixed::sub(c.floorz, c.dropoffz), MAXSTEP) {
        return Verdict { ok: false, floatok: true, blocker: Blocker::Dropoff };
    }
    Verdict { ok: true, floatok: true, blocker: Blocker::Nothing }
}

/// [`try_move`] on a [`Level`], with the mobj behind one pointer: the
/// boxed record is read in place and re-boxed only on a successful move
/// (S7: the 27 felts are neither pushed at the call nor stored at the
/// return).
pub fn try_move_in(
    lv: Level,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    mo: Box<Mobj>,
    me: u32,
    x: Fixed,
    y: Fixed,
    ref events: Array<MoveEvent>,
) -> (Box<Mobj>, Verdict) {
    let m = mo.unbox();
    let c = check_position_in(lv, mobjs, ref g, mover_of(@m), me, x, y, ref events);
    let flags = m.flags;
    let v = clip_verdict(c, flags, m.z, m.height);
    if !v.ok {
        return (mo, v);
    }
    // The move is ok: relink the thing at its new position.
    let old = Point { x: m.x, y: m.y };
    move_cell(ref g, me, flags, m.kind, m.cell, c.loc.cell);
    let moved = BoxTrait::new(
        Mobj {
            x,
            y,
            floorz: c.floorz,
            ceilingz: c.ceilingz,
            cell: c.loc.cell,
            subsector: c.loc.subsector,
            sector: c.loc.sector,
            ..m,
        },
    );
    // Any special lines whose side changed were crossed.
    if c.nspec != 0 && !has(flags, MF_TELEPORT + MF_NOCLIP) {
        cross_specials(lv, c, old, Point { x, y }, ref events);
    }
    (moved, v)
}

/// Report every straddled special line whose side changed between `old`
/// and `new` (`P_CrossSpecialLine`'s trigger).
#[inline(never)]
fn cross_specials(lv: Level, c: Check, old: Point, new: Point, ref events: Array<MoveEvent>) {
    let rhs_old = hoist(old);
    let rhs_new = hoist(new);
    if c.nspec > 0 {
        cross_special(lv, c.spec0, old, rhs_old, new, rhs_new, ref events);
    }
    if c.nspec > 1 {
        cross_special(lv, c.spec1, old, rhs_old, new, rhs_new, ref events);
    }
    if c.nspec > 2 {
        cross_special(lv, c.spec2, old, rhs_old, new, rhs_new, ref events);
    }
    if c.nspec > 3 {
        cross_special(lv, c.spec3, old, rhs_old, new, rhs_new, ref events);
    }
}

/// One straddled special: crossed when the side changed.
#[inline(never)]
fn cross_special(
    lv: Level,
    line: u32,
    old: Point,
    rhs_old: felt252,
    new: Point,
    rhs_new: felt252,
    ref events: Array<MoveEvent>,
) {
    let map = lv.hot.unbox();
    let hp = line_hp(map.l_ab, map.l_bb, map.l_cb, line);
    let side = point_side(hp, new, rhs_new);
    let oldside = point_side(hp, old, rhs_old);
    if side != oldside {
        events.append(MoveEvent::CrossSpecial((line, oldside)));
    }
}

// ---------------------------------------------------------------------------
// P_SlideMove
// ---------------------------------------------------------------------------

#[cfg(feature: "vanilla_slide")]
/// "No blocking line found yet" (`bestslidefrac == FRACUNIT + 1`).
const NO_SLIDE: u32 = 0xFFFF;

#[cfg(feature: "vanilla_slide")]
/// The slider's fields `PTR_SlideTraverse` reads.
#[derive(Copy, Drop)]
struct Slider {
    x: Fixed,
    y: Fixed,
    z: Fixed,
    height: Fixed,
}

#[cfg(feature: "vanilla_slide")]
/// `PTR_SlideTraverse` over the lines of one cell: the nearest blocking line
/// so far as `(best, bestline)`.
fn slide_cell(
    lv: Level, tr: Box<Trace>, cell: u32, s: Slider, rhs_mo: felt252, best: Fixed, bestline: u32,
) -> (Fixed, u32) {
    let bm_start = lv.hot.unbox().bm_start;
    let mut j = rd32(bm_start, cell);
    let end = rd32(bm_start, inc(cell));
    let mut best = best;
    let mut bestline = bestline;
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
        let meta = line_meta(rd(map.l_packed, line));
        let blocking = if !has(meta.flags, ML_TWOSIDED) {
            // Don't hit the back side of a one-sided line.
            point_side(hp, Point { x: s.x, y: s.y }, rhs_mo) != SIDE_BACK
        } else {
            let o = line_opening(lv.floor, lv.ceil, meta.front, meta.back);
            fixed::lt(fixed::sub(o.top, o.bottom), s.height)
                || fixed::lt(fixed::sub(o.top, s.z), s.height)
                || fixed::gt(fixed::sub(o.bottom, s.z), MAXSTEP)
        };
        if blocking {
            // Intercepts behind the source or past its end are never
            // traversed (`P_TraverseIntercepts` with `maxfrac = FRACUNIT`).
            let frac = crossing_fraction(tr, hp, lbox);
            if !fixed::is_neg(frac) && fixed::lt(frac, best) {
                best = frac;
                bestline = line;
            }
        }
    }
    (best, bestline)
}

#[cfg(feature: "vanilla_slide")]
/// `PTR_SlideTraverse` over one trace: the nearest blocking line along
/// `p1 -> p2` for a thing of `s.height` standing at `s.z`, folded into
/// `(best, bestline)`.
fn slide_traverse(
    lv: Level, s: Slider, p1: Point, p2: Point, best: Fixed, bestline: u32,
) -> (Fixed, u32) {
    let grid = lv.hot.unbox().grid;
    let mut cur = match ray_start(grid, p1, p2) {
        Option::Some(r) => r,
        Option::None => { return (best, bestline); },
    };
    let tr = trace_of(p1, p2);
    let rhs_mo = hoist(Point { x: s.x, y: s.y });
    let mut best = best;
    let mut bestline = bestline;
    loop {
        let cell = match ray_cell(cur, grid) {
            Option::Some(c) => c,
            Option::None => { break; },
        };
        let (b, l) = slide_cell(lv, tr, cell, s, rhs_mo, best, bestline);
        best = b;
        bestline = l;
        ray_advance(ref cur, grid.columns, grid.rows);
    }
    (best, bestline)
}

#[cfg(feature: "vanilla_slide")]
/// `P_HitSlideLine`: clip `(tmx, tmy)` to slide along `line`.
fn hit_slide_line(lv: Level, mox: Point, line: u32, tmx: Fixed, tmy: Fixed) -> (Fixed, Fixed) {
    let map = lv.hot.unbox();
    let hp = line_hp(map.l_ab, map.l_bb, map.l_cb, line);
    let (ldx, ldy) = super::maputl::line_delta(hp);
    if ldy.enc == BIAS {
        // ST_HORIZONTAL
        return (tmx, fixed::ZERO);
    }
    if ldx.enc == BIAS {
        // ST_VERTICAL
        return (fixed::ZERO, tmy);
    }
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
    (fixed::mul(newlen, bam::cosine(lineangle)), fixed::mul(newlen, bam::sine(lineangle)))
}

/// The `stairstep` fallback of `P_SlideMove`: try the y move alone, then the
/// x move alone.
fn stairstep(
    lv: Level,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    mo: Box<Mobj>,
    me: u32,
    ref events: Array<MoveEvent>,
) -> Box<Mobj> {
    let m = mo.unbox();
    let (mo, v) = try_move_in(lv, mobjs, ref g, mo, me, m.x, fixed::add(m.y, m.momy), ref events);
    if v.ok {
        return mo;
    }
    let (mo, _) = try_move_in(lv, mobjs, ref g, mo, me, fixed::add(m.x, m.momx), m.y, ref events);
    mo
}

#[cfg(feature: "vanilla_slide")]
/// The three traces of one `P_SlideMove` attempt: the nearest blocking line
/// along the leading corners of the box, or `NO_SLIDE`.
fn slide_best(lv: Level, mo: Box<Mobj>) -> (Fixed, u32) {
    let m = mo.unbox();
    let mo = @m;
    let (leadx, trailx) = if !fixed::is_neg(*mo.momx) {
        (fixed::add(*mo.x, *mo.radius), fixed::sub(*mo.x, *mo.radius))
    } else {
        (fixed::sub(*mo.x, *mo.radius), fixed::add(*mo.x, *mo.radius))
    };
    let (leady, traily) = if !fixed::is_neg(*mo.momy) {
        (fixed::add(*mo.y, *mo.radius), fixed::sub(*mo.y, *mo.radius))
    } else {
        (fixed::sub(*mo.y, *mo.radius), fixed::add(*mo.y, *mo.radius))
    };
    let momx = *mo.momx;
    let momy = *mo.momy;
    let s = Slider { x: *mo.x, y: *mo.y, z: *mo.z, height: *mo.height };
    let (best, bestline) = slide_traverse(
        lv,
        s,
        Point { x: leadx, y: leady },
        Point { x: fixed::add(leadx, momx), y: fixed::add(leady, momy) },
        fixed::FRACUNIT,
        NO_SLIDE,
    );
    let (best, bestline) = slide_traverse(
        lv,
        s,
        Point { x: trailx, y: leady },
        Point { x: fixed::add(trailx, momx), y: fixed::add(leady, momy) },
        best,
        bestline,
    );
    slide_traverse(
        lv,
        s,
        Point { x: leadx, y: traily },
        Point { x: fixed::add(leadx, momx), y: fixed::add(traily, momy) },
        best,
        bestline,
    )
}

/// One attempt of `P_SlideMove`: `true` when the slide is over (the
/// stairstep fallback ran, the rest of the momentum was spent, or the slide
/// along the wall went through), `false` when vanilla loops for another
/// attempt.
#[cfg(feature: "vanilla_slide")]
fn slide_attempt(
    lv: Level,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    mo: Box<Mobj>,
    me: u32,
    ref events: Array<MoveEvent>,
) -> (Box<Mobj>, bool) {
    let (best, bestline) = slide_best(lv, mo);
    if bestline == NO_SLIDE {
        return (stairstep(lv, mobjs, ref g, mo, me, ref events), true);
    }
    let m = mo.unbox();
    let momx = m.momx;
    let momy = m.momy;
    // Move up to the wall.
    let best = Fixed { enc: best.enc - 0x800 };
    let mut mo = mo;
    if fixed::gt(best, fixed::ZERO) {
        let x = fixed::add(m.x, fixed::mul(momx, best));
        let y = fixed::add(m.y, fixed::mul(momy, best));
        let (moved, v) = try_move_in(lv, mobjs, ref g, mo, me, x, y, ref events);
        if !v.ok {
            return (stairstep(lv, mobjs, ref g, moved, me, ref events), true);
        }
        mo = moved;
    }
    // Now slide along the wall with the rest of the momentum.
    let mut rest = Fixed { enc: BIAS + FRACUNIT_RAW - (best.enc - BIAS + 0x800) };
    if fixed::gt(rest, fixed::FRACUNIT) {
        rest = fixed::FRACUNIT;
    }
    if !fixed::gt(rest, fixed::ZERO) {
        return (mo, true);
    }
    let m = mo.unbox();
    let (tmx, tmy) = hit_slide_line(
        lv, Point { x: m.x, y: m.y }, bestline, fixed::mul(momx, rest), fixed::mul(momy, rest),
    );
    let mo = BoxTrait::new(Mobj { momx: tmx, momy: tmy, ..m });
    let (mo, v) = try_move_in(
        lv, mobjs, ref g, mo, me, fixed::add(m.x, tmx), fixed::add(m.y, tmy), ref events,
    );
    (mo, v.ok)
}

/// `P_SlideMove`, vanilla: up to three attempts, each tracing the three
/// leading corners of the thing's box along its momentum to find the nearest
/// blocking line, moving up to it, then clipping the momentum along the line
/// and trying the rest; the `stairstep` fallback (y alone, then x alone)
/// when no line is found. [`slide_move_lite`] is the documented cheaper
/// fallback.
pub fn slide_move(
    w: World,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    ref mo: Mobj,
    me: u32,
    ref events: Array<MoveEvent>,
) {
    mo = slide_move_in(level_of(w), mobjs, ref g, BoxTrait::new(mo), me, ref events).unbox();
}

/// [`slide_move`] on a [`Level`]: vanilla's `hitcount` loop, unrolled (two
/// attempts, then the stairstep).
#[cfg(feature: "vanilla_slide")]
pub fn slide_move_in(
    lv: Level,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    mo: Box<Mobj>,
    me: u32,
    ref events: Array<MoveEvent>,
) -> Box<Mobj> {
    let (mo, done) = slide_attempt(lv, mobjs, ref g, mo, me, ref events);
    if done {
        return mo;
    }
    let (mo, done) = slide_attempt(lv, mobjs, ref g, mo, me, ref events);
    if done {
        return mo;
    }
    stairstep(lv, mobjs, ref g, mo, me, ref events)
}

/// Without the `vanilla_slide` feature, [`slide_move`] is the stairstep
/// alone ([`slide_move_lite`]).
#[cfg(not(feature: "vanilla_slide"))]
pub fn slide_move_in(
    lv: Level,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    mo: Box<Mobj>,
    me: u32,
    ref events: Array<MoveEvent>,
) -> Box<Mobj> {
    stairstep(lv, mobjs, ref g, mo, me, ref events)
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
    mo = stairstep(level_of(w), mobjs, ref g, BoxTrait::new(mo), me, ref events).unbox();
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
    if felt_ge_narrow(m.enc, BIAS + MAXMOVE + 1) {
        Fixed { enc: BIAS + MAXMOVE }
    } else if felt_ge_narrow(BIAS - MAXMOVE - 1, m.enc) {
        Fixed { enc: BIAS - MAXMOVE }
    } else {
        m
    }
}

/// `|m| > MAXMOVE / 2`.
fn big_move(m: Fixed) -> bool {
    felt_ge_narrow(fixed::magnitude(m), HALF_MAXMOVE + 1)
}

/// `|m| < STOPSPEED`.
fn below_stopspeed(m: Fixed) -> bool {
    !felt_ge_narrow(fixed::magnitude(m), STOPSPEED)
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
    let (b, out) = xy_movement_in(
        level_of(w), mobjs, ref g, BoxTrait::new(mo), me, player_input, vanilla_slide, ref events,
    );
    mo = b.unbox();
    out
}

/// What is left to move after a pass of `P_XYMovement`.
#[derive(Copy, Drop)]
struct Remaining {
    xmove: Fixed,
    ymove: Fixed,
    /// A missile was blocked: the pass loop ends with `MissileHit`.
    missile_hit: Option<Blocker>,
}

/// One pass of `P_XYMovement`'s loop: the next step (the whole rest, or half
/// of it when large), tried; a blocked player slides, a blocked missile
/// stops, anything else blocked loses its momentum.
fn xy_pass(
    lv: Level,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    mo: Box<Mobj>,
    me: u32,
    player: bool,
    vanilla_slide: bool,
    rem: Remaining,
    ref events: Array<MoveEvent>,
) -> (Box<Mobj>, Remaining) {
    let m = mo.unbox();
    let (ptryx, ptryy, xmove, ymove) = if big_move(rem.xmove) || big_move(rem.ymove) {
        // Halve by splitting sign and magnitude (never `/` on a felt).
        let hx = half_of(rem.xmove);
        let hy = half_of(rem.ymove);
        (
            fixed::add(m.x, hx),
            fixed::add(m.y, hy),
            fixed::sub(rem.xmove, hx),
            fixed::sub(rem.ymove, hy),
        )
    } else {
        (fixed::add(m.x, rem.xmove), fixed::add(m.y, rem.ymove), fixed::ZERO, fixed::ZERO)
    };
    let (mo, v) = try_move_in(lv, mobjs, ref g, mo, me, ptryx, ptryy, ref events);
    if v.ok {
        return (mo, Remaining { xmove, ymove, missile_hit: Option::None });
    }
    if player {
        let mo = if vanilla_slide {
            slide_move_in(lv, mobjs, ref g, mo, me, ref events)
        } else {
            stairstep(lv, mobjs, ref g, mo, me, ref events)
        };
        return (mo, Remaining { xmove, ymove, missile_hit: Option::None });
    }
    let stopped = BoxTrait::new(Mobj { momx: fixed::ZERO, momy: fixed::ZERO, ..mo.unbox() });
    let missile_hit = if has(m.flags, MF_MISSILE) {
        Option::Some(v.blocker)
    } else {
        Option::None
    };
    (stopped, Remaining { xmove, ymove, missile_hit })
}

/// Whether the pass loop goes on: something left to move and no missile
/// stopped.
#[inline(always)]
fn more(rem: Remaining) -> bool {
    !(rem.xmove.enc == BIAS && rem.ymove.enc == BIAS) && rem.missile_hit.is_none()
}

/// [`xy_movement`] on a [`Level`].
pub fn xy_movement_in(
    lv: Level,
    mobjs: Span<Mobj>,
    ref g: ThingGrid,
    mo: Box<Mobj>,
    me: u32,
    player_input: bool,
    vanilla_slide: bool,
    ref events: Array<MoveEvent>,
) -> (Box<Mobj>, XyOutcome) {
    let m = mo.unbox();
    let flags = m.flags;
    if m.momx.enc == BIAS && m.momy.enc == BIAS {
        if has(flags, MF_SKULLFLY) {
            return (
                BoxTrait::new(Mobj { flags: without(flags, MF_SKULLFLY), momz: fixed::ZERO, ..m }),
                XyOutcome::Moved,
            );
        }
        return (mo, XyOutcome::Moved);
    }
    let player = m.kind == KIND_PLAYER;
    let momx = clamp_move(m.momx);
    let momy = clamp_move(m.momy);
    let mo = BoxTrait::new(Mobj { momx, momy, ..m });
    // Vanilla's loop, unrolled: at most four passes, each halving or
    // consuming the remaining move (a clamped move needs at most two).
    let rem = Remaining { xmove: momx, ymove: momy, missile_hit: Option::None };
    let (mut mo, mut rem) = xy_pass(
        lv, mobjs, ref g, mo, me, player, vanilla_slide, rem, ref events,
    );
    if more(rem) {
        let (b, r) = xy_pass(lv, mobjs, ref g, mo, me, player, vanilla_slide, rem, ref events);
        mo = b;
        rem = r;
        if more(rem) {
            let (b, r) = xy_pass(lv, mobjs, ref g, mo, me, player, vanilla_slide, rem, ref events);
            mo = b;
            rem = r;
            if more(rem) {
                let (b, r) = xy_pass(
                    lv, mobjs, ref g, mo, me, player, vanilla_slide, rem, ref events,
                );
                mo = b;
                rem = r;
            }
        }
    }
    if let Option::Some(blocker) = rem.missile_hit {
        return (mo, XyOutcome::MissileHit(blocker));
    }
    // Slow down.
    let m = mo.unbox();
    let (momx, momy, outcome) = friction(
        lv, flags, player && player_input, m.momx, m.momy, m.z, m.floorz, m.sector,
    );
    (BoxTrait::new(Mobj { momx, momy, ..m }), outcome)
}

/// The friction tail of `P_XYMovement`: the new momenta and the outcome.
fn friction(
    lv: Level,
    flags: u32,
    walking: bool,
    momx: Fixed,
    momy: Fixed,
    z: Fixed,
    floorz: Fixed,
    sector: u32,
) -> (Fixed, Fixed, XyOutcome) {
    if has(flags, MF_MISSILE + MF_SKULLFLY) {
        return (momx, momy, XyOutcome::Moved); // no friction for missiles ever
    }
    if fixed::gt(z, floorz) {
        return (momx, momy, XyOutcome::Moved); // no friction when airborne
    }
    let slow = below_stopspeed(momx) && below_stopspeed(momy);
    if has(flags, MF_CORPSE) && !slow {
        // Do not stop sliding if halfway off a step with some momentum.
        let sector_floor = Fixed { enc: rd(lv.floor, sector) };
        if floorz != sector_floor {
            return (momx, momy, XyOutcome::Moved);
        }
    }
    if slow && !walking {
        return (fixed::ZERO, fixed::ZERO, XyOutcome::Stopped);
    }
    (fixed::mul(momx, FRICTION), fixed::mul(momy, FRICTION), XyOutcome::Moved)
}

/// `m / 2` on a signed `Fixed` (C's `>> 1` on the raw value: floor).
#[inline(never)]
pub fn half_of(m: Fixed) -> Fixed {
    let (neg, mag) = fixed::split(m);
    let two: NonZero<u128> = 2;
    let (q, r) = DivRem::div_rem(to_u128(mag), two);
    let half: felt252 = q.into();
    let odd: felt252 = r.into();
    if neg {
        // floor(-mag / 2) = -ceil(mag / 2) = -(mag / 2 + mag % 2)
        Fixed { enc: BIAS - half - odd }
    } else {
        Fixed { enc: BIAS + half }
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

/// `P_ZMovement`'s float toward the target (`MF_FLOAT` without
/// `MF_INFLOAT`): the new `z`.
fn float_toward(t: @Mobj, x: Fixed, y: Fixed, z: Fixed, height: Fixed) -> Fixed {
    let dist = geom2d::approx_distance(fixed::sub(x, *t.x), fixed::sub(y, *t.y));
    let delta = fixed::sub(fixed::add(*t.z, half_of(height)), z);
    let three = Fixed { enc: 3 * delta.enc - 2 * BIAS };
    if fixed::is_neg(delta) && fixed::lt(dist, fixed::neg(three)) {
        fixed::sub(z, Fixed { enc: BIAS + FLOATSPEED })
    } else if fixed::gt(delta, fixed::ZERO) && fixed::lt(dist, three) {
        fixed::add(z, Fixed { enc: BIAS + FLOATSPEED })
    } else {
        z
    }
}

/// `P_ZMovement`: gravity, floating toward the target, floor and ceiling
/// clamps. `target` is the mobj `mo.target` points at, for `MF_FLOAT`.
pub fn z_movement(ref mo: Mobj, target: Option<@Mobj>) -> ZOutcome {
    let flags = mo.flags;
    let missile = has(flags, MF_MISSILE) && !has(flags, MF_NOCLIP);
    // Adjust height.
    let mut z = fixed::add(mo.z, mo.momz);
    let mut momz = mo.momz;
    if has(flags, MF_FLOAT) && !has(flags, MF_INFLOAT) {
        if let Option::Some(t) = target {
            z = float_toward(t, mo.x, mo.y, z, mo.height);
        }
    }
    // Clip movement.
    let mut hard_landing = fixed::ZERO;
    let mut landed = false;
    let mut missile_hit = false;
    let on_floor = fixed::le(z, mo.floorz);
    if on_floor {
        // Hit the floor.
        if fixed::is_neg(momz) {
            if mo.kind == KIND_PLAYER && fixed::lt(momz, Fixed { enc: BIAS - GRAVITY * 8 }) {
                hard_landing = momz;
            }
            momz = fixed::ZERO;
        }
        landed = z != mo.floorz;
        z = mo.floorz;
        missile_hit = missile;
    } else if !has(flags, MF_NOGRAVITY) {
        momz =
            if momz.enc == BIAS {
                Fixed { enc: BIAS - GRAVITY * 2 }
            } else {
                Fixed { enc: momz.enc - GRAVITY }
            };
    }
    // A missile that hit the floor explodes there; vanilla returns before
    // the ceiling test.
    if !missile_hit && fixed::gt(fixed::add(z, mo.height), mo.ceilingz) {
        // Hit the ceiling.
        if fixed::gt(momz, fixed::ZERO) {
            momz = fixed::ZERO;
        }
        z = fixed::sub(mo.ceilingz, mo.height);
        if has(flags, MF_SKULLFLY) {
            momz = fixed::neg(momz);
        }
        missile_hit = missile;
    }
    mo.z = z;
    mo.momz = momz;
    ZOutcome { missile_hit, hard_landing, landed }
}

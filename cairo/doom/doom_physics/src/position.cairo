// SPDX-License-Identifier: GPL-2.0-only
//! Where a thing is: `R_PointInSubsector` through the D22 `CELL_NODE`
//! accelerator, and `P_SetThingPosition` / `P_UnsetThingPosition`
//! (`p_maputl.c`), which keep `Mobj::cell`/`subsector`/`sector` and the
//! thing grid in sync.

use blockmap::cell_of;
use bsp::{Nodes, point_in_subsector_total};
use doom_map::HotMap;
use geom2d::Point;
use super::grid::{ThingGrid, link, relink, unlink};
use super::maputl::{cell_at, rd32};
use super::mobj::{MF_NOBLOCKMAP, Mobj, NO_CELL, has, is_removed};

/// A resolved position: blockmap cell (or [`NO_CELL`]), BSP subsector and
/// its sector.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct Location {
    pub cell: u32,
    pub subsector: u32,
    pub sector: u32,
}

/// The level's BSP as `bsp::Nodes` (bboxes deliberately empty, as
/// `doom_map::nodes` documents).
#[inline(always)]
pub fn nodes_of(map: @HotMap) -> Nodes {
    Nodes {
        ab: *map.n_ab,
        bb: *map.n_bb,
        cb: *map.n_cb,
        child0: *map.n_child0,
        child1: *map.n_child1,
        bbox: array![].span(),
    }
}

/// `R_PointInSubsector` for a point known to be in blockmap `cell`: the
/// descent starts at `CELL_NODE[cell]` (D22, 4.15 levels on average instead
/// of 11.36 on E1M1).
pub fn subsector_in_cell(map: @HotMap, cell: u32, p: Point) -> u32 {
    let nodes = nodes_of(map);
    point_in_subsector_total(@nodes, rd32(*map.cell_node, cell), p)
}

/// `R_PointInSubsector` from the root, for a point off the blockmap (the
/// void around the level; a descent still names a leaf there).
pub fn subsector_from_root(map: @HotMap, p: Point) -> u32 {
    let nodes = nodes_of(map);
    point_in_subsector_total(@nodes, *map.root, p)
}

/// Resolve `p`: its cell (one `blockmap::cell_of`), then the accelerated
/// descent. **Measured ~700 steps** on E1M1 — the single most expensive
/// step of a move, which is why `try_move` computes it once and hands the
/// result to [`place`] instead of locating twice as Doom does.
pub fn locate(map: @HotMap, p: Point) -> Location {
    let (cell, subsector) = match cell_of(*map.grid, p) {
        Option::Some((
            cx, cy,
        )) => {
            let cell = cell_at(*map.grid, cx, cy);
            (cell, subsector_in_cell(map, cell, p))
        },
        Option::None => (NO_CELL, subsector_from_root(map, p)),
    };
    Location { cell, subsector, sector: rd32(*map.ss_sector, subsector) }
}

/// [`locate`] on the boxed map: what the crate's own callers use (the
/// snapshot form above copies the ~30 felts of the `HotMap` per call).
pub fn locate_boxed(hot: Box<HotMap>, p: Point) -> Location {
    let map = hot.unbox();
    let grid = map.grid;
    let (cell, node) = match cell_of(grid, p) {
        Option::Some((
            cx, cy,
        )) => {
            let cell = cell_at(grid, cx, cy);
            (cell, rd32(map.cell_node, cell))
        },
        Option::None => (NO_CELL, map.root),
    };
    let subsector = descend(hot, node, p);
    Location { cell, subsector, sector: rd32(map.ss_sector, subsector) }
}

/// The BSP descent from `node` on the boxed map.
pub fn descend(hot: Box<HotMap>, node: u32, p: Point) -> u32 {
    let map = hot.unbox();
    let nodes = Nodes {
        ab: map.n_ab,
        bb: map.n_bb,
        cb: map.n_cb,
        child0: map.n_child0,
        child1: map.n_child1,
        bbox: array![].span(),
    };
    point_in_subsector_total(@nodes, node, p)
}

/// The blockmap half of `P_UnsetThingPosition`: unlink `me` from its cell.
/// The mobj keeps its coordinates and its `cell` (Doom keeps `bnext`
/// dangling until the next `P_SetThingPosition`).
pub fn unset_thing_position(ref g: ThingGrid, m: @Mobj, me: u32) {
    if !has(*m.flags, MF_NOBLOCKMAP) && *m.cell != NO_CELL && !is_removed(m) {
        unlink(ref g, *m.cell, me);
    }
}

/// The blockmap half of `P_SetThingPosition`: link `me` into its cell.
pub fn link_thing(ref g: ThingGrid, m: @Mobj, me: u32) {
    if !has(*m.flags, MF_NOBLOCKMAP) && *m.cell != NO_CELL && !is_removed(m) {
        link(ref g, *m.cell, me);
    }
}

/// Whether a thing with these `flags`/`kind` is kept in the grid at `cell`
/// (`in_blockmap` on the fields alone).
#[inline(always)]
pub fn linkable(flags: u32, kind: u32, cell: u32) -> bool {
    !has(flags, MF_NOBLOCKMAP) && cell != NO_CELL && kind != super::mobj::KIND_NONE
}

/// Move `me` (a thing with `flags`/`kind`) from `old_cell` to `new_cell` in
/// the grid, when they differ: `try_move`'s relink on the fields it already
/// holds.
#[inline(never)]
pub fn move_cell(ref g: ThingGrid, me: u32, flags: u32, kind: u32, old_cell: u32, new_cell: u32) {
    if new_cell != old_cell {
        if linkable(flags, kind, old_cell) {
            unlink(ref g, old_cell, me);
        }
        if linkable(flags, kind, new_cell) {
            link(ref g, new_cell, me);
        }
    }
}

/// Move a **linked** `mo` to `loc` (its coordinates already updated by the
/// caller): the sector links are the three fields, the blockmap link is
/// rewritten only if the cell changed — a thing that stays in its cell costs
/// nothing here (R2-A11). `try_move`'s path; a thing that is not yet in the
/// grid goes through [`set_thing_position`].
pub fn place(ref g: ThingGrid, ref mo: Mobj, me: u32, loc: Location) {
    move_cell(ref g, me, mo.flags, mo.kind, mo.cell, loc.cell);
    mo.cell = loc.cell;
    mo.subsector = loc.subsector;
    mo.sector = loc.sector;
}

/// `P_SetThingPosition` in full: locate `mo`'s current coordinates and link
/// it, unlinking it first from wherever its `cell` says it was (a no-op on a
/// grid it is not in). Used by spawning, teleporting and any thing that is
/// not yet in the grid; `try_move` uses the location it already computed.
///
/// A thing that stays in its cell is moved to the end of the cell's list in
/// one rewrite (or none, when it already is last), which is what the
/// unlink + link pair would do (S7).
pub fn set_thing_position(map: @HotMap, ref g: ThingGrid, ref mo: Mobj, me: u32) {
    let loc = locate(map, Point { x: mo.x, y: mo.y });
    let flags = mo.flags;
    let kind = mo.kind;
    let old_cell = mo.cell;
    if loc.cell == old_cell {
        if linkable(flags, kind, old_cell) {
            relink(ref g, old_cell, me);
        }
    } else {
        if linkable(flags, kind, old_cell) {
            unlink(ref g, old_cell, me);
        }
        if linkable(flags, kind, loc.cell) {
            link(ref g, loc.cell, me);
        }
    }
    mo.cell = loc.cell;
    mo.subsector = loc.subsector;
    mo.sector = loc.sector;
}

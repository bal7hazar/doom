// SPDX-License-Identifier: GPL-2.0-only
//! Edge cases and branch coverage on a level built here, with no data from
//! `doom_map`: a strip of six sectors (128 units wide each, 256 deep) with
//! every height rule of `P_TryMove` between two of them, a
//! `ML_BLOCKMONSTERS` special line, an `ML_BLOCKING` line, a diagonal wall,
//! a closed door and a REJECTed pair. `bench/coverage.py` runs exactly this
//! module (the real level does not compile under `inlining-strategy =
//! "avoid"`).
//!
//! ```text
//!   y=256 +----+----+----+----+----+----+
//!         | S0 | S1 | S2 | S3 | S4 | S5 |   floors  0  16  40  72  72  72
//!         |  | |  | |    |    |    |    |   ceils 128 128 128 128  80  72
//!   y=0   +----+----+----+----+----+----+
//!        x=0  128  256  384  512  640  768
//!   line 9 at x=64 (two-sided, ML_BLOCKMONSTERS, special 97)
//!   line 10 at x=192 (two-sided, ML_BLOCKING)
//!   line 11 the diagonal (0,192)-(64,256), one-sided
//! ```

use blockmap::Grid;
use bsp::SUBSECTOR_FLAG;
use doom_map::{HotMap, ML_BLOCKING, ML_BLOCKMONSTERS, ML_TWOSIDED, NO_SECTOR};
use doom_things::tables::{KIND_CLIP, KIND_PLAYER, KIND_POSSESSED, KIND_TROOP, KIND_TROOPSHOT};
use doom_things::{rndtable, states, thing_info};
use fixed::{BIAS, Fixed};
use geom2d::{Box, Point, box_of_segment, diagonal, half_plane};
use prng::from_index;
use crate::damage::{damage_mobj, kill_mobj};
use crate::grid::{link, new_grid, rebuild, things_in, unlink};
use crate::hitscan::{Hit, aim_line_attack, bleeds, line_attack, path_traverse};
use crate::maputl::{line_meta, line_opening};
use crate::mobj::{
    MF_CORPSE, MF_FLOAT, MF_INFLOAT, MF_MISSILE, MF_NOBLOCKMAP, MF_NOCLIP, MF_NOGRAVITY,
    MF_SHOOTABLE, MF_SOLID, MF_SPECIAL, MF_TELEPORT, Mobj, NO_CELL, NO_MOBJ, first_free, has,
    in_blockmap, is_removed, push, removed_mobj, replace, without,
};
use crate::movement::{
    Blocker, MoveEvent, XyOutcome, check_position, slide_move, slide_move_lite, try_move,
    xy_movement, z_movement,
};
use crate::position::{
    link_thing, locate, set_thing_position, subsector_from_root, unset_thing_position,
};
use crate::sight::{check_sight, check_sight_cached};
use crate::spawn::{
    FIREBALL, MTF_AMBUSH, SpawnZ, explode_missile, set_state, spawn_cell, spawn_map_thing,
    spawn_missile, spawn_mobj, spawn_player,
};
use crate::world::{World, ceiling_of, floor_of, with_heights};

// ---------------------------------------------------------------------------
// The fixture
// ---------------------------------------------------------------------------

/// Every array of the strip level (owned here so that the spans live).
#[derive(Drop)]
struct Strip {
    l_ab: Array<felt252>,
    l_bb: Array<felt252>,
    l_cb: Array<felt252>,
    l_box: Array<felt252>,
    l_packed: Array<felt252>,
    n_ab: Array<felt252>,
    n_bb: Array<felt252>,
    n_cb: Array<felt252>,
    n_child0: Array<u32>,
    n_child1: Array<u32>,
    ss_sector: Array<u32>,
    cell_node: Array<u32>,
    bm_start: Array<u32>,
    bm_items: Array<u32>,
    reject: Array<felt252>,
    pow2: Array<felt252>,
    floor: Array<felt252>,
    ceil: Array<felt252>,
}

fn units(u: felt252) -> Fixed {
    fixed::from_units(u)
}

fn pt(x: felt252, y: felt252) -> Point {
    Point { x: units(x), y: units(y) }
}

fn pack_box(b: Box) -> felt252 {
    let l = fixed::to_units(b.left) + 32768;
    let bo = fixed::to_units(b.bottom) + 32768;
    let r = fixed::to_units(b.right) + 32768;
    let t = fixed::to_units(b.top) + 32768;
    l + bo * 0x10000 + r * 0x100000000 + t * 0x1000000000000
}

/// Inclusive box overlap (touching counts).
fn overlaps(a: Box, b: Box) -> bool {
    fixed::le(b.left, a.right)
        && fixed::le(a.left, b.right)
        && fixed::le(b.bottom, a.top)
        && fixed::le(a.bottom, b.top)
}

fn pack_line(flags: u32, special: u32, diag: u8, front: u32, back: u32) -> felt252 {
    let f: felt252 = flags.into();
    let s: felt252 = special.into();
    let d: felt252 = diag.into();
    let fr: felt252 = front.into();
    let bk: felt252 = back.into();
    f + s * 0x10000 + d * 0x10000000000 + fr * 0x20000000000 + bk * 0x10000000000000
}

const GRID: Grid = Grid {
    origin_x: Fixed { enc: BIAS - 128 * 65536 },
    origin_y: Fixed { enc: BIAS - 128 * 65536 },
    columns: 8,
    rows: 4,
};

fn strip() -> Strip {
    // (v1, v2, flags, special, front, back)
    let lines: Array<(Point, Point, u32, u32, u32, u32)> = array![
        (pt(768, 0), pt(0, 0), 0, 0, 0, NO_SECTOR), // 0 bottom wall
        (pt(0, 256), pt(768, 256), 0, 0, 0, NO_SECTOR), // 1 top wall
        (pt(0, 0), pt(0, 256), 0, 0, 0, NO_SECTOR), // 2 left wall
        (pt(768, 256), pt(768, 0), 0, 0, 5, NO_SECTOR), // 3 right wall
        (pt(128, 0), pt(128, 256), ML_TWOSIDED, 0, 1, 0), // 4 S0|S1: step 16
        (pt(256, 0), pt(256, 256), ML_TWOSIDED, 0, 2, 1), // 5 S1|S2: step 24
        (pt(384, 0), pt(384, 256), ML_TWOSIDED, 0, 3, 2), // 6 S2|S3: step 32
        (pt(512, 0), pt(512, 256), ML_TWOSIDED, 0, 4, 3), // 7 S3|S4: low ceiling
        (pt(640, 0), pt(640, 256), ML_TWOSIDED, 0, 5, 4), // 8 S4|S5: closed
        (pt(64, 0), pt(64, 256), ML_TWOSIDED + ML_BLOCKMONSTERS, 97, 0, 0), // 9
        (pt(192, 0), pt(192, 256), ML_TWOSIDED + ML_BLOCKING, 0, 1, 1), // 10
        (pt(0, 192), pt(64, 256), 0, 0, 0, NO_SECTOR) // 11 diagonal corner
    ];
    let mut l_ab = array![];
    let mut l_bb = array![];
    let mut l_cb = array![];
    let mut l_box = array![];
    let mut l_packed = array![];
    let mut boxes: Array<Box> = array![];
    let mut i: u32 = 0;
    while i != lines.len() {
        let (v1, v2, flags, special, front, back) = *lines.at(i);
        let hp = half_plane(v1, v2);
        l_ab.append(hp.ab);
        l_bb.append(hp.bb);
        l_cb.append(hp.cb);
        let b = box_of_segment(v1, v2);
        boxes.append(b);
        l_box.append(pack_box(b));
        l_packed.append(pack_line(flags, special, diagonal(v1, v2), front, back));
        i += 1;
    }
    // BSP: node k splits at x = 128 (k + 1); front (east) = node k + 1 or
    // subsector 5, back (west) = subsector k. Root is node 0.
    let mut n_ab = array![];
    let mut n_bb = array![];
    let mut n_cb = array![];
    let mut n_child0 = array![];
    let mut n_child1 = array![];
    let mut k: u32 = 0;
    while k != 5 {
        let x: felt252 = (128 * (k + 1)).into();
        let hp = half_plane(pt(x, 0), pt(x, 256));
        n_ab.append(hp.ab);
        n_bb.append(hp.bb);
        n_cb.append(hp.cb);
        n_child0.append(if k == 4 {
            SUBSECTOR_FLAG + 5
        } else {
            k + 1
        });
        n_child1.append(SUBSECTOR_FLAG + k);
        k += 1;
    }
    // Blockmap: a line is in every cell its box overlaps or touches (a
    // superset of Doom's, harmless: `bbox_reject` drops the extras again;
    // the walls lie exactly on cell boundaries, so touching must count).
    let mut bm_start = array![0_u32];
    let mut bm_items = array![];
    let mut cell_node = array![];
    let mut cy: u32 = 0;
    while cy != GRID.rows {
        let mut cx: u32 = 0;
        while cx != GRID.columns {
            let x0: felt252 = -128 + (cx * 128).into();
            let y0: felt252 = -128 + (cy * 128).into();
            let cell_box = Box {
                left: units(x0), bottom: units(y0), right: units(x0 + 128), top: units(y0 + 128),
            };
            let mut j: u32 = 0;
            while j != boxes.len() {
                if overlaps(cell_box, *boxes.at(j)) {
                    bm_items.append(j);
                }
                j += 1;
            }
            bm_start.append(bm_items.len());
            cell_node.append(0);
            cx += 1;
        }
        cy += 1;
    }
    let mut pow2 = array![];
    let mut p: felt252 = 1;
    let mut e: u32 = 0;
    while e != 64 {
        pow2.append(p);
        p *= 2;
        e += 1;
    }
    Strip {
        l_ab,
        l_bb,
        l_cb,
        l_box,
        l_packed,
        n_ab,
        n_bb,
        n_cb,
        n_child0,
        n_child1,
        ss_sector: array![0, 1, 2, 3, 4, 5],
        cell_node,
        bm_start,
        bm_items,
        // S0 and S5 cannot see each other.
        reject: array![32, 0, 0, 0, 0, 1],
        pow2,
        floor: array![
            units(0).enc, units(16).enc, units(40).enc, units(72).enc, units(72).enc, units(72).enc,
        ],
        ceil: array![
            units(128).enc, units(128).enc, units(128).enc, units(128).enc, units(80).enc,
            units(72).enc,
        ],
    }
}

fn world(s: @Strip) -> World {
    World {
        map: HotMap {
            l_ab: s.l_ab.span(),
            l_bb: s.l_bb.span(),
            l_cb: s.l_cb.span(),
            l_box: s.l_box.span(),
            l_packed: s.l_packed.span(),
            n_ab: s.n_ab.span(),
            n_bb: s.n_bb.span(),
            n_cb: s.n_cb.span(),
            n_child0: s.n_child0.span(),
            n_child1: s.n_child1.span(),
            root: 0,
            ss_sector: s.ss_sector.span(),
            cell_node: s.cell_node.span(),
            grid: GRID,
            bm_start: s.bm_start.span(),
            bm_items: s.bm_items.span(),
            reject: s.reject.span(),
            reject_stride: 1,
            pow2: s.pow2.span(),
        },
        floor: s.floor.span(),
        ceil: s.ceil.span(),
        states: states(),
        rndtable: rndtable(),
    }
}

/// A player standing on the floor at `(x, y)`.
fn player(w: World, x: felt252, y: felt252) -> Mobj {
    spawn_mobj(w, KIND_PLAYER, units(x), units(y), SpawnZ::OnFloor)
}

/// A zombieman standing on the floor at `(x, y)`.
fn monster(w: World, x: felt252, y: felt252) -> Mobj {
    spawn_mobj(w, KIND_POSSESSED, units(x), units(y), SpawnZ::OnFloor)
}

fn attempt(w: World, ref mo: Mobj, x: felt252, y: felt252) -> Blocker {
    let mut g = new_grid();
    let mobjs = array![mo].span();
    let mut events: Array<MoveEvent> = array![];
    try_move(w, mobjs, ref g, ref mo, 0, units(x), units(y), ref events).blocker
}

// ---------------------------------------------------------------------------
// P_TryMove's rules, one by one
// ---------------------------------------------------------------------------

#[test]
fn test_height_rules() {
    let s = strip();
    let w = world(@s);
    // S0 -> S1: a 16-unit step up.
    let mut p = player(w, 100, 128);
    assert(attempt(w, ref p, 150, 128) == Blocker::Nothing, 'step 16');
    assert(p.sector == 1 && p.floorz == units(16), 'now in S1 on its floor');
    // S1 -> S2: exactly 24 units, allowed.
    let mut p = player(w, 230, 128);
    assert(attempt(w, ref p, 280, 128) == Blocker::Nothing, 'step exactly 24');
    // S2 -> S3: 32 units, too high.
    let mut p = player(w, 350, 128);
    assert(attempt(w, ref p, 400, 128) == Blocker::Step, 'step 32');
    assert(p.x == units(350), 'did not move');
    // S3 -> S2: a 32-unit ledge (straddled by the box), fine for a player,
    // refused by a monster.
    let mut p = player(w, 420, 128);
    assert(attempt(w, ref p, 396, 128) == Blocker::Nothing, 'player at the ledge');
    let mut m = monster(w, 420, 128);
    assert(attempt(w, ref m, 396, 128) == Blocker::Dropoff, 'monster refuses the ledge');
    // S3 -> S4: 8 units between floor and ceiling.
    let mut p = player(w, 480, 128);
    assert(attempt(w, ref p, 520, 128) == Blocker::Fit, 'does not fit');
    // S4 -> S5: a closed door, zero opening.
    let mut p = player(w, 600, 128);
    p.z = units(72);
    assert(attempt(w, ref p, 650, 128) == Blocker::Fit, 'closed door');
    // Must lower itself: a thing hovering near the ceiling of S0.
    let mut p = player(w, 100, 128);
    p.z = units(80);
    let mut g = new_grid();
    let mut events: Array<MoveEvent> = array![];
    let v = try_move(w, array![p].span(), ref g, ref p, 0, units(110), units(128), ref events);
    assert(v.blocker == Blocker::Ceiling && v.floatok, 'ceiling, but floatok');
    // A teleporting thing skips the step and ceiling rules.
    let mut p = player(w, 350, 128);
    p.flags = p.flags | MF_TELEPORT;
    assert(attempt(w, ref p, 400, 128) == Blocker::Nothing, 'teleport ignores the step');
    // A floater ignores the ledge.
    let mut m = monster(w, 420, 128);
    m.flags = m.flags | MF_FLOAT;
    assert(attempt(w, ref m, 396, 128) == Blocker::Nothing, 'floater over the ledge');
}

#[test]
fn test_lines_block_by_kind() {
    let s = strip();
    let w = world(@s);
    // Into the left wall.
    let mut p = player(w, 40, 128);
    assert(attempt(w, ref p, 10, 128) == Blocker::Line(2), 'one-sided wall');
    // Touching the wall exactly is allowed (box edges coincide).
    let mut p = player(w, 40, 128);
    assert(attempt(w, ref p, 16, 128) == Blocker::Nothing, 'touching is fine');
    // ML_BLOCKING stops everyone, ML_BLOCKMONSTERS only monsters.
    let mut p = player(w, 150, 128);
    assert(attempt(w, ref p, 200, 128) == Blocker::Line(10), 'blocking line');
    let mut m = monster(w, 30, 128);
    assert(attempt(w, ref m, 70, 128) == Blocker::Line(9), 'blockmonsters line');
    let mut p = player(w, 30, 128);
    let mut g = new_grid();
    let mut events: Array<MoveEvent> = array![];
    let v = try_move(w, array![p].span(), ref g, ref p, 0, units(70), units(128), ref events);
    assert(v.ok, 'player crosses it');
    assert(events.len() == 1, 'and triggers its special');
    assert(*events.at(0) == MoveEvent::CrossSpecial((9, geom2d::SIDE_BACK)), 'from the west side');
    // Straddling without crossing triggers nothing.
    let mut p = player(w, 30, 128);
    let mut events: Array<MoveEvent> = array![];
    let v = try_move(w, array![p].span(), ref g, ref p, 0, units(55), units(128), ref events);
    assert(v.ok && events.len() == 0, 'straddled, not crossed');
    // A missile ignores ML_BLOCKING and ML_BLOCKMONSTERS but not walls.
    let mut ball = spawn_mobj(w, KIND_TROOPSHOT, units(150), units(128), SpawnZ::At(units(40)));
    assert(attempt(w, ref ball, 195, 128) == Blocker::Nothing, 'missile through blocking');
    let mut ball = spawn_mobj(w, KIND_TROOPSHOT, units(40), units(128), SpawnZ::At(units(40)));
    assert(attempt(w, ref ball, 2, 128) == Blocker::Line(2), 'missile into the wall');
    // The diagonal corner wall, and NOCLIP through everything.
    let mut p = player(w, 40, 200);
    assert(attempt(w, ref p, 20, 235) == Blocker::Line(11), 'diagonal wall');
    p.flags = p.flags | MF_NOCLIP;
    assert(attempt(w, ref p, 20, 235) == Blocker::Nothing, 'noclip');
    assert(attempt(w, ref p, -300, -300) == Blocker::Nothing, 'noclip off the grid');
}

#[test]
fn test_corners_and_the_void() {
    let s = strip();
    let w = world(@s);
    // A box corner exactly on a wall's end (the corner of the map).
    let mut p = player(w, 40, 40);
    assert(attempt(w, ref p, 16, 16) == Blocker::Nothing, 'corner touch');
    assert(attempt(w, ref p, 15, 16) == Blocker::Line(2), 'one unit into the left wall');
    let mut p = player(w, 40, 40);
    assert(attempt(w, ref p, 16, 15) == Blocker::Line(0), 'one unit into the bottom wall');
    // Off the grid: no lines, no cell, a root descent for the sector.
    let far = pt(-500, -500);
    let loc = locate(@w.map, far);
    assert(loc.cell == NO_CELL, 'off-grid cell');
    assert(loc.subsector == subsector_from_root(@w.map, far), 'root descent');
    let mut p = player(w, -500, -500);
    assert(p.cell == NO_CELL, 'spawned off the grid');
    assert(attempt(w, ref p, -480, -500) == Blocker::Nothing, 'nothing to hit there');
    // A straddled special is remembered once even when the box spans two
    // cells that both list the line (no `validcount`).
    let mut g = new_grid();
    let p = player(w, 40, 128);
    let mut events: Array<MoveEvent> = array![];
    let c = check_position(w, array![p].span(), ref g, @p, 0, units(60), units(128), ref events);
    assert(c.nspec == 1 && c.spec0 == 9, 'one special straddled');
}

// ---------------------------------------------------------------------------
// Things
// ---------------------------------------------------------------------------

#[test]
fn test_thing_grid() {
    let mut g = new_grid();
    assert(things_in(ref g, 3).len() == 0, 'empty');
    link(ref g, 3, 7);
    link(ref g, 3, 9);
    let l = things_in(ref g, 3);
    assert(l.len() == 2 && *l.at(0) == 7 && *l.at(1) == 9, 'linked in order');
    unlink(ref g, 3, 7);
    let l = things_in(ref g, 3);
    assert(l.len() == 1 && *l.at(0) == 9, 'unlinked');
    unlink(ref g, 3, 42);
    assert(things_in(ref g, 3).len() == 1, 'unlinking a stranger is a no-op');

    let s = strip();
    let w = world(@s);
    let mut a = player(w, 100, 128);
    a.cell = 11;
    let mut b = monster(w, 100, 128);
    b.cell = 11;
    let mut c = monster(w, 100, 128);
    c.cell = 12;
    c.flags = c.flags | MF_NOBLOCKMAP;
    let mut g2 = rebuild(array![a, b, c, removed_mobj()].span());
    assert(things_in(ref g2, 11).len() == 2, 'two in cell 11');
    assert(things_in(ref g2, 12).len() == 0, 'noblockmap not linked');
    assert(!in_blockmap(@c) && in_blockmap(@a), 'in_blockmap');
    // set/unset position.
    let mut p = player(w, 100, 128);
    let mut g3 = new_grid();
    set_thing_position(@w.map, ref g3, ref p, 4);
    assert(p.cell != NO_CELL && things_in(ref g3, p.cell).len() == 1, 'set links');
    assert(spawn_cell(w, @p) == p.cell, 'spawn_cell');
    unset_thing_position(ref g3, @p, 4);
    assert(things_in(ref g3, p.cell).len() == 0, 'unset unlinks');
    link_thing(ref g3, @p, 4);
    assert(things_in(ref g3, p.cell).len() == 1, 'link_thing');
    // Moving within the cell keeps the link; crossing a cell boundary
    // relinks.
    let mobjs = array![p].span();
    let mut events: Array<MoveEvent> = array![];
    let before = p.cell;
    assert(
        try_move(w, mobjs, ref g3, ref p, 4, units(110), units(128), ref events).ok, 'small move',
    );
    assert(p.cell == before, 'same cell');
    assert(
        try_move(w, mobjs, ref g3, ref p, 4, units(110), units(120), ref events).ok, 'cross 128',
    );
    assert(p.cell != before, 'new cell');
    assert(
        things_in(ref g3, before).len() == 0 && things_in(ref g3, p.cell).len() == 1, 'relinked',
    );
}

#[test]
fn test_mobj_list_helpers() {
    let s = strip();
    let w = world(@s);
    let mut list: Array<Mobj> = array![];
    let p = player(w, 100, 128);
    assert(push(ref list, p) == 0, 'first slot');
    let m = monster(w, 300, 128);
    assert(push(ref list, m) == 1, 'second slot');
    assert(first_free(list.span()) == NO_MOBJ, 'no free slot');
    replace(ref list, 1, removed_mobj());
    assert(is_removed(list.at(1)) && !is_removed(list.at(0)), 'replaced');
    assert(first_free(list.span()) == 1, 'free slot found');
    // Fill to capacity.
    let mut k: u32 = list.len();
    while k != crate::mobj::MAX_MOBJS {
        push(ref list, removed_mobj());
        k += 1;
    }
    assert(push(ref list, p) == NO_MOBJ, 'full');
}

#[test]
fn test_things_collide_and_pick_up() {
    let s = strip();
    let w = world(@s);
    let mut g = new_grid();
    let mut p = player(w, 100, 128);
    set_thing_position(@w.map, ref g, ref p, 0);
    let mut m = monster(w, 150, 128);
    set_thing_position(@w.map, ref g, ref m, 1);
    let mut item = spawn_mobj(w, KIND_CLIP, units(100), units(60), SpawnZ::OnFloor);
    set_thing_position(@w.map, ref g, ref item, 2);
    let mobjs = array![p, m, item].span();
    let mut events: Array<MoveEvent> = array![];
    let v = try_move(w, mobjs, ref g, ref p, 0, units(120), units(128), ref events);
    assert(v.blocker == Blocker::Thing(1), 'monster blocks');
    let v = try_move(w, mobjs, ref g, ref p, 0, units(100), units(80), ref events);
    assert(v.ok && *events.at(0) == MoveEvent::Touch(2), 'clip touched');
    // A solid special thing would block after the touch; the clip is not.
    // A missile hits the monster; a missile fired by a monster's kin does
    // not; a missile against a non-shootable solid explodes silently.
    let mut ball = spawn_mobj(w, KIND_TROOPSHOT, units(120), units(128), SpawnZ::At(units(20)));
    set_thing_position(@w.map, ref g, ref ball, 3);
    let mobjs = array![p, m, item, ball].span();
    let mut events: Array<MoveEvent> = array![];
    let v = try_move(w, mobjs, ref g, ref ball, 3, units(135), units(128), ref events);
    assert(v.blocker == Blocker::Thing(1) && *events.at(0) == MoveEvent::MissileHit(1), 'hit');
    let mut solid = monster(w, 150, 128);
    solid.flags = MF_SOLID;
    let mobjs = array![p, solid, item, ball].span();
    let mut events: Array<MoveEvent> = array![];
    let v = try_move(w, mobjs, ref g, ref ball, 3, units(135), units(128), ref events);
    assert(v.blocker == Blocker::Thing(1) && events.len() == 0, 'explodes on a pillar');
    let mut ghost = monster(w, 150, 128);
    ghost.flags = 0;
    let mobjs = array![p, ghost, item, ball].span();
    let v = try_move(w, mobjs, ref g, ref ball, 3, units(135), units(128), ref events);
    assert(v.ok, 'nothing to hit');
    // Under a floating monster.
    let mut floating = m;
    floating.z = units(40);
    let mut low = ball;
    let mobjs = array![p, floating, item, low].span();
    let v = try_move(w, mobjs, ref g, ref low, 3, units(135), units(128), ref events);
    assert(v.ok, 'passes under');
}

// ---------------------------------------------------------------------------
// Slides and integration
// ---------------------------------------------------------------------------

#[test]
fn test_slide_along_walls() {
    let s = strip();
    let w = world(@s);
    // Straight into the top wall: the slide leaves the player against it.
    let mut g = new_grid();
    let mut p = player(w, 100, 200);
    set_thing_position(@w.map, ref g, ref p, 0);
    p.momy = units(50);
    let mobjs = array![p].span();
    let mut events: Array<MoveEvent> = array![];
    slide_move(w, mobjs, ref g, ref p, 0, ref events);
    assert(fixed::gt(p.y, units(230)) && fixed::le(p.y, units(240)), 'up against the wall');
    assert(p.momy == fixed::ZERO, 'vertical momentum clipped');
    // Diagonally into the top wall: keeps the x part.
    let mut p = player(w, 300, 200);
    p.momx = units(10);
    p.momy = units(50);
    let mobjs = array![p].span();
    slide_move(w, mobjs, ref g, ref p, 0, ref events);
    assert(fixed::gt(p.momx, fixed::ZERO) && p.momy == fixed::ZERO, 'slides east');
    assert(fixed::gt(p.x, units(300)), 'moved east');
    // Into the diagonal corner, mostly westward: the momentum is projected
    // onto the wall's direction (south-west along it).
    let mut p = player(w, 48, 200);
    p.momx = units(-30);
    p.momy = units(10);
    let mobjs = array![p].span();
    slide_move(w, mobjs, ref g, ref p, 0, ref events);
    assert(fixed::is_neg(p.momx) && fixed::is_neg(p.momy), 'turned along it');
    // Perpendicular to it: nothing to slide along.
    let mut p = player(w, 48, 200);
    p.momx = units(-30);
    p.momy = units(30);
    let mobjs = array![p].span();
    slide_move(w, mobjs, ref g, ref p, 0, ref events);
    // cos(90 degrees) is a hair below zero in the (i + 0.5)-sampled table,
    // so a residue well under a unit survives, as in Doom.
    assert(fixed::lt(fixed::abs(p.momx), fixed::FRACUNIT), 'stopped dead');
    assert(fixed::lt(fixed::abs(p.momy), fixed::FRACUNIT), 'stopped dead y');
    // The lite fallback: y alone, then x alone.
    let mut p = player(w, 100, 200);
    p.momx = units(10);
    p.momy = units(50);
    let mobjs = array![p].span();
    slide_move_lite(w, mobjs, ref g, ref p, 0, ref events);
    assert(p.y == units(200) && p.x == units(110), 'x alone succeeded');
    // Nothing found by the traces: the stairstep tries y alone, which
    // succeeds on the spot, and leaves the x momentum for the next tic.
    let mut p = player(w, 100, 128);
    p.momx = units(5);
    let mobjs = array![p].span();
    slide_move(w, mobjs, ref g, ref p, 0, ref events);
    assert(p.x == units(100) && p.y == units(128), 'stairstep keeps y');
    assert(p.momx == units(5), 'momentum kept');
}

#[test]
fn test_xy_movement_friction_and_stops() {
    let s = strip();
    let w = world(@s);
    let mut g = new_grid();
    let mut p = player(w, 100, 128);
    set_thing_position(@w.map, ref g, ref p, 0);
    let mobjs = array![p].span();
    let mut events: Array<MoveEvent> = array![];
    // At rest: nothing happens.
    assert(
        xy_movement(w, mobjs, ref g, ref p, 0, false, true, ref events) == XyOutcome::Moved, 'idle',
    );
    // A big move is clamped to MAXMOVE and done in halves.
    p.momx = units(40);
    assert(
        xy_movement(w, mobjs, ref g, ref p, 0, false, true, ref events) == XyOutcome::Moved, 'ok',
    );
    assert(p.x == units(130), 'moved MAXMOVE');
    assert(fixed::lt(p.momx, units(30)), 'friction applied');
    // Under STOPSPEED with no input: stops; with input: keeps going.
    p.momx = Fixed { enc: BIAS + 0x800 };
    assert(
        xy_movement(w, mobjs, ref g, ref p, 0, true, true, ref events) == XyOutcome::Moved,
        'walking',
    );
    assert(p.momx != fixed::ZERO, 'input keeps momentum');
    assert(
        xy_movement(w, mobjs, ref g, ref p, 0, false, true, ref events) == XyOutcome::Stopped,
        'stops',
    );
    assert(p.momx == fixed::ZERO, 'zero');
    // Airborne: no friction.
    p.momx = units(4);
    p.z = units(50);
    xy_movement(w, mobjs, ref g, ref p, 0, false, true, ref events);
    assert(p.momx == units(4), 'no air friction');
    // A corpse halfway off a step keeps sliding.
    let mut c = player(w, 120, 128);
    c.flags = MF_CORPSE;
    c.momx = units(4);
    c.floorz = units(16); // as if standing partly on S1's step
    let mobjs = array![c].span();
    xy_movement(w, mobjs, ref g, ref c, 0, false, true, ref events);
    // Its move succeeds into S1, where floorz == the sector floor: friction
    // then applies on the next tic only.
    assert(fixed::gt(c.momx, fixed::ZERO), 'corpse keeps sliding');
    // A monster stops dead on a wall; a missile reports the hit.
    let mut m = monster(w, 100, 128);
    m.momx = units(-30);
    m.momy = units(0);
    let mobjs = array![m].span();
    let _ = xy_movement(w, mobjs, ref g, ref m, 0, false, true, ref events);
    assert(m.momx == fixed::ZERO, 'monster stops at the wall');
    let mut ball = spawn_mobj(w, KIND_TROOPSHOT, units(20), units(128), SpawnZ::At(units(40)));
    ball.momx = units(-20);
    let mobjs = array![ball].span();
    match xy_movement(w, mobjs, ref g, ref ball, 0, false, true, ref events) {
        XyOutcome::MissileHit(b) => { assert(b == Blocker::Line(2), 'hit the wall'); },
        _ => { assert(false, 'missile hit'); },
    }
    // The player slides with the lite variant too (momentum clamped to
    // MAXMOVE first: 30 units from y = 230 reach the wall at 256).
    let mut p = player(w, 100, 230);
    p.momy = units(50);
    let mobjs = array![p].span();
    xy_movement(w, mobjs, ref g, ref p, 0, false, false, ref events);
    assert(p.y == units(230), 'lite: y refused');
}

#[test]
fn test_z_movement() {
    let s = strip();
    let w = world(@s);
    let mut p = player(w, 100, 128);
    // Gravity from rest: -2, then -1 per tic.
    p.z = units(100);
    z_movement(ref p, Option::None);
    assert(p.momz == units(-2), 'first tic of gravity');
    z_movement(ref p, Option::None);
    assert(p.momz == units(-3), 'then one per tic');
    // Landing hard.
    p.momz = units(-20);
    p.z = units(10);
    let out = z_movement(ref p, Option::None);
    assert(out.landed && p.z == p.floorz && p.momz == fixed::ZERO, 'landed');
    assert(out.hard_landing == units(-20), 'oof');
    // Into the ceiling.
    p.z = units(70);
    p.momz = units(10);
    z_movement(ref p, Option::None);
    assert(p.z == units(72) && p.momz == fixed::ZERO, 'clamped under the ceiling');
    // No gravity.
    let mut f = player(w, 100, 128);
    f.flags = f.flags | MF_NOGRAVITY;
    f.z = units(50);
    z_movement(ref f, Option::None);
    assert(f.momz == fixed::ZERO && f.z == units(50), 'hovers');
    // A floater rises toward a target above it and sinks toward one below.
    let mut fl = monster(w, 100, 128);
    fl.flags = fl.flags | MF_FLOAT | MF_NOGRAVITY;
    fl.z = units(10);
    let mut target = player(w, 110, 128);
    target.z = units(60);
    z_movement(ref fl, Option::Some(@target));
    assert(fl.z == units(14), 'floats up by FLOATSPEED');
    target.z = units(0);
    fl.z = units(60);
    z_movement(ref fl, Option::Some(@target));
    assert(fl.z == units(56), 'floats down');
    fl.flags = fl.flags | MF_INFLOAT;
    z_movement(ref fl, Option::Some(@target));
    assert(fl.z == units(56), 'in-float holds');
    // A missile hitting the floor or the ceiling.
    let mut ball = spawn_mobj(w, KIND_TROOPSHOT, units(100), units(128), SpawnZ::At(units(2)));
    ball.momz = units(-5);
    assert(z_movement(ref ball, Option::None).missile_hit, 'floor hit');
    let mut ball = spawn_mobj(w, KIND_TROOPSHOT, units(100), units(128), SpawnZ::At(units(118)));
    ball.momz = units(5);
    assert(z_movement(ref ball, Option::None).missile_hit, 'ceiling hit');
}

// ---------------------------------------------------------------------------
// Sight
// ---------------------------------------------------------------------------

#[test]
fn test_sight_rules() {
    let s = strip();
    let w = world(@s);
    let p0 = player(w, 64, 128);
    let p1 = player(w, 192, 128);
    let p3 = player(w, 448, 128);
    let p4 = player(w, 576, 128);
    let p5 = player(w, 700, 128);
    assert(!check_sight(w, @p0, @p5), 'REJECT');
    assert(check_sight(w, @p0, @p1), 'a step is no wall');
    assert(check_sight(w, @p0, @p3), 'looking up the steps');
    assert(check_sight(w, @p3, @p0), 'looking down the steps');
    assert(!check_sight(w, @p4, @p5), 'closed door');
    assert(!check_sight(w, @p1, @p4), 'low ceiling hides the top step');
    // The BLOCKING/BLOCKMONSTERS lines are two-sided with equal heights:
    // they never block sight.
    let pa = player(w, 30, 128);
    let pb = player(w, 230, 128);
    assert(check_sight(w, @pa, @pb), 'lines with equal heights');
    // Through the diagonal one-sided corner.
    let corner = player(w, 20, 240);
    assert(!check_sight(w, @corner, @p1), 'one-sided line blocks');
    // Off the grid: no sight.
    let void = player(w, -500, -500);
    assert(!check_sight(w, @void, @p0), 'nothing from the void');
    // The cache.
    let mut looker = monster(w, 64, 128);
    assert(check_sight_cached(w, ref looker, @p1, 0, 8), 'first look');
    looker.sight_ok = false;
    assert(!check_sight_cached(w, ref looker, @p1, 7, 8), 'remembered');
    assert(check_sight_cached(w, ref looker, @p1, 8, 8), 'looked again');
}

// ---------------------------------------------------------------------------
// Hitscan
// ---------------------------------------------------------------------------

#[test]
fn test_hitscan_rules() {
    let s = strip();
    let w = world(@s);
    let mut g = new_grid();
    let mut p = player(w, 64, 128);
    set_thing_position(@w.map, ref g, ref p, 0);
    let mobjs = array![p].span();
    // East, level: the shot clears the 16 step (slope < 0 at 64 units) and
    // hits the 24 step of line 5 (floor 40 > gun height 36).
    match line_attack(w, mobjs, ref g, 0, 0, units(2048), fixed::ZERO) {
        Hit::Wall((
            line, at, z,
        )) => {
            assert(line == 5, 'the step edge');
            assert(fixed::gt(at.x, units(250)) && fixed::lt(at.x, units(254)), 'puff pulled back');
            assert(fixed::gt(z, units(35)) && fixed::lt(z, units(37)), 'at gun height');
        },
        _ => { assert(false, 'wall hit'); },
    }
    // Aimed up: over the step, down the strip into the low ceiling of S4.
    match line_attack(w, mobjs, ref g, 0, 0, units(2048), Fixed { enc: BIAS + 0x2000 }) {
        Hit::Wall((line, _, _)) => { assert(line == 7, 'low ceiling'); },
        _ => { assert(false, 'wall hit 2'); },
    }
    // Too short to reach anything.
    assert(line_attack(w, mobjs, ref g, 0, 0, units(32), fixed::ZERO) == Hit::Nothing, 'max range');
    // Along the top wall, touching it: that wall is never crossed, the shot
    // goes on to the step edge. (From *exactly* on the wall the trace, which
    // the (i + 0.5)-sampled sine tilts a hair north, leaves the strip and
    // hits nothing — a degenerate position.)
    let mut on_wall = player(w, 100, 240);
    set_thing_position(@w.map, ref g, ref on_wall, 0);
    let mobjs2 = array![on_wall].span();
    match line_attack(w, mobjs2, ref g, 0, 0, units(512), fixed::ZERO) {
        Hit::Wall((line, _, _)) => { assert(line == 5, 'along the wall'); },
        _ => { assert(false, 'along the wall 2'); },
    }
    let mut exactly_on = player(w, 100, 256);
    set_thing_position(@w.map, ref g, ref exactly_on, 0);
    let mobjs2b = array![exactly_on].span();
    assert(
        line_attack(w, mobjs2b, ref g, 0, 0, units(512), fixed::ZERO) == Hit::Nothing,
        'on the wall',
    );
    // North: the top wall (from x = 100, clear of the diagonal's end at 64).
    let mut mid = player(w, 100, 128);
    set_thing_position(@w.map, ref g, ref mid, 0);
    let mobjs_mid = array![mid].span();
    match line_attack(w, mobjs_mid, ref g, 0, bam::ANG90, units(2048), fixed::ZERO) {
        Hit::Wall((line, _, _)) => { assert(line == 1, 'top wall'); },
        _ => { assert(false, 'wall hit 3'); },
    }
    // A monster in the way: aimed at, hit, and it bleeds.
    let mut m = monster(w, 100, 128);
    set_thing_position(@w.map, ref g, ref m, 1);
    let mobjs3 = array![p, m].span();
    let aim = aim_line_attack(w, mobjs3, ref g, 0, 0, units(1024));
    assert(aim.target == 1, 'aimed');
    match line_attack(w, mobjs3, ref g, 0, 0, units(2048), aim.slope) {
        Hit::Thing((idx, _, _)) => { assert(idx == 1 && bleeds(mobjs3.at(1)), 'hit and bleeds'); },
        _ => { assert(false, 'thing hit'); },
    }
    // Aiming over a corpse finds nothing; a corpse is not shot either.
    let mut corpse = m;
    corpse.flags = without(corpse.flags, MF_SHOOTABLE);
    let mobjs4 = array![p, corpse].span();
    assert(
        aim_line_attack(w, mobjs4, ref g, 0, 0, units(1024)).target == NO_MOBJ, 'corpse ignored',
    );
    match line_attack(w, mobjs4, ref g, 0, 0, units(2048), fixed::ZERO) {
        Hit::Wall((line, _, _)) => { assert(line == 5, 'through the corpse'); },
        _ => { assert(false, 'wall hit 4'); },
    }
    // A thing above the aim cone is not aimed at.
    let mut high = m;
    high.z = units(120);
    let mobjs5 = array![p, high].span();
    assert(aim_line_attack(w, mobjs5, ref g, 0, 0, units(1024)).target == NO_MOBJ, 'over the cone');
    // The raw traversal lists both lines and things, nearest cell first.
    let list = path_traverse(w, mobjs3, ref g, pt(64, 128), pt(300, 128), true, 0);
    assert(list.len() >= 3, 'lines and a thing');
    // Aiming down the closed door stops at it.
    let mut p4 = player(w, 576, 128);
    set_thing_position(@w.map, ref g, ref p4, 2);
    let mobjs6 = array![p, m, p4].span();
    assert(aim_line_attack(w, mobjs6, ref g, 2, 0, units(1024)).target == NO_MOBJ, 'door');
}

// ---------------------------------------------------------------------------
// Damage, spawn, state
// ---------------------------------------------------------------------------

#[test]
fn test_damage_edge_cases() {
    let s = strip();
    let w = world(@s);
    let mut rng = from_index(1);
    let p = player(w, 64, 128);
    // Fall forwards: light damage that kills, from far below.
    let mut m = monster(w, 100, 128);
    m.health = 3;
    let mut low = player(w, 100, 128);
    low.z = units(-200);
    let mobjs = array![low, m].span();
    let out = damage_mobj(w, mobjs, ref rng, ref m, 1, 0, 0, 10, true);
    assert(out.died, 'killed');
    // Not shootable: nothing happens.
    let mut pillar = monster(w, 100, 128);
    pillar.flags = MF_SOLID;
    let out = damage_mobj(w, mobjs, ref rng, ref pillar, 1, 0, 0, 10, true);
    assert(!out.died && !out.pain && pillar.health == 20, 'not shootable');
    // A skull-flyer's momentum is zeroed (flag only, no lost souls here).
    let mut fly = monster(w, 100, 128);
    fly.flags = fly.flags | crate::mobj::MF_SKULLFLY;
    fly.momx = units(5);
    let out = damage_mobj(w, mobjs, ref rng, ref fly, 1, NO_MOBJ, 0, 1, true);
    assert(fly.momx == fixed::ZERO && !out.pain, 'skullfly stopped, no pain');
    // Killing the player clears MF_SOLID.
    let mut pl = p;
    let (_, drop) = kill_mobj(w, ref rng, ref pl);
    assert(!has(pl.flags, MF_SOLID) && drop.is_none(), 'dead player');
    // A source equal to the target does not retaliate.
    let mut m2 = monster(w, 100, 128);
    let out = damage_mobj(w, mobjs, ref rng, ref m2, 1, 1, 1, 1, false);
    assert(!out.retaliated, 'self-inflicted');
}

#[test]
fn test_spawn_helpers() {
    let s = strip();
    let w = world(@s);
    let pl = spawn_player(w, pt(64, 128), bam::ANG90);
    assert(pl.kind == KIND_PLAYER && pl.angle == bam::ANG90, 'player');
    let t = doom_map::MapThing {
        position: pt(200, 128), angle: bam::ANG180, doomednum: 3004, flags: 7 + MTF_AMBUSH,
    };
    let m = spawn_map_thing(w, t).unwrap();
    assert(m.kind == KIND_POSSESSED && has(m.flags, crate::mobj::MF_AMBUSH), 'ambusher');
    assert(m.z == units(16) && m.sector == 1, 'on S1 floor');
    let start = doom_map::MapThing { position: pt(200, 128), angle: 0, doomednum: 1, flags: 7 };
    assert(spawn_map_thing(w, start).is_none(), 'starts are not things');
    let hanging = spawn_mobj(w, KIND_TROOP, units(200), units(128), SpawnZ::OnCeiling);
    assert(hanging.z == fixed::sub(units(128), hanging.height), 'from the ceiling');
    // set_state and the tables.
    let mut m2 = m;
    let action = set_state(w, ref m2, thing_info(KIND_POSSESSED).seestate);
    assert(
        m2.state == thing_info(KIND_POSSESSED).seestate && action != 0, 'see state runs A_Chase',
    );
    // A missile spawned against a wall explodes at once.
    let mut g = new_grid();
    let mut imp = spawn_mobj(w, KIND_TROOP, units(8), units(128), SpawnZ::OnFloor);
    set_thing_position(@w.map, ref g, ref imp, 0);
    let mut target = player(w, -100, 128);
    let mobjs = array![imp, target].span();
    let mut rng = from_index(1);
    let mut events: Array<MoveEvent> = array![];
    let (ball, exploded) = spawn_missile(
        w, mobjs, ref g, ref rng, @imp, 0, @target, FIREBALL, 2, ref events,
    );
    assert(exploded && !has(ball.flags, MF_MISSILE), 'exploded on spawn');
    // Against a shadow target the aim is fuzzed.
    target.flags = target.flags | crate::mobj::MF_SHADOW;
    target.x = units(300);
    let mobjs = array![imp, target].span();
    let (ball2, exploded2) = spawn_missile(
        w, mobjs, ref g, ref rng, @imp, 0, @target, FIREBALL, 2, ref events,
    );
    assert(!exploded2 && fixed::gt(ball2.momx, fixed::ZERO), 'flies east');
    let mut b = ball2;
    explode_missile(w, ref rng, ref b);
    assert(b.state == thing_info(KIND_TROOPSHOT).deathstate, 'exploded');
}

#[test]
fn test_world_helpers_and_line_meta() {
    let s = strip();
    let w = world(@s);
    assert(floor_of(w.floor, 2) == units(40) && ceiling_of(w.ceil, 4) == units(80), 'heights');
    let moved = array![
        units(0).enc, units(16).enc, units(40).enc, units(72).enc, units(72).enc, units(72).enc,
    ];
    let raised = array![
        units(128).enc, units(128).enc, units(128).enc, units(128).enc, units(80).enc,
        units(200).enc,
    ];
    let w2 = with_heights(w, moved.span(), raised.span());
    // The door is open now: S4 -> S5 fits.
    let mut p = player(w2, 600, 128);
    p.z = units(72);
    let mut g = new_grid();
    let mut events: Array<MoveEvent> = array![];
    let v = try_move(w2, array![p].span(), ref g, ref p, 0, units(650), units(128), ref events);
    assert(v.blocker == Blocker::Fit, 'S4 itself is 8 units tall');
    let mut p5 = player(w2, 700, 128);
    assert(p5.ceilingz == units(200), 'raised ceiling');
    let meta = line_meta(*s.l_packed.at(9));
    assert(meta.flags == ML_TWOSIDED + ML_BLOCKMONSTERS && meta.special == 97, 'meta');
    assert(meta.front == 0 && meta.back == 0 && meta.tag == 0, 'sectors');
    let o = line_opening(w.floor, w.ceil, 3, 4);
    assert(o.top == units(80) && o.bottom == units(72) && o.lowfloor == units(72), 'opening');
    assert(!o.floors_differ && o.ceilings_differ, 'differ flags');
    let o2 = line_opening(w.floor, w.ceil, 1, 0);
    assert(o2.bottom == units(16) && o2.lowfloor == units(0) && o2.floors_differ, 'reversed');
    assert(has(MF_SPECIAL + MF_SOLID, MF_SOLID) && !has(MF_SPECIAL, MF_SOLID), 'has');
    assert(without(MF_SPECIAL + MF_SOLID, MF_SOLID) == MF_SPECIAL, 'without');
}


// SPDX-License-Identifier: GPL-2.0-only
//! Tests for the generated level data and its accessors.
//!
//! The expectations come from `src/tests/vectors.cairo`, which
//! `scripts/gen_level.py` computes **from the WAD JSON**, never from the
//! emitted arrays — so a bug in the emitter shows up as a failing test
//! rather than as two copies of the same mistake.

mod vectors;
use blockmap::{cell_index, cell_of, list_item, list_range};
use bsp::{SUBSECTOR_FLAG, is_subsector, point_in_subsector, subsector_of};
use fixed::Fixed;
use geom2d::{Point, SIDE_BACK, SIDE_FRONT, half_plane, hoist, point_side};
use vectors::{LINE_VERTICES, PINNED_LINES, SAMPLE_POINTS};
use super::levels::e1m1;
use super::{
    LevelId, ML_BLOCKING, ML_TWOSIDED, NO_SECTOR, REJECT_BITS, blockmap_lists, descent_start,
    genesis, grid, linedef, linedef_box, linedef_diagonal, linedef_flags, linedef_half_plane,
    linedef_sectors, linedef_special, linedef_v1, linedef_v2, load, node_side, nodes, num_linedefs,
    num_sectors, num_subsectors, num_things, reject, sector, sector_ceiling, sector_floor,
    subsector_at, subsector_in_cell, subsector_sector, thing, things,
};

/// A map-unit coordinate as a `Fixed`.
fn at(x: felt252, y: felt252) -> Point {
    Point { x: fixed::from_units(x), y: fixed::from_units(y) }
}

// ---------------------------------------------------------------------------
// Counts: the generated data matches the WAD lumps
// ---------------------------------------------------------------------------

#[test]
fn test_counts_match_the_wad() {
    let m = load(LevelId::E1M1);
    assert(num_linedefs(@m) == 1175, 'linedefs');
    assert(num_sectors(@m) == 182, 'sectors');
    assert(num_subsectors(@m) == 682, 'subsectors');
    assert(m.n_ab.len() == 681, 'nodes');
    assert(m.n_child0.len() == 681, 'child0');
    assert(m.n_child1.len() == 681, 'child1');
    assert(m.root == 680, 'root node');
    assert(m.id == 'E1M1', 'level id');
    assert(e1m1::BM_COLUMNS * e1m1::BM_ROWS == 864, 'blockmap cells');
}

#[test]
fn test_spans_are_consistently_sized() {
    let m = load(LevelId::E1M1);
    let lines = num_linedefs(@m);
    assert(m.l_bb.len() == lines, 'l_bb');
    assert(m.l_cb.len() == lines, 'l_cb');
    assert(m.l_box_lr.len() == lines, 'l_box_lr');
    assert(m.l_box_bt.len() == lines, 'l_box_bt');
    assert(m.l_packed.len() == lines, 'l_packed');
    assert(m.n_bb.len() == m.n_ab.len(), 'n_bb');
    assert(m.n_cb.len() == m.n_ab.len(), 'n_cb');
    assert(m.s_ceil.len() == num_sectors(@m), 's_ceil');
    assert(m.s_meta.len() == num_sectors(@m), 's_meta');
    assert(m.pow2.len() == REJECT_BITS, 'pow2');
    assert(m.reject.len() == num_sectors(@m) * m.reject_stride, 'reject rows');
    // `PackedLists::start` has one entry per cell plus the end sentinel.
    let cells = e1m1::BM_COLUMNS * e1m1::BM_ROWS;
    assert(m.blockmap.start.len() == cells + 1, 'bm start');
    assert(m.cell_node.len() == cells, 'cell_node');
}

// ---------------------------------------------------------------------------
// The predicate pin: the Python builder against `geom2d::half_plane`
// ---------------------------------------------------------------------------

#[test]
fn test_linedef_predicates_match_geom2d_half_plane() {
    let m = load(LevelId::E1M1);
    let v = LINE_VERTICES.span();
    let mut i: u32 = 0;
    while i != PINNED_LINES {
        let v1 = at(*v.at(i * 4), *v.at(i * 4 + 1));
        let v2 = at(*v.at(i * 4 + 2), *v.at(i * 4 + 3));
        let expected = half_plane(v1, v2);
        let got = linedef_half_plane(@m, i);
        assert(got.ab == expected.ab, 'ab');
        assert(got.bb == expected.bb, 'bb');
        assert(got.cb == expected.cb, 'cb');
        assert(linedef_diagonal(@m, i) == geom2d::diagonal(v1, v2), 'diag');
        i += 1;
    }
}

#[test]
fn test_linedef_boxes_match_their_vertices() {
    let m = load(LevelId::E1M1);
    let v = LINE_VERTICES.span();
    let mut i: u32 = 0;
    while i != PINNED_LINES {
        let v1 = at(*v.at(i * 4), *v.at(i * 4 + 1));
        let v2 = at(*v.at(i * 4 + 2), *v.at(i * 4 + 3));
        let expected = geom2d::box_of_segment(v1, v2);
        let got = linedef_box(@m, i);
        assert(got.left == expected.left, 'left');
        assert(got.bottom == expected.bottom, 'bottom');
        assert(got.right == expected.right, 'right');
        assert(got.top == expected.top, 'top');
        i += 1;
    }
}

#[test]
fn test_linedef_vertices_are_recovered_exactly() {
    // The VERTEXES lump is not compiled in: `linedef_v1`/`linedef_v2` rebuild
    // the two endpoints from the stored box and the sign of the deltas.
    let m = load(LevelId::E1M1);
    let v = LINE_VERTICES.span();
    let mut i: u32 = 0;
    while i != PINNED_LINES {
        let v1 = at(*v.at(i * 4), *v.at(i * 4 + 1));
        let v2 = at(*v.at(i * 4 + 2), *v.at(i * 4 + 3));
        assert(linedef_v1(@m, i) == v1, 'v1');
        assert(linedef_v2(@m, i) == v2, 'v2');
        i += 1;
    }
}

#[test]
fn test_stored_predicate_agrees_with_point_on_side() {
    // Ten lines against four probe points each, through the two independent
    // routes: the stored coefficients, and `geom2d::point_on_side` from the
    // recovered vertices.
    let m = load(LevelId::E1M1);
    let v = LINE_VERTICES.span();
    let probes: Array<(felt252, felt252)> = array![(0, 0), (512, 512), (-256, 1024), (2048, -512)];
    let mut i: u32 = 0;
    while i != 10 {
        let v1 = at(*v.at(i * 4), *v.at(i * 4 + 1));
        let v2 = at(*v.at(i * 4 + 2), *v.at(i * 4 + 3));
        let hp = linedef_half_plane(@m, i);
        let mut k: u32 = 0;
        while k != probes.len() {
            let (px, py) = *probes.at(k);
            let p = at(px, py);
            assert(point_side(hp, p, hoist(p)) == geom2d::point_on_side(p, v1, v2), 'side');
            k += 1;
        }
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Spot values against the WAD lumps
// ---------------------------------------------------------------------------

#[test]
fn test_sector_spot_values() {
    // Sector 0 of E1M1: floor -160, ceiling 376, light 202, special 0, tag 0.
    let m = load(LevelId::E1M1);
    let s = sector(@m, 0);
    assert(s.floor == fixed::from_units(-160), 'floor 0');
    assert(s.ceiling == fixed::from_units(376), 'ceiling 0');
    assert(s.light == 202, 'light 0');
    assert(s.special == 0, 'special 0');
    assert(s.tag == 0, 'tag 0');
    assert(sector_floor(@m, 0) == s.floor, 'floor accessor');
    assert(sector_ceiling(@m, 0) == s.ceiling, 'ceiling accessor');
}

#[test]
fn test_sector_specials_and_tags_are_preserved() {
    // The report lists 6 strobe (12), 4 secret (9), 3 random-blink (1) and
    // 3 damaging (7) sectors, and tags 1..6.
    let m = load(LevelId::E1M1);
    let n = num_sectors(@m);
    let mut i: u32 = 0;
    let mut specials: u32 = 0;
    let mut tagged: u32 = 0;
    let mut max_tag: u32 = 0;
    while i != n {
        let s = sector(@m, i);
        if s.special != 0 {
            specials += 1;
        }
        if s.tag != 0 {
            tagged += 1;
            if s.tag > max_tag {
                max_tag = s.tag;
            }
        }
        assert(s.light <= 255, 'light in range');
        i += 1;
    }
    assert(specials == 16, 'special sectors');
    assert(max_tag == 6, 'max sector tag');
    assert(tagged != 0, 'some sectors tagged');
}

#[test]
fn test_linedef_spot_values() {
    // Linedef 0 of E1M1: flags 1 (ML_BLOCKING), no special, one sided.
    let m = load(LevelId::E1M1);
    let l = linedef(@m, 0);
    assert(l.flags == ML_BLOCKING, 'flags 0');
    assert(l.special == 0, 'special 0');
    assert(l.tag == 0, 'tag 0');
    assert(l.back_sector == NO_SECTOR, 'one sided');
    assert(l.front_sector != NO_SECTOR, 'has a front sector');
    assert(linedef_flags(@m, 0) == l.flags, 'flags accessor');
    let (special, tag) = linedef_special(@m, 0);
    assert(special == l.special && tag == l.tag, 'special accessor');
}

#[test]
fn test_linedef_specials_match_the_report() {
    // REPORT-e1m1.md: 42 of 1175 linedefs carry a non-zero special, one of
    // them the exit switch (type 11).
    let m = load(LevelId::E1M1);
    let n = num_linedefs(@m);
    let mut i: u32 = 0;
    let mut specials: u32 = 0;
    let mut exits: u32 = 0;
    let mut two_sided: u32 = 0;
    let mut blocking: u32 = 0;
    while i != n {
        let (special, _) = linedef_special(@m, i);
        if special != 0 {
            specials += 1;
        }
        if special == 11 {
            exits += 1;
        }
        let flags = linedef_flags(@m, i);
        if flags / ML_TWOSIDED % 2 == 1 {
            two_sided += 1;
        }
        if flags % 2 == 1 {
            blocking += 1;
        }
        i += 1;
    }
    assert(specials == 42, 'special linedefs');
    assert(exits == 1, 'one exit switch');
    assert(two_sided == 654, 'two sided linedefs');
    assert(blocking == 547, 'blocking linedefs');
}

#[test]
fn test_two_sided_lines_have_two_sectors() {
    let m = load(LevelId::E1M1);
    let n = num_linedefs(@m);
    let mut i: u32 = 0;
    while i != n {
        let (front, back) = linedef_sectors(@m, i);
        assert(front < 182, 'front sector in range');
        let two_sided = linedef_flags(@m, i) / ML_TWOSIDED % 2 == 1;
        if two_sided {
            assert(back < 182, 'back sector in range');
        } else {
            assert(back == NO_SECTOR, 'one sided has no back');
        }
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// BSP
// ---------------------------------------------------------------------------

#[test]
fn test_node_children_use_the_bsp_subsector_flag() {
    let m = load(LevelId::E1M1);
    let n = m.n_child0.len();
    let mut i: u32 = 0;
    let mut leaves: u32 = 0;
    while i != n {
        let c0 = *m.n_child0.at(i);
        let c1 = *m.n_child1.at(i);
        if is_subsector(c0) {
            assert(subsector_of(c0) < 682, 'leaf 0 in range');
            leaves += 1;
        } else {
            assert(c0 < 681, 'node 0 in range');
        }
        if is_subsector(c1) {
            assert(subsector_of(c1) < 682, 'leaf 1 in range');
            leaves += 1;
        } else {
            assert(c1 < 681, 'node 1 in range');
        }
        i += 1;
    }
    // Every subsector is exactly one node's child on this map.
    assert(leaves == 682, 'every leaf referenced once');
    assert(SUBSECTOR_FLAG == 0x80000000, 'flag value');
}

#[test]
fn test_subsector_sectors_are_in_range() {
    let m = load(LevelId::E1M1);
    let n = num_subsectors(@m);
    let mut i: u32 = 0;
    while i != n {
        assert(subsector_sector(@m, i) < 182, 'sector in range');
        i += 1;
    }
    // Spot values from the JSON's `derived.subsectorSectors`.
    assert(subsector_sector(@m, 0) == 122, 'ss 0');
    assert(subsector_sector(@m, 3) == 8, 'ss 3');
}

#[test]
fn test_node_side_matches_a_direct_descent() {
    let m = load(LevelId::E1M1);
    let nd = nodes(@m);
    let p = at(1056, -3200 + 3200);
    let rhs = hoist(p);
    let side = node_side(@m, m.root, p, rhs);
    assert(side == SIDE_FRONT || side == SIDE_BACK, 'a side');
    let child = if side == SIDE_FRONT {
        *m.n_child0.at(m.root)
    } else {
        *m.n_child1.at(m.root)
    };
    // One manual step of the descent must agree with `point_in_subsector`
    // restarted from that child.
    assert(point_in_subsector(@nd, child, p) == subsector_at(@m, p), 'descent agrees');
}

// ---------------------------------------------------------------------------
// R2-A9 accelerator (D22: CELL_NODE)
// ---------------------------------------------------------------------------

#[test]
fn test_descent_from_root_matches_the_python_transcription() {
    // Every sampled point's subsector, computed by a Python transcription of
    // `R_PointInSubsector` from the WAD JSON, must be what the Cairo descent
    // reaches.
    let m = load(LevelId::E1M1);
    let pts = SAMPLE_POINTS.span();
    let n = pts.len() / 3;
    let mut i: u32 = 0;
    while i != n {
        let p = at(*pts.at(i * 3), *pts.at(i * 3 + 1));
        let expected: u32 = (*pts.at(i * 3 + 2)).try_into().unwrap();
        assert(subsector_at(@m, p) == expected, 'descent matches python');
        i += 1;
    }
}

#[test]
fn test_descent_start_answers_exactly_like_the_root() {
    let m = load(LevelId::E1M1);
    let pts = SAMPLE_POINTS.span();
    let g = grid(@m);
    let n = pts.len() / 3;
    let mut i: u32 = 0;
    while i != n {
        let p = at(*pts.at(i * 3), *pts.at(i * 3 + 1));
        match cell_of(g, p) {
            Option::Some((
                cx, cy,
            )) => {
                let cell = cell_index(g, cx, cy);
                assert(
                    subsector_in_cell(@m, cell, p) == subsector_at(@m, p), 'accelerated == root',
                );
            },
            Option::None => {},
        }
        i += 1;
    }
}

#[test]
fn test_descent_start_ids_are_in_range() {
    let m = load(LevelId::E1M1);
    let n = m.cell_node.len();
    let mut i: u32 = 0;
    while i != n {
        let c = descent_start(@m, i);
        if is_subsector(c) {
            assert(subsector_of(c) < 682, 'leaf in range');
        } else {
            assert(c < 681, 'node in range');
        }
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Blockmap
// ---------------------------------------------------------------------------

#[test]
fn test_blockmap_lists_are_valid() {
    let m = load(LevelId::E1M1);
    let lists = blockmap_lists(@m);
    let cells = e1m1::BM_COLUMNS * e1m1::BM_ROWS;
    let lines = num_linedefs(@m);
    let mut cell: u32 = 0;
    let mut total: u32 = 0;
    let mut nonempty: u32 = 0;
    let mut widest: u32 = 0;
    while cell != cells {
        let (from, to) = list_range(@lists, cell);
        assert(from <= to, 'range is ordered');
        if to != from {
            nonempty += 1;
            if to - from > widest {
                widest = to - from;
            }
        }
        let mut k = from;
        let mut previous: u32 = 0;
        let mut first = true;
        while k != to {
            let line = list_item(@lists, k);
            assert(line < lines, 'linedef id in range');
            if !first {
                assert(line > previous, 'sorted and deduplicated');
            }
            previous = line;
            first = false;
            k += 1;
        }
        total += to - from;
        cell += 1;
    }
    // S1 §4 / REPORT-e1m1.md: 2 064 entries, 494 non-empty cells, max 26.
    assert(total == 2064, 'blocklist entries');
    assert(nonempty == 494, 'non-empty cells');
    assert(widest == 26, 'widest cell');
    assert(*lists.start.at(cells) == total, 'end sentinel');
}

#[test]
fn test_grid_matches_the_wad_blockmap_header() {
    let m = load(LevelId::E1M1);
    let g = grid(@m);
    assert(g.columns == 32, 'columns');
    assert(g.rows == 27, 'rows');
    assert(g.origin_x == fixed::from_units(-712), 'origin x');
    assert(g.origin_y == fixed::from_units(-1072), 'origin y');
    // The player start must be on the grid.
    let gen = genesis(LevelId::E1M1);
    assert(cell_of(g, gen.start).is_some(), 'player start on grid');
}

// ---------------------------------------------------------------------------
// REJECT
// ---------------------------------------------------------------------------

#[test]
fn test_reject_is_symmetric() {
    let m = load(LevelId::E1M1);
    let n = num_sectors(@m);
    let mut i: u32 = 0;
    let mut blocked: u32 = 0;
    while i != n {
        let mut j: u32 = i;
        while j != n {
            let a = reject(@m, i, j);
            assert(a == reject(@m, j, i), 'reject is symmetric');
            if a {
                blocked += if i == j {
                    1
                } else {
                    2
                };
            }
            j += 1;
        }
        i += 1;
    }
    // REPORT-e1m1.md: 70.9 % of the 33 124 pairs are blocked.
    assert(blocked == 23490, 'blocked pairs');
}

#[test]
fn test_reject_lets_a_sector_see_itself() {
    let m = load(LevelId::E1M1);
    let n = num_sectors(@m);
    let mut i: u32 = 0;
    while i != n {
        assert(!reject(@m, i, i), 'a sector sees itself');
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Things
// ---------------------------------------------------------------------------

#[test]
fn test_things_are_filtered_to_skill_two() {
    // 221 of the 292 THINGS survive `P_SpawnMapThing`'s skill-2 test; every
    // one of them either carries MTF_NORMAL and not MTF_NOTSINGLE, or is a
    // player/deathmatch start (which bypass the test).
    let m = load(LevelId::E1M1);
    let n = num_things(@m);
    assert(n == 221, 'skill 2 things');
    assert(things(@m).len() == n, 'things span');
    let mut i: u32 = 0;
    let mut monsters: u32 = 0;
    let mut starts: u32 = 0;
    while i != n {
        let t = thing(@m, i);
        let is_start = t.doomednum <= 4 || t.doomednum == 11;
        if !is_start {
            assert(t.flags / 2 % 2 == 1, 'has MTF_NORMAL');
            assert(t.flags / 16 % 2 == 0, 'not multiplayer only');
        } else {
            starts += 1;
        }
        if t.doomednum == 3001
            || t.doomednum == 3002
            || t.doomednum == 3004
            || t.doomednum == 9
            || t.doomednum == 58 {
            monsters += 1;
        }
        assert(t.angle % 0x20000000 == 0, 'angle is a multiple of 45');
        i += 1;
    }
    // 10 imps + 5 demons + 4 zombiemen + 10 shotgun guys, no spectre.
    assert(monsters == 29, 'monsters at skill 2');
    assert(starts == 12, 'player and dm starts');
}

#[test]
fn test_thing_spot_value_and_genesis() {
    let m = load(LevelId::E1M1);
    let gen = genesis(LevelId::E1M1);
    assert(gen.id == 'E1M1', 'level id');
    assert(gen.num_things == num_things(@m), 'thing count');
    // The Player 1 start must be one of the kept things, at the same place.
    let n = num_things(@m);
    let mut i: u32 = 0;
    let mut found = false;
    while i != n {
        let t = thing(@m, i);
        if t.doomednum == 1 {
            assert(t.position == gen.start, 'start position');
            assert(t.angle == gen.angle, 'start angle');
            found = true;
        }
        i += 1;
    }
    assert(found, 'player 1 start is kept');
}

#[test]
fn test_thing_positions_are_inside_the_map_bounds() {
    let m = load(LevelId::E1M1);
    let n = num_things(@m);
    let mut i: u32 = 0;
    while i != n {
        let t = thing(@m, i);
        assert(fixed::ge(t.position.x, Fixed { enc: e1m1::BOUNDS_LEFT }), 'x >= left');
        assert(fixed::le(t.position.x, Fixed { enc: e1m1::BOUNDS_RIGHT }), 'x <= right');
        assert(fixed::ge(t.position.y, Fixed { enc: e1m1::BOUNDS_BOTTOM }), 'y >= bottom');
        assert(fixed::le(t.position.y, Fixed { enc: e1m1::BOUNDS_TOP }), 'y <= top');
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Provability (A7)
// ---------------------------------------------------------------------------

#[test]
fn test_every_constant_stays_below_2_pow_72() {
    // S0 measured +33 % on `range_check_9_9` above 2^72; every packed felt
    // and every coefficient must stay under it (PLAN.md A7, S1 §7 rule 6).
    let m = load(LevelId::E1M1);
    let limit: u128 = 0x1000000000000000000; // 2^72
    check_below(m.l_ab, limit);
    check_below(m.l_bb, limit);
    check_below(m.l_cb, limit);
    check_below(m.l_box_lr, limit);
    check_below(m.l_box_bt, limit);
    check_below(m.l_packed, limit);
    check_below(m.n_ab, limit);
    check_below(m.n_bb, limit);
    check_below(m.n_cb, limit);
    check_below(m.s_floor, limit);
    check_below(m.s_ceil, limit);
    check_below(m.s_meta, limit);
    check_below(m.reject, limit);
    check_below(m.things, limit);
}

/// Every element converts to a `u128` (so it is non-negative and below 2^128)
/// and is below `limit`.
fn check_below(span: Span<felt252>, limit: u128) {
    let mut i: u32 = 0;
    while i != span.len() {
        let v: u128 = (*span.at(i)).try_into().unwrap();
        assert(v < limit, 'below 2^72');
        i += 1;
    }
}


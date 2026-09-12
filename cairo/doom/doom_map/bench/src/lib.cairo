// SPDX-License-Identifier: GPL-2.0-only
//! Step-cost benchmark and bytecode scale for `doom_map`.
//!
//! Differential measurement (S1 §3.1) with **varying operands** and a
//! per-operation baseline (`base` in `budgets.json`):
//!
//! * op 0 — bare loop;
//! * op 1 — the loaded `LevelMap` plus the index arithmetic every accessor
//!   pays (the baseline of every array read);
//! * op 2 — op 1 plus a `Point` and its hoisted term, the baseline of the
//!   predicate and location ops.
//!
//! `main` also references **every** generated array (op 99), so that nothing
//! is dead-code-eliminated and the compiled size measured by `measure.py`
//! against `baseline/` is the real cost of the level data.

use blockmap::{cell_index, cell_of};
use doom_map::{
    LevelId, blockmap_lists, descent_start, genesis, linedef, linedef_box, linedef_diagonal,
    linedef_flags, linedef_half_plane, linedef_sectors, linedef_special, linedef_v1, load,
    node_side, num_linedefs, reject, sector, sector_ceiling, sector_floor, subsector_at,
    subsector_candidate, subsector_candidates, subsector_in_cell, subsector_sector, thing,
};
use fixed::Fixed;
use geom2d::{Point, hoist};

/// A probe point that really moves: a 32 x 32 lattice of 64-unit steps over
/// the middle of E1M1, so that consecutive iterations land in different
/// blockmap cells and different subsectors. A point that barely moves would
/// make the R2-A9 comparison meaningless.
fn probe(i: u32) -> Point {
    let cx: felt252 = (i % 32).into();
    let cy: felt252 = ((i / 32) % 32).into();
    Point {
        x: Fixed { enc: 0x100000000 + cx * 64 * 65536 },
        y: Fixed { enc: 0x100000000 + cy * 64 * 65536 },
    }
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let m = load(LevelId::E1M1);
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;

    if op == 0 { // bare loop
        while i != n {
            i += 1;
        }
    } else if op == 1 {
        // index baseline: the modulo every array op pays
        while i != n {
            acc += (i % 1024).into();
            i += 1;
        }
    } else if op == 2 {
        // probe point + hoisted term baseline
        while i != n {
            let p = probe(i);
            acc += hoist(p) + (i % 1024).into();
            i += 1;
        }
    } else if op == 3 {
        while i != n {
            let hp = linedef_half_plane(@m, i % 1024);
            acc += hp.ab + hp.bb + hp.cb;
            i += 1;
        }
    } else if op == 4 {
        while i != n {
            let b = linedef_box(@m, i % 1024);
            acc += b.left.enc + b.bottom.enc + b.right.enc + b.top.enc;
            i += 1;
        }
    } else if op == 5 {
        while i != n {
            acc += linedef_flags(@m, i % 1024).into();
            i += 1;
        }
    } else if op == 6 {
        while i != n {
            let (s, t) = linedef_special(@m, i % 1024);
            acc += s.into() + t.into();
            i += 1;
        }
    } else if op == 7 {
        while i != n {
            let (f, b) = linedef_sectors(@m, i % 1024);
            acc += f.into() + b.into();
            i += 1;
        }
    } else if op == 8 {
        while i != n {
            acc += linedef_diagonal(@m, i % 1024).into();
            i += 1;
        }
    } else if op == 9 {
        while i != n {
            let p = linedef_v1(@m, i % 1024);
            acc += p.x.enc + p.y.enc;
            i += 1;
        }
    } else if op == 10 {
        while i != n {
            let l = linedef(@m, i % 1024);
            acc += l.hp.ab + l.bbox.left.enc + l.flags.into() + l.front_sector.into();
            i += 1;
        }
    } else if op == 11 {
        while i != n {
            acc += sector_floor(@m, i % 128).enc + sector_ceiling(@m, i % 128).enc;
            i += 1;
        }
    } else if op == 12 {
        while i != n {
            let s = sector(@m, i % 128);
            acc += s.floor.enc + s.light.into() + s.special.into() + s.tag.into();
            i += 1;
        }
    } else if op == 13 {
        while i != n {
            acc += subsector_sector(@m, i % 512).into();
            i += 1;
        }
    } else if op == 14 {
        while i != n {
            if reject(@m, i % 128, (i + 7) % 128) {
                acc += 1;
            }
            i += 1;
        }
    } else if op == 15 {
        while i != n {
            let t = thing(@m, i % 128);
            acc += t.position.x.enc + t.angle.into() + t.doomednum.into();
            i += 1;
        }
    } else if op == 16 {
        while i != n {
            acc += descent_start(@m, i % 512).into();
            i += 1;
        }
    } else if op == 17 {
        while i != n {
            acc += subsector_candidate(@m, i % 1024).into();
            i += 1;
        }
    } else if op == 18 {
        while i != n {
            let (from, to) = subsector_candidates(@m, i % 512);
            acc += from.into() + to.into();
            i += 1;
        }
    } else if op == 19 {
        // full BSP descent from the root (the ground truth)
        while i != n {
            let p = probe(i);
            acc += subsector_at(@m, p).into() + (i % 1024).into();
            i += 1;
        }
    } else if op == 20 {
        // R2-A9: the same answer, starting from the cell's node
        while i != n {
            let p = probe(i);
            let g = doom_map::grid(@m);
            let cell = match cell_of(g, p) {
                Option::Some((cx, cy)) => cell_index(g, cx, cy),
                Option::None => 0,
            };
            acc += subsector_in_cell(@m, cell, p).into() + (i % 1024).into();
            i += 1;
        }
    } else if op == 21 {
        while i != n {
            let p = probe(i);
            acc += node_side(@m, i % 512, p, hoist(p)).into() + (i % 1024).into();
            i += 1;
        }
    } else if op == 22 {
        // one blockmap cell's linedef list, open-coded (R2-A10)
        let lists = blockmap_lists(@m);
        while i != n {
            let (from, to) = blockmap::list_range(@lists, i % 512);
            let mut k = from;
            while k != to {
                acc += blockmap::list_item(@lists, k).into();
                k += 1;
            }
            i += 1;
        }
    } else if op == 23 {
        // The same read as op 13, but with the span hoisted out of the loop:
        // the difference is what the 24-field `@LevelMap` snapshot costs at
        // every accessor call site.
        let ss: Span<u32> = m.ss_sector;
        while i != n {
            acc += (*ss.at(i % 512)).into();
            i += 1;
        }
    } else if op == 99 {
        // Reference every array once, so that none is dead-code-eliminated.
        let g = genesis(LevelId::E1M1);
        acc += g.id + g.start.x.enc + g.angle.into() + g.num_things.into();
        acc += num_linedefs(@m).into() + m.id + m.root.into() + m.reject_stride.into();
        acc += *m.l_ab.at(0) + *m.l_bb.at(0) + *m.l_cb.at(0);
        acc += *m.l_box_lr.at(0) + *m.l_box_bt.at(0) + *m.l_packed.at(0);
        acc += *m.n_ab.at(0) + *m.n_bb.at(0) + *m.n_cb.at(0);
        acc += (*m.n_child0.at(0)).into() + (*m.n_child1.at(0)).into();
        acc += (*m.ss_sector.at(0)).into();
        acc += *m.s_floor.at(0) + *m.s_ceil.at(0) + *m.s_meta.at(0);
        acc += (*m.blockmap.start.at(0)).into() + (*m.blockmap.items.at(0)).into();
        acc += (*m.accel_start.at(0)).into() + *m.accel_packed.at(0);
        acc += (*m.cell_node.at(0)).into();
        acc += *m.reject.at(0) + *m.pow2.at(1) + *m.things.at(0);
        let g = doom_map::grid(@m);
        acc += g.origin_x.enc + g.origin_y.enc + g.columns.into();
    }
    acc + i.into()
}

// SPDX-License-Identifier: GPL-2.0-only
//! The "with data" side of `doom_map`'s bytecode measurement (R2-A12).
//!
//! Loads the level and reads one element of **every** generated `const`
//! array, so that none is dead-code-eliminated, and does nothing else.
//! `../baseline` is the same executable without the data; `../measure.py`
//! subtracts the two.

use doom_map::{LevelId, genesis, grid, load, num_linedefs};

#[executable]
fn main(op: u32) -> felt252 {
    let m = load(LevelId::E1M1);
    let g = genesis(LevelId::E1M1);
    let grid = grid(@m);
    let mut acc: felt252 = op.into();
    acc += g.id + g.start.x.enc + g.start.y.enc + g.angle.into() + g.num_things.into();
    acc += num_linedefs(@m).into() + m.id + m.root.into() + m.reject_stride.into();
    acc += *m.l_ab.at(0) + *m.l_bb.at(0) + *m.l_cb.at(0);
    acc += *m.l_box.at(0) + *m.l_packed.at(0);
    acc += *m.n_ab.at(0) + *m.n_bb.at(0) + *m.n_cb.at(0);
    acc += (*m.n_child0.at(0)).into() + (*m.n_child1.at(0)).into();
    acc += (*m.ss_sector.at(0)).into();
    acc += *m.s_floor.at(0) + *m.s_ceil.at(0) + *m.s_meta.at(0);
    acc += (*m.blockmap.start.at(0)).into() + (*m.blockmap.items.at(0)).into();
    acc += (*m.cell_node.at(0)).into();
    acc += *m.reject.at(0) + *m.pow2.at(1) + *m.things.at(0);
    acc += grid.origin_x.enc + grid.origin_y.enc + grid.columns.into() + grid.rows.into();
    acc
}

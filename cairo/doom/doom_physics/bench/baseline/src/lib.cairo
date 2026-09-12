// SPDX-License-Identifier: GPL-2.0-only
//! The "without physics" side of `doom_physics`'s bytecode measurement: the
//! level and the tables loaded and referenced exactly as `../size` does, and
//! no physics call — so the difference is the crate's own code.

use doom_map::{LevelId, genesis, load, thing};
use doom_physics::MAX_MOBJS;
use doom_things::tables::KIND_POSSESSED;
use doom_things::thing_info;
use prng::from_index;

#[executable]
fn main(op: u32) -> felt252 {
    let m = load(LevelId::E1M1);
    let g = genesis(LevelId::E1M1);
    let t = thing(@m, 0);
    let mut acc: felt252 = op.into();
    acc += g.start.x.enc + t.position.x.enc;
    // The same spans the physics world would hold, all touched once.
    acc += *m.l_ab.at(0) + *m.l_bb.at(0) + *m.l_cb.at(0) + *m.l_box.at(0) + *m.l_packed.at(0);
    acc += *m.n_ab.at(0) + *m.n_bb.at(0) + *m.n_cb.at(0);
    acc += (*m.n_child0.at(0)).into() + (*m.n_child1.at(0)).into() + (*m.ss_sector.at(0)).into();
    acc += *m.s_floor.at(0) + *m.s_ceil.at(0) + (*m.cell_node.at(0)).into();
    acc += (*m.blockmap.start.at(0)).into() + (*m.blockmap.items.at(0)).into();
    acc += *m.reject.at(0) + *m.pow2.at(1);
    let info = thing_info(KIND_POSSESSED);
    acc += info.radius.enc + info.spawnstate.into();
    let (rng, roll) = prng::PrngTrait::next(from_index(op), doom_things::rndtable());
    acc += roll.into() + rng.index.into();
    let (tics, action) = fsm_enter(info.spawnstate);
    acc + tics.into() + action.into() + MAX_MOBJS.into()
}

fn fsm_enter(state: u32) -> (u32, u32) {
    fsm::enter(doom_things::states(), state)
}

// SPDX-License-Identifier: GPL-2.0-only
//! The "with data" side of `doom_specials`' bytecode measurement (R2-A12).
//!
//! References one element of every generated `const` table and does nothing
//! else. `../baseline` is the same executable with the `doom_specials`
//! tables left out — `doom_map`'s own arrays are referenced by both, through
//! `doom_map::load`, so they cancel and what remains is exactly this crate's
//! contribution.

use doom_map::LevelId;
use doom_specials::level::{neighbour, neighbours, tag_sector, tag_sectors};

#[executable]
fn main(op: u32) -> felt252 {
    let m = doom_map::load(LevelId::E1M1);
    let lm = doom_specials::load(LevelId::E1M1);
    let mut acc: felt252 = op.into() + doom_map::num_sectors(@m).into();
    let (from, to) = neighbours(@lm, 0);
    acc += from.into() + to.into() + neighbour(@lm, 0).into();
    let (tfrom, tto) = tag_sectors(@lm, 1);
    acc += tfrom.into() + tto.into() + tag_sector(@lm, 0).into();
    acc += (*lm.tag_keys.at(0)).into();
    acc += (*lm.ceil_slot.at(0)).into() + (*lm.floor_slot.at(0)).into();
    acc += (*lm.light_slot.at(0)).into() + (*lm.special_slot.at(0)).into();
    acc += (*lm.ceil_sectors.at(0)).into() + (*lm.floor_sectors.at(0)).into();
    acc += (*lm.light_sectors.at(0)).into() + (*lm.special_sectors.at(0)).into();
    acc
}

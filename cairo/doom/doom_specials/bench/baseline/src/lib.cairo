// SPDX-License-Identifier: GPL-2.0-only
//! The "without data" side of `doom_specials`' bytecode measurement
//! (R2-A12).
//!
//! Same crate graph, same flags and — importantly — the **same accessor
//! code** as `../size`: it builds a `SpecialsMap` out of fourteen tiny local
//! arrays instead of `doom_specials::load`'s generated ones and calls the
//! same four accessors on it. `doom_map`'s own arrays are referenced by both
//! probes through `doom_map::load`, so they cancel too, and the difference
//! between the two compiled sizes is the generated tables plus the `span()`
//! glue of `load` — which is what `../measure.py`'s `GLUE_PER_ARRAY`
//! allowance accounts for. S1 §5.9: one word per `const` element, and
//! `2 340 + 14.7 × words` steps of bootloader program-hashing per segment.

use doom_map::LevelId;
use doom_specials::level::{SpecialsMap, neighbour, neighbours, tag_sector, tag_sectors};

#[executable]
fn main(op: u32) -> felt252 {
    let m = doom_map::load(LevelId::E1M1);
    let lm = SpecialsMap {
        adj_start: array![0_u32, 1].span(),
        adj_packed: array![1].span(),
        tag_keys: array![1_u32].span(),
        tag_start: array![0_u32, 1].span(),
        tag_packed: array![1].span(),
        ceil_slot: array![0_u32].span(),
        floor_slot: array![0_u32].span(),
        light_slot: array![0_u32].span(),
        special_slot: array![0_u32].span(),
        ceil_sectors: array![0_u32].span(),
        floor_sectors: array![0_u32].span(),
        light_sectors: array![0_u32].span(),
        special_sectors: array![0_u32].span(),
        shift8: array![
            1, 256, 65536, 16777216, 4294967296, 1099511627776, 281474976710656, 72057594037927936,
        ]
            .span(),
    };
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

// SPDX-License-Identifier: GPL-2.0-only
//! **Transitional.** The Phase-0 skeleton's three-variant `MobjType` and its
//! hand-written `info_of`, kept only because `doom_physics`, `doom_player`,
//! `doom_monsters` and `doom_game` still import
//! `doom_things::{MobjType, info_of}`.
//!
//! The real catalogue is `super::thing_info`, over the generated
//! `super::tables` columns. This module is the `doom_things` half of the D17
//! clean-up and disappears with P1.6, the PR that ports those crates onto
//! `ThingInfo`. To keep the two from drifting while both exist, the crate's
//! tests assert that each variant's health, radius and height match the
//! generated `mobjinfo` entry for the same Doom type.

use fixed::Fixed;

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub enum MobjType {
    Player,
    Zombieman,
    Imp,
}

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct MobjInfo {
    pub health: u32,
    pub speed: Fixed,
    pub radius: Fixed,
    pub height: Fixed,
    pub state_table_first: u32,
    pub state_table_len: u32,
}

/// Static, immutable catalogue entry for `kind`. Total: every `MobjType`
/// variant has an entry.
pub fn info_of(kind: MobjType) -> MobjInfo {
    match kind {
        MobjType::Player => MobjInfo {
            health: 100,
            speed: fixed::from_int(0),
            radius: fixed::from_int(16),
            height: fixed::from_int(56),
            state_table_first: 0,
            state_table_len: 4,
        },
        MobjType::Zombieman => MobjInfo {
            health: 20,
            speed: fixed::from_int(8),
            radius: fixed::from_int(20),
            height: fixed::from_int(56),
            state_table_first: 4,
            state_table_len: 6,
        },
        MobjType::Imp => MobjInfo {
            health: 60,
            speed: fixed::from_int(8),
            radius: fixed::from_int(20),
            height: fixed::from_int(56),
            state_table_first: 10,
            state_table_len: 8,
        },
    }
}

/// The generated `tables::KIND_*` index each transitional variant stands for,
/// so the tests can check the two against each other.
pub fn kind_of(kind: MobjType) -> u32 {
    match kind {
        MobjType::Player => super::tables::KIND_PLAYER,
        MobjType::Zombieman => super::tables::KIND_POSSESSED,
        MobjType::Imp => super::tables::KIND_TROOP,
    }
}

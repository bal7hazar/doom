// SPDX-License-Identifier: GPL-2.0-only
//! TRANSITIONAL — the Phase-0 skeleton's `Door`, kept because
//! `cairo/doom/doom_game` still imports it (`spawn_sample_door`). It is the
//! `doom_specials` half of D17's clean-up and disappears with the PR that
//! ports `doom_game` onto [`super::SpecialsState`]. Nothing in the real
//! code path touches it: the shipped door is [`super::Mover`], driven by
//! [`super::specials_ticker`].

use doom_map::Sector;

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub enum DoorState {
    Opening,
    Open,
    Closing,
    Closed,
}

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Door {
    pub sector: Sector,
    pub state: DoorState,
    /// Raw 16.16 fixed ceiling height the door is moving toward.
    pub target_ceiling: i64,
    /// Raw 16.16 fixed units moved per tic (always positive).
    pub speed: i64,
}

pub fn start_opening(sector: Sector, target_ceiling: i64, speed: i64) -> Door {
    Door { sector, state: DoorState::Opening, target_ceiling, speed }
}

/// Advance the door by one tic, clamping exactly at `target_ceiling`.
pub fn think_door(door: Door) -> Door {
    let ceiling = door.sector.ceiling_height;
    match door.state {
        DoorState::Opening => {
            let candidate = ceiling + door.speed;
            let done = candidate >= door.target_ceiling;
            settle(door, done, candidate, DoorState::Opening, DoorState::Open)
        },
        DoorState::Closing => {
            let candidate = ceiling - door.speed;
            let done = candidate <= door.target_ceiling;
            settle(door, done, candidate, DoorState::Closing, DoorState::Closed)
        },
        DoorState::Open => door,
        DoorState::Closed => door,
    }
}

fn settle(door: Door, done: bool, candidate: i64, moving: DoorState, settled: DoorState) -> Door {
    let ceiling = if done {
        door.target_ceiling
    } else {
        candidate
    };
    let sector = Sector {
        floor_height: door.sector.floor_height,
        ceiling_height: ceiling,
        light_level: door.sector.light_level,
    };
    Door {
        sector,
        state: if done {
            settled
        } else {
            moving
        },
        target_ceiling: door.target_ceiling,
        speed: door.speed,
    }
}

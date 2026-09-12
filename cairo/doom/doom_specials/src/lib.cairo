// SPDX-License-Identifier: GPL-2.0-only
//! **Skeleton** (rewritten in P1.9 on top of `doom_map`'s sectors): a door is
//! a moving ceiling on a sector's dynamic heights.

/// The dynamic heights of one sector, raw 16.16 fixed values (what a door or
/// a lift moves). The static per-sector data is `doom_map::MapSector`.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct SectorHeights {
    pub floor_height: i64,
    pub ceiling_height: i64,
}

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub enum DoorState {
    Opening,
    Open,
    Closing,
    Closed,
}

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Door {
    pub sector: SectorHeights,
    pub state: DoorState,
    /// Raw 16.16 fixed ceiling height the door is moving toward.
    pub target_ceiling: i64,
    /// Raw 16.16 fixed units moved per tic (always positive).
    pub speed: i64,
}

pub fn start_opening(sector: SectorHeights, target_ceiling: i64, speed: i64) -> Door {
    Door { sector, state: DoorState::Opening, target_ceiling, speed }
}

/// Advance the door by one tic, clamping exactly at `target_ceiling`.
pub fn think_door(door: Door) -> Door {
    match door.state {
        DoorState::Opening => {
            let candidate = door.sector.ceiling_height + door.speed;
            let (ceiling, state) = if candidate >= door.target_ceiling {
                (door.target_ceiling, DoorState::Open)
            } else {
                (candidate, DoorState::Opening)
            };
            Door {
                sector: SectorHeights {
                    floor_height: door.sector.floor_height, ceiling_height: ceiling,
                },
                state,
                target_ceiling: door.target_ceiling,
                speed: door.speed,
            }
        },
        DoorState::Closing => {
            let candidate = door.sector.ceiling_height - door.speed;
            let (ceiling, state) = if candidate <= door.target_ceiling {
                (door.target_ceiling, DoorState::Closed)
            } else {
                (candidate, DoorState::Closing)
            };
            Door {
                sector: SectorHeights {
                    floor_height: door.sector.floor_height, ceiling_height: ceiling,
                },
                state,
                target_ceiling: door.target_ceiling,
                speed: door.speed,
            }
        },
        DoorState::Open => door,
        DoorState::Closed => door,
    }
}

#[cfg(test)]
mod tests {
    use super::{DoorState, SectorHeights, start_opening, think_door};

    fn sector_at(ceiling: i64) -> SectorHeights {
        SectorHeights { floor_height: 0, ceiling_height: ceiling }
    }

    #[test]
    fn test_door_opens_and_snaps_to_target() {
        let mut door = start_opening(sector_at(0), 100, 30);
        door = think_door(door); // 0 -> 30
        assert(door.state == DoorState::Opening, 'still opening');
        assert(door.sector.ceiling_height == 30, 'moved by speed');
        door = think_door(door); // 30 -> 60
        door = think_door(door); // 60 -> 90
        door = think_door(door); // 90 -> would overshoot to 120, clamps to 100
        assert(door.state == DoorState::Open, 'reached open');
        assert(door.sector.ceiling_height == 100, 'clamped exactly at target');
    }

    #[test]
    fn test_open_door_is_stable() {
        let mut door = start_opening(sector_at(100), 100, 30);
        door = think_door(door);
        assert(door.state == DoorState::Open, 'reaches open immediately');
        assert(door == think_door(door), 'stable once open');
    }

    #[test]
    fn test_door_closes_and_snaps_to_target() {
        let mut door = super::Door {
            sector: sector_at(100), state: DoorState::Closing, target_ceiling: 0, speed: 40,
        };
        door = think_door(door); // 100 -> 60
        door = think_door(door); // 60 -> 20
        door = think_door(door); // 20 -> would overshoot to -20, clamps to 0
        assert(door.state == DoorState::Closed, 'reached closed');
        assert(door.sector.ceiling_height == 0, 'clamped exactly at target');
    }
}

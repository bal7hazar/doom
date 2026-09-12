// SPDX-License-Identifier: GPL-2.0-only

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
    match door.state {
        DoorState::Opening => {
            let candidate = door.sector.ceiling_height + door.speed;
            if candidate >= door.target_ceiling {
                let sector = Sector {
                    floor_height: door.sector.floor_height,
                    ceiling_height: door.target_ceiling,
                    light_level: door.sector.light_level,
                };
                Door {
                    sector,
                    state: DoorState::Open,
                    target_ceiling: door.target_ceiling,
                    speed: door.speed,
                }
            } else {
                let sector = Sector {
                    floor_height: door.sector.floor_height,
                    ceiling_height: candidate,
                    light_level: door.sector.light_level,
                };
                Door {
                    sector,
                    state: DoorState::Opening,
                    target_ceiling: door.target_ceiling,
                    speed: door.speed,
                }
            }
        },
        DoorState::Closing => {
            let candidate = door.sector.ceiling_height - door.speed;
            if candidate <= door.target_ceiling {
                let sector = Sector {
                    floor_height: door.sector.floor_height,
                    ceiling_height: door.target_ceiling,
                    light_level: door.sector.light_level,
                };
                Door {
                    sector,
                    state: DoorState::Closed,
                    target_ceiling: door.target_ceiling,
                    speed: door.speed,
                }
            } else {
                let sector = Sector {
                    floor_height: door.sector.floor_height,
                    ceiling_height: candidate,
                    light_level: door.sector.light_level,
                };
                Door {
                    sector,
                    state: DoorState::Closing,
                    target_ceiling: door.target_ceiling,
                    speed: door.speed,
                }
            }
        },
        DoorState::Open => door,
        DoorState::Closed => door,
    }
}

#[cfg(test)]
mod tests {
    use doom_map::Sector;
    use super::{DoorState, start_opening, think_door};

    fn sector_at(ceiling: i64) -> Sector {
        Sector { floor_height: 0, ceiling_height: ceiling, light_level: 200 }
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
        // Ceiling already at target: the very first tic reaches Open.
        let mut door = start_opening(sector_at(100), 100, 30);
        door = think_door(door);
        assert(door.state == DoorState::Open, 'reaches open immediately');
        // Further ticks on an open door are no-ops.
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

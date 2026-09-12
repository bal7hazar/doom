// SPDX-License-Identifier: GPL-2.0-or-later

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

#[cfg(test)]
mod tests {
    use fixed::{from_int, lt};
    use super::{MobjType, info_of};

    #[test]
    fn test_info_of_is_total() {
        // Exercise every variant: none should panic.
        let _ = info_of(MobjType::Player);
        let _ = info_of(MobjType::Zombieman);
        let _ = info_of(MobjType::Imp);
    }

    #[test]
    fn test_state_ranges_are_non_empty() {
        let kinds: Array<MobjType> = array![MobjType::Player, MobjType::Zombieman, MobjType::Imp];
        let mut i: u32 = 0;
        loop {
            if i == kinds.len() {
                break;
            }
            let info = info_of(*kinds.at(i));
            assert(info.state_table_len > 0, 'non-empty state range');
            i += 1;
        }
    }

    #[test]
    fn test_dimensions_are_non_negative() {
        let info = info_of(MobjType::Imp);
        let zero = from_int(0);
        assert(!lt(info.radius, zero), 'radius non-negative');
        assert(!lt(info.height, zero), 'height non-negative');
    }
}

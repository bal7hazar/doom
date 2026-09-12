// SPDX-License-Identifier: Apache-2.0

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct TicCmd {
    pub forward: i64,
    pub side: i64,
    pub angle_turn: i64,
    pub buttons: u8,
}

const FORWARD_OFFSET: i64 = 128;
const ANGLE_OFFSET: i64 = 32768;
const SIDE_SHIFT: u64 = 256;
const ANGLE_SHIFT: u64 = 65536;
const BUTTONS_SHIFT: u64 = 4294967296; // 2^32

/// Pack a `TicCmd` into a single `felt252`. Panics if a field is out of
/// Doom's native range rather than silently truncating.
pub fn pack(cmd: TicCmd) -> felt252 {
    assert(cmd.forward >= -128 && cmd.forward <= 127, 'ticcmd: forward oob');
    assert(cmd.side >= -128 && cmd.side <= 127, 'ticcmd: side oob');
    assert(cmd.angle_turn >= -32768 && cmd.angle_turn <= 32767, 'ticcmd: angle oob');

    let forward_off: u64 = (cmd.forward + FORWARD_OFFSET).try_into().unwrap();
    let side_off: u64 = (cmd.side + FORWARD_OFFSET).try_into().unwrap();
    let angle_off: u64 = (cmd.angle_turn + ANGLE_OFFSET).try_into().unwrap();
    let buttons_w: u64 = cmd.buttons.into();

    let packed: u64 = forward_off
        + side_off * SIDE_SHIFT
        + angle_off * ANGLE_SHIFT
        + buttons_w * BUTTONS_SHIFT;
    packed.into()
}

/// Inverse of `pack`.
pub fn unpack(packed: felt252) -> TicCmd {
    let packed_u64: u64 = packed.try_into().unwrap();
    let buttons_w: u64 = packed_u64 / BUTTONS_SHIFT;
    let rem1: u64 = packed_u64 % BUTTONS_SHIFT;
    let angle_off: u64 = rem1 / ANGLE_SHIFT;
    let rem2: u64 = rem1 % ANGLE_SHIFT;
    let side_off: u64 = rem2 / SIDE_SHIFT;
    let forward_off: u64 = rem2 % SIDE_SHIFT;

    let forward_i64: i64 = forward_off.try_into().unwrap();
    let side_i64: i64 = side_off.try_into().unwrap();
    let angle_i64: i64 = angle_off.try_into().unwrap();

    TicCmd {
        forward: forward_i64 - FORWARD_OFFSET,
        side: side_i64 - FORWARD_OFFSET,
        angle_turn: angle_i64 - ANGLE_OFFSET,
        buttons: buttons_w.try_into().unwrap(),
    }
}

#[cfg(test)]
mod tests {
    use super::{TicCmd, pack, unpack};

    #[test]
    fn test_roundtrip_zero() {
        let cmd = TicCmd { forward: 0, side: 0, angle_turn: 0, buttons: 0 };
        assert(unpack(pack(cmd)) == cmd, 'roundtrip zero');
    }

    #[test]
    fn test_roundtrip_reference_values() {
        let cmd = TicCmd { forward: 50, side: -30, angle_turn: 1200, buttons: 3 };
        assert(unpack(pack(cmd)) == cmd, 'roundtrip reference');
    }

    #[test]
    fn test_roundtrip_extremes() {
        let cmd_min = TicCmd { forward: -128, side: -128, angle_turn: -32768, buttons: 0 };
        assert(unpack(pack(cmd_min)) == cmd_min, 'roundtrip min');
        let cmd_max = TicCmd { forward: 127, side: 127, angle_turn: 32767, buttons: 255 };
        assert(unpack(pack(cmd_max)) == cmd_max, 'roundtrip max');
    }

    #[test]
    #[should_panic(expected: 'ticcmd: forward oob')]
    fn test_pack_rejects_out_of_range_forward() {
        let cmd = TicCmd { forward: 200, side: 0, angle_turn: 0, buttons: 0 };
        pack(cmd);
    }
}

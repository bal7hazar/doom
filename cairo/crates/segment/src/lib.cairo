// SPDX-License-Identifier: Apache-2.0

use state_hash::chain;
use ticcmd::{TicCmd, pack};

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct SegmentOutput {
    pub h_in: felt252,
    pub h_out: felt252,
    pub tic_start: u32,
    pub tic_end: u32,
}

/// Chain a batch of commands onto `h_in`, producing `h_out`. Chaining zero
/// commands is a strict identity on the hash.
pub fn chain_commands(h_in: felt252, tic_start: u32, cmds: Span<TicCmd>) -> SegmentOutput {
    if cmds.len() == 0 {
        return SegmentOutput { h_in, h_out: h_in, tic_start, tic_end: tic_start };
    }

    let mut packed: Array<felt252> = array![];
    let mut i: u32 = 0;
    loop {
        if i == cmds.len() {
            break;
        }
        packed.append(pack(*cmds.at(i)));
        i += 1;
    }

    let h_out = chain(h_in, packed.span());
    SegmentOutput { h_in, h_out, tic_start, tic_end: tic_start + cmds.len() }
}

#[cfg(test)]
mod tests {
    use ticcmd::TicCmd;
    use super::chain_commands;

    fn cmd(forward: i64) -> TicCmd {
        TicCmd { forward, side: 0, angle_turn: 0, buttons: 0 }
    }

    #[test]
    fn test_empty_batch_is_identity() {
        let out = chain_commands(42, 0, array![].span());
        assert(out.h_in == 42, 'h_in preserved');
        assert(out.h_out == 42, 'h_out equals h_in on empty');
        assert(out.tic_start == out.tic_end, 'no tics elapsed');
    }

    #[test]
    fn test_tic_bounds_match_command_count() {
        let cmds: Array<TicCmd> = array![cmd(1), cmd(2), cmd(3)];
        let out = chain_commands(0, 10, cmds.span());
        assert(out.tic_start == 10, 'tic_start preserved');
        assert(out.tic_end == 13, 'tic_end advances by len');
    }

    #[test]
    fn test_deterministic_and_order_sensitive() {
        let cmds_a: Array<TicCmd> = array![cmd(1), cmd(2)];
        let cmds_b: Array<TicCmd> = array![cmd(2), cmd(1)];
        let out_a1 = chain_commands(0, 0, cmds_a.span());
        let out_a2 = chain_commands(0, 0, cmds_a.span());
        let out_b = chain_commands(0, 0, cmds_b.span());
        assert(out_a1.h_out == out_a2.h_out, 'deterministic');
        assert(out_a1.h_out != out_b.h_out, 'order sensitive');
    }

    #[test]
    fn test_different_h_in_gives_different_h_out() {
        let cmds: Array<TicCmd> = array![cmd(1)];
        let out_1 = chain_commands(1, 0, cmds.span());
        let out_2 = chain_commands(2, 0, cmds.span());
        assert(out_1.h_out != out_2.h_out, 'depends on h_in');
    }
}

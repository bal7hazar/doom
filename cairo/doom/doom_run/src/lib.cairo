// SPDX-License-Identifier: GPL-2.0-only

use doom_game::{genesis, step_tic};
use ticcmd::TicCmd;

/// Run `x` no-op tics from genesis and return the final tic count.
/// Factored out of `main` so it can be unit-tested with `cairo_test`
/// (the `#[executable]` attribute below is the provable entry point).
pub fn run(x: u32) -> u32 {
    let mut state = genesis();
    let cmd = TicCmd { forward: 0, side: 0, angle_turn: 0, buttons: 0 };
    let mut i: u32 = 0;
    loop {
        if i == x {
            break;
        }
        state = step_tic(state, cmd);
        i += 1;
    }
    state.tic
}

#[executable]
fn main(x: u32) -> u32 {
    run(x)
}

#[cfg(test)]
mod tests {
    use super::run;

    #[test]
    fn test_run_zero_tics_stays_at_zero() {
        assert(run(0) == 0, 'zero tics');
    }

    #[test]
    fn test_run_returns_exact_tic_count() {
        assert(run(5) == 5, 'five tics');
    }
}

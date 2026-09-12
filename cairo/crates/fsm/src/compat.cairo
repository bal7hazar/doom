// SPDX-License-Identifier: Apache-2.0

//! TRANSITIONAL compatibility layer -- delete with P1.5.
//!
//! The Phase-0 skeleton shipped a two-field `StateDef { duration, next }`
//! and a `Timer { state, remaining }`. `cairo/doom/doom_monsters` and
//! `cairo/doom/doom_game` still use them; until those crates move to the
//! planar [`super::StateTables`] API they are kept here so the workspace
//! keeps building. They are not part of the crate's intended API: a Doom
//! state needs five columns (sprite, frame, tics, action, next), not two,
//! and the tables must be planar to stay cheap to read (S1 §5.3).

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct StateDef {
    pub duration: u32,
    pub next: u32,
}

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Timer {
    pub state: u32,
    pub remaining: u32,
}

/// Load a timer for `state`, with `remaining` set to its table duration.
pub fn start(states: Span<StateDef>, state: u32) -> Timer {
    let def = *states.at(state);
    Timer { state, remaining: def.duration }
}

/// Advance the timer by one tic. A `duration == 0` state is static and
/// never advances.
pub fn tick(states: Span<StateDef>, timer: Timer) -> Timer {
    if timer.remaining == 0 {
        return timer;
    }
    let remaining = timer.remaining - 1;
    if remaining == 0 {
        let def = *states.at(timer.state);
        start(states, def.next)
    } else {
        Timer { state: timer.state, remaining }
    }
}

#[cfg(test)]
mod tests {
    use super::{StateDef, start, tick};

    fn sample_states() -> Array<StateDef> {
        // 0 -> (duration 2) -> 1 -> (duration 1) -> 2 -> (static) -> 2
        let mut states = array![];
        states.append(StateDef { duration: 2, next: 1 });
        states.append(StateDef { duration: 1, next: 2 });
        states.append(StateDef { duration: 0, next: 0 });
        states
    }

    #[test]
    fn test_start_loads_duration() {
        let states = sample_states();
        let timer = start(states.span(), 0);
        assert(timer.state == 0, 'starts at state 0');
        assert(timer.remaining == 2, 'loads duration');
    }

    #[test]
    fn test_tick_counts_down_then_transitions() {
        let states = sample_states();
        let mut timer = start(states.span(), 0);
        timer = tick(states.span(), timer);
        assert(timer.state == 0, 'still state 0');
        assert(timer.remaining == 1, 'counted down');
        timer = tick(states.span(), timer);
        assert(timer.state == 1, 'transitioned to state 1');
        assert(timer.remaining == 1, 'loaded next duration');
    }

    #[test]
    fn test_static_state_never_advances() {
        let states = sample_states();
        let mut timer = start(states.span(), 2);
        assert(timer.remaining == 0, 'static state has duration 0');
        let mut i: u32 = 0;
        while i != 10 {
            timer = tick(states.span(), timer);
            i += 1;
        }
        assert(timer.state == 2, 'never left the static state');
    }

    #[test]
    fn test_full_chain_reaches_next_after_duration_ticks() {
        let states = sample_states();
        let mut timer = start(states.span(), 0);
        // duration(0) == 2: exactly 2 ticks reach state 1.
        timer = tick(states.span(), timer);
        timer = tick(states.span(), timer);
        assert(timer.state == 1, 'reached state 1 on time');
    }
}

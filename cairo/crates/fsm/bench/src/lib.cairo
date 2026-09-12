// SPDX-License-Identifier: Apache-2.0

//! Step-budget harness for `fsm` (method: see `bench/README.md`).
//!
//! Differential measurement, one loop per operation:
//!   cost(op) = (steps(op, 2N) - steps(op, N)) / N, minus the bare loop.
//!
//! Every loop threads the machine's own state through the iterations, so
//! nothing is loop-invariant and nothing can be hoisted out.
//!
//! Two cases are measured separately because they cost very differently:
//! *counting down* (no table read, the common case for a mobj that is
//! mid-animation) and *transitioning* (three column reads).

use fsm::{FOREVER, NO_ACTION, StateTables, advance, enter, row};

/// One state, a very long `tics`: every advance counts down.
fn counting_tables(
    sprite: @Array<u32>,
    frame: @Array<u32>,
    tics: @Array<u32>,
    action: @Array<u32>,
    next: @Array<u32>,
) -> StateTables {
    StateTables {
        sprite: sprite.span(),
        frame: frame.span(),
        tics: tics.span(),
        action_id: action.span(),
        next_state: next.span(),
    }
}

fn bare(n: u32) -> felt252 {
    let mut acc: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        acc = acc + 1;
        i += 1;
    }
    acc.into()
}

fn advance_loop(tables: StateTables, state_id: u32, tics_left: u32, n: u32) -> felt252 {
    let mut state = state_id;
    let mut left = tics_left;
    let mut acc: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        let (s, t, action) = advance(tables, state, left);
        state = s;
        left = t;
        acc = acc + action;
        i += 1;
    }
    acc.into() + state.into() + left.into()
}

fn enter_loop(tables: StateTables, n: u32) -> felt252 {
    let mut acc: u32 = 0;
    let mut state: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        let (_, action) = enter(tables, state);
        acc = acc + action;
        state = if state == 3 {
            0
        } else {
            state + 1
        };
        i += 1;
    }
    acc.into() + state.into()
}

fn row_loop(tables: StateTables, n: u32) -> felt252 {
    let mut acc: u32 = 0;
    let mut state: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        acc = acc
            + match row(tables, state) {
                Option::Some(r) => r.sprite + r.frame + r.action_id,
                Option::None => 0,
            };
        state = if state == 3 {
            0
        } else {
            state + 1
        };
        i += 1;
    }
    acc.into() + state.into()
}

/// Diagnostic: a call with exactly `advance`'s signature that does
/// nothing. Isolates the cost of passing `StateTables` by value.
fn noop(tables: StateTables, state_id: u32, tics_left: u32) -> (u32, u32, u32) {
    if tics_left == 7 {
        (tables.sprite.len(), tics_left, 0)
    } else {
        (state_id, tics_left, 0)
    }
}

fn noop_loop(tables: StateTables, n: u32) -> felt252 {
    let mut state: u32 = 1;
    let mut left: u32 = 4_000_000;
    let mut acc: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        let (s, t, a) = noop(tables, state, left);
        state = s;
        left = t - 1;
        acc = acc + a;
        i += 1;
    }
    acc.into() + state.into() + left.into()
}

/// Baseline for `enter` and `row`, whose loops carry a 4-state cursor the
/// bare loop does not have.
fn cursor_loop(n: u32) -> felt252 {
    let mut acc: u32 = 0;
    let mut state: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        acc = acc + 1;
        state = if state == 3 {
            0
        } else {
            state + 1
        };
        i += 1;
    }
    acc.into() + state.into()
}

/// Diagnostic: `advance`'s counting-down branch written inline, so the
/// measurement excludes the call and the `StateTables` copy.
fn inline_countdown_loop(n: u32) -> felt252 {
    let mut state: u32 = 1;
    let mut left: u32 = 4_000_000;
    let mut acc: u32 = 0;
    let mut i: u32 = 0;
    while i != n {
        let (s, t, a) = if left > 1 {
            if left == FOREVER {
                (state, FOREVER, NO_ACTION)
            } else {
                (state, left - 1, NO_ACTION)
            }
        } else {
            (state, FOREVER, NO_ACTION)
        };
        state = s;
        left = t;
        acc = acc + a;
        i += 1;
    }
    acc.into() + state.into() + left.into()
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    // Machine A: one state, `tics` large enough that every advance in the
    // measured run counts down.
    let a_sprite: Array<u32> = array![0, 1];
    let a_frame: Array<u32> = array![0, 0];
    let a_tics: Array<u32> = array![FOREVER, 4_000_000];
    let a_action: Array<u32> = array![NO_ACTION, 5];
    let a_next: Array<u32> = array![0, 1];
    let machine_a = counting_tables(@a_sprite, @a_frame, @a_tics, @a_action, @a_next);

    // Machine B: every state lasts one tic, so every advance transitions.
    let b_sprite: Array<u32> = array![0, 1, 1, 1];
    let b_frame: Array<u32> = array![0, 0, 1, 2];
    let b_tics: Array<u32> = array![FOREVER, 1, 1, 1];
    let b_action: Array<u32> = array![NO_ACTION, 11, 12, 13];
    let b_next: Array<u32> = array![0, 2, 3, 1];
    let machine_b = counting_tables(@b_sprite, @b_frame, @b_tics, @b_action, @b_next);

    // Machine C: a realistic Doom-like cycle -- 4, 4 and 6 tics, so one
    // advance in five transitions.
    let c_sprite: Array<u32> = array![0, 1, 1, 1];
    let c_frame: Array<u32> = array![0, 0, 1, 2];
    let c_tics: Array<u32> = array![FOREVER, 4, 4, 6];
    let c_action: Array<u32> = array![NO_ACTION, 11, 12, 13];
    let c_next: Array<u32> = array![0, 2, 3, 1];
    let machine_c = counting_tables(@c_sprite, @c_frame, @c_tics, @c_action, @c_next);

    if op == 1 {
        advance_loop(machine_a, 1, 4_000_000, n)
    } else if op == 2 {
        advance_loop(machine_b, 1, 1, n)
    } else if op == 3 {
        advance_loop(machine_c, 1, 4, n)
    } else if op == 4 {
        advance_loop(machine_a, 0, FOREVER, n)
    } else if op == 5 {
        enter_loop(machine_b, n)
    } else if op == 6 {
        row_loop(machine_b, n)
    } else if op == 7 {
        noop_loop(machine_a, n)
    } else if op == 8 {
        inline_countdown_loop(n)
    } else if op == 9 {
        cursor_loop(n)
    } else {
        bare(n)
    }
}

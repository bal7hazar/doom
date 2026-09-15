// SPDX-License-Identifier: Apache-2.0

//! Generic animation/behaviour state machine, shaped like Doom's
//! `info.c` state table.
//!
//! A state is five numbers — `sprite`, `frame`, `tics`, `action_id`,
//! `next_state` — and a machine is a table of them, **supplied by the
//! caller** as five parallel `Span<u32>` columns ([`StateTables`]). One
//! `const` array per column is the representation S1 §5.3 measured as the
//! cheapest for hot data: reading one field costs 11 steps against 106 for
//! a packed record.
//!
//! ```text
//!   advance(tables, state_id, tics_left)
//!       tics_left == FOREVER  ->  stay in this state for ever
//!       tics_left <= 1        ->  enter next_state[state_id], run its action
//!       otherwise             ->  stay, tics_left - 1, no action
//! ```
//!
//! This is Doom's `P_MobjThinker`/`P_SetMobjState` pair, minus two things
//! this crate cannot have:
//!
//! * **Actions are ids, not calls.** Cairo has no function pointers, and a
//!   generic crate must not know what `A_Chase` is; `advance` returns the
//!   `action_id` of the state just entered and the caller dispatches on it.
//!   Id [`NO_ACTION`] (0) means "nothing to run", so row 0 of the
//!   `action_id` column is reserved.
//! * **Zero-tic chaining is one call per link.** Doom's `P_SetMobjState`
//!   loops while the state it enters has `tics == 0`; here, entering such a
//!   state leaves `tics_left == 0`, and the caller decides how far to
//!   chain (`while tics_left == 0 { advance(...) }` with its own bound).
//!   That keeps `advance` free of an unbounded loop, which a proving path
//!   must not contain.

/// `tics` value of a state that never advances on its own — Doom's
/// `tics == -1` (`S_NULL`, idle sprites, corpses).
///
/// It is `0xFFFF_FFFF` rather than `0` because `0` is a legitimate Doom
/// `tics` value (a state that chains immediately, e.g. `S_LIGHTDONE`), and
/// conflating the two would silently turn those states into permanent ones.
pub const FOREVER: u32 = 0xFFFF_FFFF;

/// Action id meaning "no action on entering this state".
pub const NO_ACTION: u32 = 0;

/// The five columns of a state table. Each column is indexed by state id
/// and all five must have the same length ([`validate`]).
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct StateTables {
    pub sprite: Span<u32>,
    pub frame: Span<u32>,
    pub tics: Span<u32>,
    pub action_id: Span<u32>,
    pub next_state: Span<u32>,
}

/// One row of a state table, in record form. The planar columns are what
/// the hot path reads; this is for table construction and tests.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct StateRow {
    pub sprite: u32,
    pub frame: u32,
    pub tics: u32,
    pub action_id: u32,
    pub next_state: u32,
}

/// Number of states in the table.
///
/// Reads a single column: [`validate`] is what guarantees the other four
/// have the same length, and taking the minimum of five lengths on every
/// call cost ~40 steps for nothing — with it, a transition through
/// `advance` measured 195 steps instead of 101.
#[inline(always)]
pub fn len(tables: StateTables) -> u32 {
    tables.sprite.len()
}

/// True when the table is well formed: all five columns have the same
/// length, the table is not empty, every `next_state` is a valid state id,
/// and state 0's action is [`NO_ACTION`].
///
/// Callers check this once (at genesis, or in a test) and the hot path then
/// assumes it — that is what lets [`advance`] read its columns with `at`.
pub fn validate(tables: StateTables) -> bool {
    let count = tables.sprite.len();
    if count == 0 {
        return false;
    }
    if tables.frame.len() != count
        || tables.tics.len() != count
        || tables.action_id.len() != count
        || tables.next_state.len() != count {
        return false;
    }
    if *tables.action_id.at(0) != NO_ACTION {
        return false;
    }
    let mut ok = true;
    let mut i: u32 = 0;
    while i != count {
        if *tables.next_state.at(i) >= count {
            ok = false;
            break;
        }
        i += 1;
    }
    ok
}

/// The row for `state_id`, or `None` when the id is out of range. Total
/// function.
pub fn row(tables: StateTables, state_id: u32) -> Option<StateRow> {
    if state_id >= len(tables) {
        return Option::None;
    }
    Option::Some(
        StateRow {
            sprite: *tables.sprite.at(state_id),
            frame: *tables.frame.at(state_id),
            tics: *tables.tics.at(state_id),
            action_id: *tables.action_id.at(state_id),
            next_state: *tables.next_state.at(state_id),
        },
    )
}

/// What to draw for `state_id`: `(sprite, frame)`. Out-of-range ids yield
/// `(0, 0)`.
pub fn appearance(tables: StateTables, state_id: u32) -> (u32, u32) {
    match row(tables, state_id) {
        Option::Some(state) => (state.sprite, state.frame),
        Option::None => (0, 0),
    }
}

/// Enter `state_id`: the `tics_left` to start counting from and the action
/// to run now. Doom's `P_SetMobjState`, without the zero-tic loop.
///
/// An out-of-range id yields `(FOREVER, NO_ACTION)`, i.e. a state machine
/// that has stopped — never a trap (R4-A2).
#[inline(always)]
pub fn enter(tables: StateTables, state_id: u32) -> (u32, u32) {
    if state_id >= tables.tics.len() {
        return (FOREVER, NO_ACTION);
    }
    (*tables.tics.at(state_id), *tables.action_id.at(state_id))
}

/// One tic of the machine.
///
/// Returns `(new_state_id, tics_left, action_id)`. `action_id` is
/// [`NO_ACTION`] unless this call entered a new state, in which case it is
/// that state's action and must be run by the caller.
///
/// Total function: an out-of-range `state_id` parks the machine on itself
/// with `FOREVER`.
///
/// `#[inline(always)]` is deliberate and measured. A normal call costs 43
/// steps here — with five `Span`s in and three `u32`s out, the argument and
/// return plumbing dwarfs the body — so inlining takes the common
/// counting-down case from 62 steps to 19 and a realistic animation cycle
/// from 86 to 30. The price is ~54 bytecode words per call site (S1 §5.9),
/// which the handful of call sites in `doom_things`/`doom_monsters` can
/// afford; if that ever stops being true, the fix is to call `advance` from
/// exactly one place rather than to drop the attribute.
#[inline(always)]
pub fn advance(tables: StateTables, state_id: u32, tics_left: u32) -> (u32, u32, u32) {
    // One ordered comparison sorts the three cases, because `FOREVER` is
    // the largest `u32`: `tics_left > 1` covers both "still counting" and
    // "for ever", and its complement (0 or 1) is exactly the transition.
    // An integer comparison costs ~10 steps in Cairo (S1 §5.1) whether it
    // is `==` or `>`: what matters is how many run, not which kind. The
    // three-equality-test version this replaced measured 64 steps against
    // 62 on the counting-down path -- a small win, and a reminder that
    // `==` on a `u32` is not the cheap felt comparison one might expect.
    if tics_left > 1 {
        if tics_left == FOREVER {
            return (state_id, FOREVER, NO_ACTION);
        }
        return (state_id, tics_left - 1, NO_ACTION);
    }
    if state_id >= tables.next_state.len() {
        return (state_id, FOREVER, NO_ACTION);
    }
    // `next` comes from a table `validate` has checked, so it is a valid
    // state id and the two reads below cannot trap. `state_id` is runtime
    // data and is checked above.
    let next = *tables.next_state.at(state_id);
    (next, *tables.tics.at(next), *tables.action_id.at(next))
}

#[cfg(test)]
mod tests {
    use super::{
        FOREVER, NO_ACTION, StateRow, StateTables, advance, appearance, enter, len, row, validate,
    };

    /// A four-state machine covering every shape:
    ///
    /// | id | sprite | frame | tics    | action | next |
    /// |----|--------|-------|---------|--------|------|
    /// | 0  | 0      | 0     | FOREVER | none   | 0    |  the null state
    /// | 1  | 7      | 0     | 3       | 11     | 2    |  normal
    /// | 2  | 7      | 1     | 1       | 12     | 3    |  one tic
    /// | 3  | 7      | 2     | 0       | 13     | 1    |  zero tics, chains
    fn tables_backing() -> (Array<u32>, Array<u32>, Array<u32>, Array<u32>, Array<u32>) {
        (
            array![0, 7, 7, 7],
            array![0, 0, 1, 2],
            array![FOREVER, 3, 1, 0],
            array![NO_ACTION, 11, 12, 13],
            array![0, 2, 3, 1],
        )
    }

    #[test]
    fn test_validate_accepts_a_well_formed_table() {
        let (sprite, frame, tics, action_id, next_state) = tables_backing();
        let tables = StateTables {
            sprite: sprite.span(),
            frame: frame.span(),
            tics: tics.span(),
            action_id: action_id.span(),
            next_state: next_state.span(),
        };
        assert(validate(tables), 'sample table is valid');
        assert(len(tables) == 4, 'four states');
    }

    #[test]
    fn test_validate_rejects_malformed_tables() {
        let (sprite, frame, tics, action_id, next_state) = tables_backing();
        let empty: Array<u32> = array![];
        let short: Array<u32> = array![0, 0, 0];
        let out_of_range: Array<u32> = array![0, 2, 3, 99];
        let acting_null: Array<u32> = array![5, 11, 12, 13];
        let base = StateTables {
            sprite: sprite.span(),
            frame: frame.span(),
            tics: tics.span(),
            action_id: action_id.span(),
            next_state: next_state.span(),
        };
        let mut broken = base;
        broken.sprite = empty.span();
        assert(!validate(broken), 'empty table rejected');
        let mut broken = base;
        broken.frame = short.span();
        assert(!validate(broken), 'ragged frame column');
        let mut broken = base;
        broken.tics = short.span();
        assert(!validate(broken), 'ragged tics column');
        let mut broken = base;
        broken.action_id = short.span();
        assert(!validate(broken), 'ragged action column');
        let mut broken = base;
        broken.next_state = short.span();
        assert(!validate(broken), 'ragged next column');
        let mut broken = base;
        broken.next_state = out_of_range.span();
        assert(!validate(broken), 'next out of range');
        let mut broken = base;
        broken.action_id = acting_null.span();
        assert(!validate(broken), 'state 0 must not act');
    }

    #[test]
    fn test_len_reads_one_column_and_validate_guards_it() {
        let (sprite, _frame, tics, action_id, next_state) = tables_backing();
        let short: Array<u32> = array![0, 0];
        let tables = StateTables {
            sprite: sprite.span(),
            frame: short.span(),
            tics: tics.span(),
            action_id: action_id.span(),
            next_state: next_state.span(),
        };
        assert(len(tables) == 4, 'len reads the sprite column');
        assert(!validate(tables), 'a ragged table is invalid');
    }

    #[test]
    fn test_row_and_appearance() {
        let (sprite, frame, tics, action_id, next_state) = tables_backing();
        let tables = StateTables {
            sprite: sprite.span(),
            frame: frame.span(),
            tics: tics.span(),
            action_id: action_id.span(),
            next_state: next_state.span(),
        };
        let expected = StateRow { sprite: 7, frame: 1, tics: 1, action_id: 12, next_state: 3 };
        assert(row(tables, 2) == Option::Some(expected), 'row 2');
        assert(row(tables, 4) == Option::None, 'past the end');
        assert(appearance(tables, 3) == (7, 2), 'sprite and frame');
        assert(appearance(tables, 99) == (0, 0), 'out of range appearance');
    }

    #[test]
    fn test_enter_loads_tics_and_action() {
        let (sprite, frame, tics, action_id, next_state) = tables_backing();
        let tables = StateTables {
            sprite: sprite.span(),
            frame: frame.span(),
            tics: tics.span(),
            action_id: action_id.span(),
            next_state: next_state.span(),
        };
        assert(enter(tables, 1) == (3, 11), 'state 1');
        assert(enter(tables, 0) == (FOREVER, NO_ACTION), 'null state');
        assert(enter(tables, 42) == (FOREVER, NO_ACTION), 'out of range parks');
    }

    #[test]
    fn test_forever_state_never_advances() {
        let (sprite, frame, tics, action_id, next_state) = tables_backing();
        let tables = StateTables {
            sprite: sprite.span(),
            frame: frame.span(),
            tics: tics.span(),
            action_id: action_id.span(),
            next_state: next_state.span(),
        };
        let mut state: u32 = 0;
        let mut left = FOREVER;
        let mut i: u32 = 0;
        while i != 20 {
            let (s, t, action) = advance(tables, state, left);
            assert(action == NO_ACTION, 'forever runs no action');
            state = s;
            left = t;
            i += 1;
        }
        assert(state == 0 && left == FOREVER, 'stayed for ever');
    }

    /// Property: a state whose `tics` is `n >= 1` transitions on exactly
    /// the n-th advance, like Doom's `tics--; if (!tics) SetState(next)`.
    #[test]
    fn test_transition_happens_on_the_nth_advance() {
        let sprite: Array<u32> = array![0, 1];
        let frame: Array<u32> = array![0, 0];
        let action_id: Array<u32> = array![NO_ACTION, 5];
        let next_state: Array<u32> = array![0, 0];
        let mut n: u32 = 1;
        while n != 12 {
            let tics: Array<u32> = array![FOREVER, n];
            let tables = StateTables {
                sprite: sprite.span(),
                frame: frame.span(),
                tics: tics.span(),
                action_id: action_id.span(),
                next_state: next_state.span(),
            };
            let (mut left, _) = enter(tables, 1);
            let mut state: u32 = 1;
            let mut i: u32 = 0;
            while i != n {
                let (s, t, _) = advance(tables, state, left);
                state = s;
                left = t;
                i += 1;
            }
            assert(state == 0, 'left the state on time');
            n += 1;
        }
    }

    #[test]
    fn test_transition_runs_the_action_of_the_state_entered() {
        let (sprite, frame, tics, action_id, next_state) = tables_backing();
        let tables = StateTables {
            sprite: sprite.span(),
            frame: frame.span(),
            tics: tics.span(),
            action_id: action_id.span(),
            next_state: next_state.span(),
        };
        // State 1 has tics 3 and goes to state 2 (action 12).
        let (left, action) = enter(tables, 1);
        assert(action == 11, 'entering runs its own action');
        let (state, left, action) = advance(tables, 1, left);
        assert(state == 1 && left == 2 && action == NO_ACTION, 'first tic counts down');
        let (state, left, action) = advance(tables, state, left);
        assert(state == 1 && left == 1 && action == NO_ACTION, 'second tic counts down');
        let (state, left, action) = advance(tables, state, left);
        assert(state == 2, 'third tic transitions');
        assert(left == 1, 'loaded the new tics');
        assert(action == 12, 'ran the new action');
    }

    #[test]
    fn test_zero_tic_state_chains_on_the_next_call() {
        let (sprite, frame, tics, action_id, next_state) = tables_backing();
        let tables = StateTables {
            sprite: sprite.span(),
            frame: frame.span(),
            tics: tics.span(),
            action_id: action_id.span(),
            next_state: next_state.span(),
        };
        // State 2 has tics 1 -> one advance enters state 3, which has
        // tics 0 and therefore chains to state 1 on the following call.
        let (state, left, _) = advance(tables, 2, 1);
        assert(state == 3 && left == 0, 'entered the zero-tic state');
        let (state, left, action) = advance(tables, state, left);
        assert(state == 1, 'chained immediately');
        assert(left == 3 && action == 11, 'loaded state 1');
    }

    #[test]
    fn test_cycle_returns_to_its_start() {
        let (sprite, frame, tics, action_id, next_state) = tables_backing();
        let tables = StateTables {
            sprite: sprite.span(),
            frame: frame.span(),
            tics: tics.span(),
            action_id: action_id.span(),
            next_state: next_state.span(),
        };
        // 1 --3 tics--> 2 --1 tic--> 3 --0 tics--> 1: five advances.
        let (mut left, _) = enter(tables, 1);
        let mut state: u32 = 1;
        let mut i: u32 = 0;
        while i != 5 {
            let (s, t, _) = advance(tables, state, left);
            state = s;
            left = t;
            i += 1;
        }
        assert(state == 1, 'back to the start of the cycle');
        assert(left == 3, 'with its tics reloaded');
    }

    #[test]
    fn test_out_of_range_state_parks_instead_of_trapping() {
        let (sprite, frame, tics, action_id, next_state) = tables_backing();
        let tables = StateTables {
            sprite: sprite.span(),
            frame: frame.span(),
            tics: tics.span(),
            action_id: action_id.span(),
            next_state: next_state.span(),
        };
        let (state, left, action) = advance(tables, 99, 1);
        assert(state == 99 && left == FOREVER, 'parked');
        assert(action == NO_ACTION, 'no action');
        let (state, left, _) = advance(tables, 99, 5);
        assert(state == 99 && left == 4, 'counting down skips the table');
    }

    #[test]
    fn test_advance_is_deterministic() {
        let (sprite, frame, tics, action_id, next_state) = tables_backing();
        let tables = StateTables {
            sprite: sprite.span(),
            frame: frame.span(),
            tics: tics.span(),
            action_id: action_id.span(),
            next_state: next_state.span(),
        };
        assert(advance(tables, 1, 3) == advance(tables, 1, 3), 'pure function');
        assert(advance(tables, 2, 1) == advance(tables, 2, 1), 'pure on transitions');
    }

    #[test]
    fn test_state_values_stay_small() {
        // A7: nothing this crate produces approaches 2^72.
        let (sprite, frame, tics, action_id, next_state) = tables_backing();
        let tables = StateTables {
            sprite: sprite.span(),
            frame: frame.span(),
            tics: tics.span(),
            action_id: action_id.span(),
            next_state: next_state.span(),
        };
        let (state, left, action) = advance(tables, 1, 3);
        let as_felt: felt252 = state.into() + left.into() + action.into();
        let as_u128: u128 = as_felt.try_into().unwrap();
        assert(as_u128 < 0x1000000000000000000, 'below 2^72');
    }
}

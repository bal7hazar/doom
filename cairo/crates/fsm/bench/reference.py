#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent reference implementation of `fsm`, used to produce the
traces asserted in `src/lib.cairo`'s test module and to check the Doom
semantics the crate claims.

The reference is written from Doom's own rule
(`tics--; if (!tics) P_SetMobjState(next)`) rather than from the Cairo
source, so that agreeing with it is evidence and not a tautology.

Run: `python3 reference.py`
"""

FOREVER = 0xFFFFFFFF
NO_ACTION = 0

# The four-state machine of the Cairo tests.
#            id: (sprite, frame, tics,    action,    next)
SAMPLE = {
    0: (0, 0, FOREVER, NO_ACTION, 0),   # the null state
    1: (7, 0, 3, 11, 2),                # normal
    2: (7, 1, 1, 12, 3),                # one tic
    3: (7, 2, 0, 13, 1),                # zero tics, chains
}


def enter(tables, state_id):
    if state_id not in tables:
        return FOREVER, NO_ACTION
    _, _, tics, action, _ = tables[state_id]
    return tics, action


def advance(tables, state_id, tics_left):
    if tics_left > 1:
        if tics_left == FOREVER:
            return state_id, FOREVER, NO_ACTION
        return state_id, tics_left - 1, NO_ACTION
    if state_id not in tables:
        return state_id, FOREVER, NO_ACTION
    nxt = tables[state_id][4]
    tics, action = enter(tables, nxt)
    return nxt, tics, action


def doom_reference(n: int) -> int:
    """Doom's own loop: how many `advance` calls a state with `tics = n`
    survives before leaving. `tics--; if (!tics) SetState(next)` leaves
    after exactly n calls."""
    tics = n
    calls = 0
    while True:
        calls += 1
        tics -= 1
        if tics == 0:
            return calls


def main() -> None:
    # The crate's advance must agree with Doom's decrement-then-test for
    # every positive `tics`.
    for n in range(1, 64):
        tables = {0: (0, 0, FOREVER, NO_ACTION, 0), 1: (1, 0, n, 5, 0)}
        state, left = 1, n
        calls = 0
        while state == 1:
            state, left, _ = advance(tables, state, left)
            calls += 1
        assert calls == doom_reference(n) == n, (n, calls)
    print("advance matches Doom's `tics--; if (!tics) SetState(next)` for tics = 1..63")

    # Trace of the sample machine, the one the Cairo tests walk.
    state, left = 1, SAMPLE[1][2]
    trace = []
    for _ in range(6):
        state, left, action = advance(SAMPLE, state, left)
        trace.append((state, left, action))
    print("sample machine trace from state 1:")
    for i, (s, t, a) in enumerate(trace):
        print(f"  advance {i + 1}: state={s} tics_left={t} action={a}")
    assert trace[:5] == [
        (1, 2, 0), (1, 1, 0), (2, 1, 12), (3, 0, 13), (1, 3, 11),
    ], trace
    print("cycle length from state 1 back to state 1: 5 advances")

    # A FOREVER state is a fixed point.
    for _ in range(100):
        assert advance(SAMPLE, 0, FOREVER) == (0, FOREVER, NO_ACTION)
    print("FOREVER is a fixed point")

    # Out-of-range ids park instead of raising.
    assert advance(SAMPLE, 99, 1) == (99, FOREVER, NO_ACTION)
    assert advance(SAMPLE, 99, 5) == (99, 4, NO_ACTION)
    assert enter(SAMPLE, 99) == (FOREVER, NO_ACTION)
    print("out-of-range ids park")


if __name__ == "__main__":
    main()

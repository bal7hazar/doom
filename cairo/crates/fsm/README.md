# fsm

**Does**: runs Doom-shaped state machines — the `info.c` state table — for
any game. A state is five numbers (`sprite`, `frame`, `tics`, `action_id`,
`next_state`) and a machine is a table of them, supplied by the caller as
**five parallel `Span<u32>` columns** (`StateTables`). `advance(tables,
state_id, tics_left) -> (state_id, tics_left, action_id)` is one tic of
Doom's `P_MobjThinker`; `enter` is `P_SetMobjState`; `row` and `appearance`
read a state out for rendering or serialization; `validate` checks a table
once so the hot path does not have to.

**Does not**: call anything. Cairo has no function pointers, and a generic
crate must not know what `A_Chase` is, so `advance` returns the
**`action_id`** of the state it entered and the caller dispatches on it
(`NO_ACTION = 0` means "nothing to run", which reserves row 0 of the
`action_id` column). It does not own the table, does not know what a sprite
is, and contains no Doom data — `doom_things` owns the generated tables.

## Semantics

```text
advance(tables, state_id, tics_left)
    tics_left == FOREVER   ->  (state_id, FOREVER, NO_ACTION)     stays put
    tics_left  > 1         ->  (state_id, tics_left - 1, NO_ACTION)
    tics_left <= 1         ->  next = next_state[state_id];
                               (next, tics[next], action_id[next])
```

This matches Doom's `tics--; if (!tics) P_SetMobjState(next)` exactly: a
state whose `tics` is `n ≥ 1` leaves on the n-th advance, verified for
n = 1..63 against an independent model in `bench/reference.py`.

Two encodings deserve their names:

- **`FOREVER = 0xFFFF_FFFF`**, Doom's `tics == -1`. It is not `0`, because
  `0` is a legitimate Doom `tics` value (`S_LIGHTDONE` and friends chain
  immediately) and conflating the two would silently freeze those states.
  Being the *largest* `u32` is also what lets one `tics_left > 1` test sort
  all three cases.
- **Zero-tic states chain one call at a time.** Doom's `P_SetMobjState`
  loops while the state it enters has `tics == 0`; entering such a state
  here leaves `tics_left == 0`, and the caller decides how far to chain
  (`while tics_left == 0 { advance(...) }`, with its own bound). An
  unbounded loop has no place on a proving path.

## Invariants

- `advance` and `enter` are pure functions of `(tables, state_id,
  tics_left)`.
- A `FOREVER` state is a fixed point: no transition, no action, ever.
- A state with `tics = n ≥ 1` transitions on exactly the n-th advance, and
  the action returned is that of the state *entered*, never of the one left.
- Total functions: an out-of-range `state_id` parks the machine
  (`FOREVER`, `NO_ACTION`) instead of trapping; `row` returns `None`;
  `appearance` returns `(0, 0)` (R4-A2).
- `advance` reads `tics[next]`/`action_id[next]` with `at`, which is only
  safe because `validate` has checked that every `next_state` is in range.
  **Call `validate` once** on any table before using it (at genesis, or in
  a test); `len` also reads a single column on that basis.
- Everything this crate produces is a `u32` (< 2^32, so far below the 2^72
  range-check cliff, A7).

## Measured costs

Method: differential step measurement, `scarb execute
--print-resource-usage`; see [`bench/README.md`](bench/README.md). Bare
loop 11 steps; `enter`/`row` are netted against the 6.75-step cursor loop
their harness needs. Scarb 2.16.0, `enable-gas = false`.

| Operation | net steps | budget (CI) |
|---|---:|---:|
| `advance`, counting down (the common case) | **19** | 21 |
| `advance`, realistic cycle (4/4/6 tics) | **30.3** | 34 |
| `advance`, transition on every tic | 72 | 80 |
| `enter(state)` | 44 | 48 |
| `row(state)` (five columns) | 120 | 132 |

Three measured decisions got it there, each worth recording because the
first guess was wrong in all three cases:

1. **`#[inline(always)]` on `advance` and `enter`.** A plain call costs
   **43 steps** with this signature (five `Span`s in, three `u32`s out) —
   more than twice the body. Inlining took counting-down from 62 to 19 and
   a realistic cycle from 86 to 30. S1 §5.9's rule ("inline only one- or
   two-instruction bodies") is about *bytecode*, and the price here is
   ~54 words per call site; with a handful of call sites in
   `doom_things`/`doom_monsters` that is a good trade, and the remedy if it
   ever stops being one is to funnel the calls through one site, not to
   drop the attribute.
2. **`len` reads one column, not five.** Taking the minimum of the five
   column lengths cost 40 steps on every call and made a transition 195
   steps; `validate` already guarantees they are equal.
3. **One ordered comparison, not three equality tests** — worth only 2
   steps (64 → 62 on the counting-down path before inlining), but it
   corrects a wrong assumption worth recording: `==` on a `u32` is *not*
   the cheap felt comparison one expects, it costs the same ~10 steps as
   `<` (S1 §5.1). What matters is how many tests run, not which kind, and
   `tics_left > 1` covers "counting" and "for ever" at once because
   `FOREVER` is the largest `u32`.

Passing `@StateTables` instead of `StateTables` was also tried: no gain for
`advance` and 34 steps *worse* for `enter`, so the API keeps the plain
value.

## Tests

`scarb test -p fsm`: 17 tests — Doom-semantics reference traces (mirrored
and extended by `bench/reference.py`, which checks the n-th-advance rule
for n = 1..63 against a model written from Doom's C rule), properties
(`FOREVER` is a fixed point, a cycle returns to its start, `advance` is
pure), edge cases (zero-tic chaining, out-of-range state ids, every shape
of malformed table), and a provability test on value widths. The
step-budget test is `bench/measure.py`.

**Coverage**: `python3 bench/coverage.py` reports **37/37 production
lines = 100 %** (17 tests). It copies the crate to a temporary directory
and patches the manifest there, because `cairo-coverage` only reads
`snforge` traces and `snforge` cannot compile this workspace with
`enable-gas = false`; lines at or below a file's `#[cfg(test)]` marker are
excluded, so the figure is the coverage of the code that ships.
`cairo-coverage` 0.5.0 emits no `BRF`/`BRH` records, so **branch** coverage
cannot be reported by the tool — line coverage is the proxy, and since
`scarb fmt` puts every branch arm on its own line, a missed arm shows up as
a missed line. The script exits non-zero below 90 % (C7).

## Transitional

`src/compat.cairo` still exports the Phase-0 skeleton's `StateDef {
duration, next }`, `Timer`, `start` and `tick`, because
`cairo/doom/doom_monsters` and `cairo/doom/doom_game` use them. That is
also why the five-field record here is called `StateRow` rather than
`StateDef`. Delete the module, and rename `StateRow`, with P1.5.

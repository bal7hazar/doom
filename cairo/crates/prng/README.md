# prng

**Does**: a table-driven, fully replayable pseudo-random generator with the
shape of Doom's `M_Random`/`P_Random`. The whole generator state is one
cursor — `Prng { index: u32 }` — into a **256-entry byte table supplied by
the caller on every draw**. `PrngTrait::next(table) -> (Prng, u8)` reads
`table[index]` and advances the cursor, wrapping at `TABLE_LEN = 256`.
On top of that core draw it offers the four idioms Doom's code uses:
`chance(table, threshold)` (`P_Random() < prob`), `below(table, n)`
(`P_Random() % n`), `sub_random(table)` (`P_SubRandom()`, two draws,
`[-255, 255]`), and `skip(n)`. `from_index` and `skip` fold any `u32` into
range, so no seed can make a draw trap.

**Does not**: carry a table. Doom's `rndtable` is Doom data and lives in
`cairo/doom/*`, never here (PLAN.md A10, the generic-crate rule). It does
not hold the `P_Random`/`M_Random` split either: Doom keeps two cursors so
that cosmetic randomness cannot desynchronise a demo, and *which* streams
exist is the caller's decision — hold two `Prng` values and draw from the
one the effect belongs to (`test_two_streams_are_independent` shows the
pattern). It is not a cryptographic RNG and takes no entropy from anywhere:
its only input is the cursor, which is part of the hashed game state, so an
RNG divergence is caught like any other state divergence (C2).

**Invariants**:

- `index < TABLE_LEN` always — established by every constructor, preserved
  by every method, so `table.at(index)` never traps for a table of
  `TABLE_LEN` entries (check yours once with `is_valid_table`).
- `next` is a pure function of `(index, table)`; same state and table always
  give the same `(state, byte)`.
- The cursor has period exactly 256, and one period returns every table
  entry exactly once, from any starting cursor.
- Every draw consumes exactly one table entry *whatever the outcome*
  (`chance` and `below` draw even when they return `false`/`0`), which is
  what makes RNG consumption replay-stable. `sub_random` consumes two.
- Total functions: `below(table, 0)` yields `0` instead of dividing by zero,
  `from_index`/`skip` fold out-of-range cursors (R4-A2, zero panics on the
  proving path).
- The state serializes to exactly one felt, far below 2^72 (A7).

## Measured costs

Method: differential step measurement, `scarb execute
--print-resource-usage`; see [`bench/README.md`](bench/README.md). Net =
gross minus the 9-step bare loop. Scarb 2.16.0, `enable-gas = false`.

| Operation | net steps | budget (CI) |
|---|---:|---:|
| `next(table)` — one draw | **17** | 18 |
| `below(table, 8)` | 25 | 29 |
| `chance(table, 128)` | 27.5 | 31 |
| `sub_random(table)` — two draws | 48 | 55 |
| *(cursor wrap alone, not an API call)* | 7 | — |

17 steps is at the floor for a wrapping table draw in Cairo 2.16: S1
measured a `Span` index at 11 net steps and an integer comparison at 10,
and the wrap alone measures 7 here. The variants tried and rejected:
branching on `index + 1` instead of on the cursor (18, the increment then
exists on both arms), a `felt252` cursor converted per read (19), a
`Span<felt252>` table instead of `Span<u8>` (17, no gain), and `%
TABLE_LEN` instead of a comparison (a `u32` division costs ~15 alone).
The target in the task statement was ≤ 15; 17 is the measured floor and the
2 extra steps are the equality-plus-select of the wrap, which cannot be
removed without changing the table length to a power-of-two mask (S1: masks
cost *more*, 57 steps/iteration against 14 in felt arithmetic).

## Tests

`scarb test -p prng`: 22 tests — reference vectors cross-checked against
`bench/reference.py`, properties (determinism, period 256, period is a
permutation of the table, `below` stays in range over a full period,
`sub_random` cancels on a flat table, `skip(n)` equals `n` draws), edge
cases (cursor at 255, modulus 0, huge seeds, short table), and the
serialization shape. The step-budget test is `bench/measure.py` (exit code
is the verdict).

## Transitional

`src/compat.cairo` still exports the Phase-0 skeleton's `value(index)` /
`next(index)` pair, which embeds a placeholder byte formula, because
`cairo/doom/doom_monsters` imports `prng::next`. Delete both — and this
paragraph — when `doom_monsters` moves to `PrngTrait` and takes Doom's
`rndtable` from `doom_things`.

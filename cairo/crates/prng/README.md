# prng

**Does**: reimplements the *shape* of Doom's table-based pseudo-random
generator: a 256-period deterministic byte sequence indexed by an
`index: u8` that increments (and wraps) on every draw, exactly like the
original `rndtable`/`M_Random`. The byte sequence itself is currently a
placeholder formula (a small deterministic mixing function of the index),
**not** a copy of the original `rndtable` bytes; it is to be replaced by the
exact 256 values extracted independently from public Doom documentation in
Phase 1 (PLAN.md §3.1, task 2) without reading GPL-licensed source (A10).
Replaying the same sequence of draws from the same starting index is fully
deterministic and reproducible, which is required for `run_segment`
replays (PLAN.md C2).

**Does not**: seed itself from wall-clock time or any external entropy —
the only state is the `u8` index, which is part of `GameState` and is
included in the canonical state hash (`state_hash`) so that RNG divergence
is detected like any other state divergence. It does not provide a
cryptographic RNG.

**Invariants**: `next(index)` is a pure function of `index` (no hidden
state); the returned next index is always `index + 1` modulo 256 (wraps,
never panics); iterating 256 times returns to the starting index; the table
contains exactly 256 entries, each in `[0, 255]`.

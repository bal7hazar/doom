# segment

**Does**: runs K tics of *someone's* game as one provable Cairo execution
and produces the fixed public output the chain reads. `run_segment(state,
cmds, tic_start, max_tics)` loops until the commands run out, the tic
budget runs out, or the engine reports a terminal status; it hashes the
state exactly twice (before and after), folds the commands it consumed into
an input-log commitment, and returns the final state together with a
`SegmentOutput`. `to_felts`/`from_felts` flatten and re-read that output,
and `continues` is the continuity rule `DoomRuns` enforces between
consecutive segments, written once so the contract and the tests share it.

**Does not**: know any game. The game arrives as an impl of
`SegmentEngine` — `step`, `hash`, `stats`, `word` — so this crate never
depends on `doom/*`. It does not choose K (the caller passes `max_tics`),
does not decide when to cut a segment, and does not prove anything itself.

## Public output layout

Ten felts, in this order. It is what `Serde` writes for a `SegmentOutput`
(asserted by `test_to_felts_matches_serde`), so an executable returning one
puts exactly these felts in the leaf bootloader's output preimage
(`[program_hash, out_0, …]`, S4 §1).

| # | Field | Meaning |
|---:|---|---|
| 0 | `version` | layout version — currently **1** |
| 1 | `h_in` | Poseidon hash of the state before the segment |
| 2 | `h_out` | … and after it |
| 3 | `tic_start` | absolute tic index of the first tic |
| 4 | `tic_end` | one past the last tic actually run |
| 5 | `status` | 0 RUNNING, 1 DEAD, 2 EXIT, 3 ABORT |
| 6 | `inputs_commitment` | commitment to this segment's slice of the input log |
| 7 | `kills` | |
| 8 | `items` | |
| 9 | `secrets` | |

This is CONTEXT.md §9's `[h_in, h_out, tic_start, tic_end, status, kills,
items, secrets]` with two additions:

- **`version` first**, so a consumer dispatches on the layout before
  reading anything else. A field added later must not silently shift the
  meaning of fields already deployed on chain; `from_felts` refuses any
  other version.
- **`inputs_commitment`**, so the input log published as an event is
  *bound* to the proof rather than merely accompanying it. Without it a
  third party can replay the log but cannot tell whether it is the log the
  proof consumed.

The chain-side rules are unchanged: `h_in[0] = genesis`, `h_out[i] =
h_in[i+1]`, `tic_end[i] = tic_start[i+1]`, `status = EXIT` on the last
segment and `RUNNING` on every other one. `bench/reference.py` implements
all of them in Python for the contract and the replay tool.

### The input-log commitment

`inputs_commitment` is **per segment**, not chained: it starts from
`state_hash::inputs_seed()` and folds this segment's own commands, seven
words to a transport felt (`ticcmd::Packer`), with Starknet's 2-to-1
Poseidon. A verifier recomputes it from the slice of the published log that
`tic_start`/`tic_end` names — `bench/reference.py`'s `commit_log` is that
computation, and the crate pins one of its values as a test vector.

Per-segment rather than chained because a segment boundary seals a partial
group of seven, so a chained commitment would not survive re-cutting the
run into different segments. The consequence is deliberate and tested
(`test_inputs_commitment_is_per_segment_not_chained`): splitting a segment
preserves the state, the hash chain and the stats, but not this field.

## Invariants

- **Associativity**: `run(s, a ++ b)` and `run(run(s, a), b)` agree on the
  final state, on `h_out`, on `tic_end` and on the stats, for every split
  point (tested for all ten splits of a nine-tic segment) — and the two
  halves satisfy `continues`.
- The tic that ends the game is *included*: a segment that exits on its
  second tic has `tic_end = tic_start + 2`.
- `tic_end - tic_start == min(cmds.len(), max_tics)` unless a terminal
  status cut it short.
- An empty command span, or `max_tics = 0`, is a strict no-op: same state,
  `h_out == h_in`, `tic_end == tic_start`, status `RUNNING`.
- `to_felts` is `Serde`'s output, and `from_felts` is its inverse on any
  well-formed output — including an `ABORT` one.
- **Zero panics** (R4-A2): nothing here can trap. The loop only indexes
  inside the span; `tic_start + ran` cannot overflow because the run is
  clamped to `MAX_TIC = 2^30`; a `tic_start` past that ceiling yields a
  zero-tic `ABORT` instead of a trap; and the engine signals trouble by
  returning `Status::Abort` rather than panicking. An `ABORT` segment still
  produces a complete, readable output — it simply will not be accepted as
  part of a finished run.
- `hash` is called exactly twice per segment, never per tic (S3: the state
  is (de)serialized only at segment boundaries).

## Why a trait, not a function argument

Cairo has no function pointers, so the game is supplied as an impl of
`SegmentEngine`. It is **one trait with four methods** rather than four
separate generic parameters because each monomorphised generic costs 60–77
bytecode words (S1 §5.9) against a 16 k-word program budget (G0 D4).

## Measured costs

Method: differential step measurement, `scarb execute
--print-resource-usage`; `n` is the number of tics, so these are per-tic
figures, netted against the 4-steps/tic span construction. See
[`bench/README.md`](bench/README.md). Scarb 2.16.0, `enable-gas = false`.

| Operation | net steps/tic | budget (CI) |
|---|---:|---:|
| `run_segment`, whole loop | **35.7** | 39 |
| … span read + engine dispatch only | 19 | 21 |
| … loop core (adds the terminal-status test) | 19 | 21 |
| … the input-log commitment alone | 34.7 | 38 |

**The loop itself costs 19 steps/tic**, comfortably inside the 30-step
target and in line with S1 §5.8's 29 steps for a bare tic loop carrying
full state by value. The other ~17 are the input-log commitment: the
`ticcmd::Packer` push (12.3 steps/tic) plus one 2-to-1 Poseidon per seven
tics (7 steps, so 1 per tic), plus its share of the loop.

Two things moved that number:

1. `state_hash::commit_input` was `poseidon_hash_span([prev, packed])` at
   48 steps; it is now Starknet's 2-to-1 Poseidon (one Hades permutation)
   at 7. That alone took the total from 45.7 to 35.7, and it is also the
   function `starknet.js` exposes as `poseidonHash(a, b)`, so the verifier
   side got simpler at the same time.
2. Inlining `Packer::push` was tried and changed nothing (the compiler
   already inlines it). Getting under 30 would mean open-coding the 7-tic
   packing inside the loop, duplicating `ticcmd`'s format for ~6 steps —
   0.05 % of the 12 000-step tic budget (G0 D2). Not taken; the duplication
   would be a correctness risk for no measurable gain.

For scale: at 12 000 steps/tic, the runner's overhead is **0.3 % of a
tic**, and the two state hashes are ~116 000 steps per segment, ~1 % of a
2^20-step segment at K = 160.

## Tests

`scarb test -p segment`: 24 tests, all against a toy engine (a counter with
health and kills) so that nothing Doom-specific leaks in — the output
layout felt by felt and against `Serde`, `from_felts` round trip and its
five rejection cases, every status code, associativity over all ten splits
of a nine-tic segment, the continuity predicate and its four failure modes,
early stop on `EXIT`/`DEAD`/`ABORT` (including on the very first tic),
empty span, `max_tics = 0`, `max_tics` truncation, the `MAX_TIC` ceiling
from both sides, the commitment against an independently packed log and
against a `poseidon_py` vector, and its sensitivity to every single tic.
The step-budget test is `bench/measure.py`.

## Transitional

`chain_commands` is kept because `doom_game::run_segment_header` calls it.
It has no game semantics at all — `run_segment` replaces it. Delete with
P1.3.

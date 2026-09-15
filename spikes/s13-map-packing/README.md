<!--
SPDX-FileCopyrightText: 2026 Hellproof contributors
SPDX-License-Identifier: GPL-2.0-only
-->

# S13 — isolated map packing probe: NO-GO

This experiment tests one candidate: six eleven-bit `BM_ITEMS` ids per u128
constant, decoded to exactly the original 2064-element `Span<u32>`. It is not
used by the game. No loader, context, GameState, entrypoint, wire schema, pin,
profile, benchmark limit or 35 Hz rule is changed.

**Rejected on cost.** The actual program saves **1439 words**, but decoding
adds **65417 VM steps** against a reference returning the planar const span.
The existing Blake sizing approximation (S0/S4b, 14.75 steps per program word)
credits only **21225.25 steps** for that saving. The estimated combined delta is
therefore **+44191.75 steps per load**, before any repeated-load integration.
No proof or RAM reduction is claimed. This is one candidate's result, not a
proof that all compression algorithms fail. The experiment stops here.

| Proving executable | Instructions | Constants | Framing | Total words | VM steps, full observable output |
|---|---:|---:|---:|---:|---:|
| reference | 114 | 2064 | 18 | 2196 | 20694 |
| candidate | 395 | 344 | 18 | 757 | 86111 |
| inspect_decode | 466 | 0 | 17 | 483 | varies by case |

The decoder/glue adds 281 instruction words to the 1720-word raw payload saving.
The candidate has only 344 constant words: the reference array in the same
source module is eliminated from its executable. Both measured paths return
an `Option<Span<u32>>`; serialization and all 2064 output ids are observable.
The reference does not copy/decode into a scratch array, and no baseline
subtracts work the original loader would not perform. `count=2064` is a runtime
argument, not a constant supplied by a wrapper.

Range-check cells rise from 2 to 11015. Recorded maximum memory addresses rise
from 20835 to 83973, with 1 versus 348 holes. These are VM resource counters,
not browser RSS, proof trace sizes or AIR/log heights. Logs include their raw
values. `measured.json` records final executable/Sierra identities and results.

## Correctness and domain

`src/data.cairo` copies the exact `BM_ITEMS` from
`cairo/doom/doom_map/src/levels/e1m1.cairo`, a GPL-2.0-only source derived from
the pinned Freedoom map. The generated header records that complete source's
SHA-256. `prepare.py` only writes this experiment's file; no original generated
file or expectation is rewritten. The source table has 2064 ids, all below 2048;
packing emits 344 values strictly below 2^66 (and therefore 2^72/A7).

The private decoder accepts count 0..2064 and exactly `ceil(count/6)` words.
Each word holds six base-2048 digits. A final partial word must have zero unused
digits; all full words must also have zero bits above bit 65. Extraction uses
integer u128 division by a NonZero literal, never division in the felt field.
The resulting span preserves every element, length and order. Invalid metadata
or padding returns None, with no public gameplay fallback changed.

Validation compares every output id to the independent original table, then
checks fourteen opaque-input cases: empty, zero/max mask, six max ids, seven ids,
five-id partial group, nonzero padding, high bit, u128 maximum, truncated/extra
words, empty with extra word, count 2065 and u32 maximum. Four more runtime count
values must be rejected identically by reference and candidate. No skipped tests.

## Reproduce

Use Scarb **2.16.0**, one job and a **120-second timeout per command**, no proof.
`measure.py` enforces this bound for executions and Sierra attribution. It does
not build the Rust attribution tool; supply an existing `infra/sierra_words`
binary compiled with the repository's pinned dependencies.

```sh
export ASDF_SCARB_VERSION=2.16.0 RAYON_NUM_THREADS=1
python3 spikes/s13-map-packing/prepare.py
scarb --manifest-path spikes/s13-map-packing/Scarb.toml fmt
scarb --manifest-path spikes/s13-map-packing/Scarb.toml --profile proving build
python3 spikes/s13-map-packing/measure.py \
  --sierra-words /absolute/path/to/sierra_words \
  --out /tmp/s13-measurements
```

Build/fmt should be supervised with a 120-second timeout as well. The Python
script writes exact native outputs, input files, resource logs, commands and
instruction/constant/framing attribution only under `--out`. The full result
is in `result.json`; performance failure is data (`passes_cost_filter=false`),
not a skipped correctness test. A nonzero script exit means a failed execution,
comparison or harness invariant.

The first candidate was measured, then only formatting and measurement-report
attribution were completed. Rebuilding confirmed identical executable hashes,
word counts and VM costs. No loop-tuning attempt, larger table, reuse-context
migration, public ABI campaign, browser run or proof followed the NO-GO.

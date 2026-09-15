<!-- SPDX-License-Identifier: GPL-2.0-only -->
# D29: sharing linked code without changing the compiler policy

Reference: `aa16f2b952b0df29366597f3b4970ed790266f06` (D33 plus main).
Scarb 2.16.0, existing `dev` and `proving` profiles, at most two CPU jobs.
The three experiment families and final results are recorded in `results.json`.
No table, golden, schema, compiler profile, step budget or 100,000-word guard
was changed. `doom_run/bench/size.py` must still fail while the complete
proved program exceeds that target.

| Complete executable | dev before → after | proving before → after |
|---|---:|---:|
| run_segment | 129,086 → 125,854 | 110,015 → 106,878 |
| step_tic | 129,213 → 125,981 | 111,502 → 108,365 |
| genesis | 51,731 → 50,746 | 47,415 → 46,434 |

The total guard still returns **1**, 6,878 words over target. All 565 Cairo
tests, 70 replay/cut comparisons and 35 native ABI cases per profile pass;
four malformed executable envelopes are rejected in both profiles. Fixed,
BAM, physics, player and monster budgets pass unchanged. The retained tradeoff
is explicit: the proving idle300/fight493 tic frames increase 0.60%/0.88%,
while complete proving replays range from −0.83% to +0.25%; dev complete
replays increase 1.01%–1.75%. This is not a general VM speedup.

The retained code shares Doom's full-domain `to_u128` conversion through a
non-inlined wrapper around the original `fixed` function, as well as the
opaque loop zero and repeated boxed constructors. `A_Lower` and `A_Raise`
select their updated fields before rebuilding the same Player record once.
The generic arithmetic remains unchanged: globally outlining its conversion
broke the existing `mul`, `to_units` and `shr8` step budgets.

The other rejected experiments were the hot fixed comparison, outlining all
readers and parser conversions, unpacking four map columns at load time,
and reading adjacent pairs from the BAM tables. Map unpacking ran at every
context load, including each tic; its initialization cost was measured.
BAM packing was exact and smaller but exceeded nine unchanged BAM budgets.
Neither generated table representation is retained.

## Reproduce the measurements

Keep immutable reference executables in `REF/dev` and `REF/proving` before
building the candidate. The existing game scripts compare every output felt,
not just the final checksum. They never rewrite expected values:

```sh
ASDF_SCARB_VERSION=2.16.0 RAYON_NUM_THREADS=2 scarb --manifest-path cairo/Scarb.toml test
ASDF_SCARB_VERSION=2.16.0 RAYON_NUM_THREADS=2 python3 cairo/doom/doom_run/bench/size.py
SIM_PROBE=/absolute/path/to/sim-probe-lines python3 cairo/doom/doom_game/bench_boundary/measure.py --reference REF/proving --executables cairo/target/proving --json boundaries.json
RAYON_NUM_THREADS=1 python3 cairo/doom/doom_game/bench_sizing/compare.py --reference REF --profile proving --json replays-proving.json
RAYON_NUM_THREADS=1 python3 cairo/doom/doom_game/bench_sizing/compare.py --reference REF --profile dev --json replays-dev.json
```

Use execution timeouts (the audit used 90 seconds per native call and 900
seconds per complete validation command). Run the fixed, BAM, physics, player
and monster `bench/measure.py` scripts with their checked-in budgets, never
`--update`. `doom_monsters/bench/profile_loop.py --arguments ... --keep-trace`
and `doom_game/bench_boxed/inspect.py` measure the actual idle300/fight493
command frames separately from the boundary. Preserve the same arguments and
verify the executable hash recorded by each profile.

`attribute.py` reads the matching annotated Sierra and executable:

```sh
python3 cairo/doom/doom_run/bench_bytecode/attribute.py \
  --sierra cairo/target/proving/run_segment.executable.sierra.json \
  --executable cairo/target/proving/run_segment.executable.json \
  --tool infra/sierra_words/target/release/sierra_words --json attribution.json
```

It separates statement words, static payloads and executable framing. The
first non-core source frame receives a core helper's consumer cost; this is
not a `size−baseline` result. Constants are extracted by the pinned compiler's
`ConstsInfo::new` / `extract_const_value` rules. The 77 reference constants
contain 22,932 words, with only 64 words of duplicate payload (different
constant types). The remaining framing is 61 words. Pairing all constants
whose values fit 36 bits could theoretically save at most 8,855 payload words,
before decoder code, reads, allocations and initialization. No such saving
is assumed for the final program.

Passing these tests establishes VM equivalence and the reported costs.
It does not establish AIR admissibility, cryptographic verification, proof
memory use or browser throughput. Those require separate measurements of
the exact final executable.

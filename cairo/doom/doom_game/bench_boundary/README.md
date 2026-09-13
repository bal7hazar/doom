<!-- SPDX-License-Identifier: GPL-2.0-only -->
# State boundary measurement

This measures the real `prover/sim::SimProgram` executable ABI with runtime
felt inputs. It does not infer costs by subtracting two averaged game loops.
It compares every output felt with preserved baseline executables and records
both executable SHA-256 identities. The baseline source is `df1888d`; the
optimized sources are `9f3d90c` (private executable encoding) and `56291d1`
(state, grid and render). Scarb is **2.16.0** throughout.

## Reproduce

Build and preserve the three baseline executable JSON files in a separate
checkout of `df1888d`, then build the current code with the same profile:

```sh
ASDF_SCARB_VERSION=2.16.0 scarb --manifest-path cairo/Scarb.toml --profile proving build -p doom_run
SIM_PROBE=/tmp/hellproof-game-sim-probe-lines python3 cairo/doom/doom_game/bench_boundary/measure.py \
  --executables cairo/target/proving --reference /path/to/baseline/target/proving \
  --json /tmp/boundary-proving.json
```

Use `build` without `--profile proving` and `target/dev` for dev. `SIM_PROBE`
is the native line-oriented runner from `doom_run/bench/sim_probe.rs`; its
`build_sim_probe.sh` builds it against the pinned simulation VM. The protocol
is one space-separated hex-felt request per stdin line and one
`steps output_felt...` response. The probe executes the same loaded program
and VM as simulation; there is no alternate direct ABI.

The comparison covers 35 cases: genesis/unknown level, empty/idle/walk/four
walk tics, ten-felt segment outputs, all terminal statuses, malformed states,
wrong tic start, and four actual serialized cuts. Four malformed executable
ABI envelopes must also be rejected by both programs. The script never
rewrites gameplay fixtures or accepts a difference as a new baseline.

## Results, 2026-09-13

Full reports: [proving.json](proving.json) and [dev.json](dev.json).
All output felts compare equal in both profiles, including empty ABORT arrays
and the final output of four serialized cuts versus four grouped tics.

| Real executable call | Proving before | Proving after | Dev before | Dev after |
| --- | ---: | ---: | ---: | ---: |
| `step_tic(state, [])` | 528,154 | 288,045 | 534,640 | 293,044 |
| One idle | 584,351 | 344,230 | 592,376 | 350,768 |
| One walk | 600,643 | 360,522 | 608,854 | 367,246 |
| Four walk tics | 807,458 | 567,301 | 820,579 | 578,935 |
| Empty `run_segment` | 571,220 | 412,320 | 575,012 | 414,618 |
| Four-walk `run_segment` | 850,626 | 691,678 | 861,061 | 700,619 |
| `genesis(0)` | 875,903 | 819,777 | 883,895 | 827,773 |

The fixed empty call falls **45.5%** in proving. **The 150,000-step target is
not met.** The gameplay ticker is unchanged; this improvement does not claim
to bring its per-tic p99 below D2.

| Full executable bytecode words | Proving before | Proving after | Dev before | Dev after |
| --- | ---: | ---: | ---: | ---: |
| `run_segment` | 117,531 | 116,451 | 138,466 | 137,422 |
| `step_tic` | 118,768 | 118,003 | 138,283 | 137,663 |
| `genesis` | 47,356 | 47,563 | 51,791 | 52,036 |

These are total program words, including data, not source attribution or a
size-minus-baseline contribution. The proving `run_segment` remains **16,451
words above the 100,000 target**, with 3,549 words below its 120,000 hard limit.
The adapter slightly increases the genesis bytecode. No budget is changed.

## Changes and invariants

* Executable input arrays use core's checked span decoder with the identical
  `[length, felts...]` encoding. A private output Serde copies 64-felt blocks
  and an exact tail. Public `*_impl` APIs retain their signatures.
* Each mobj record is bounds-checked once as a 27-felt immutable view. Every
  scalar domain check remains. A narrow roster helper carries three map
  bounds, and its fallible record return is boxed.
* The reader restores one complete validated list per grid cell. Its grid
  dictionary rejects duplicate cells; four u64 words detect repeated members
  across the full 256-slot domain. Counts, membership, coverage and trailing
  data are still validated.
* Canonical grid serialization retains cell order by first live index and
  historical member order. The journal dictionary also stores its visited
  bit, removing one temporary dictionary without changing its output.
* The render snapshot writes its final array directly after a narrow live
  count, avoiding a complete body copy. Its format is unchanged.

Schema 2, field order, hashes, grid order, status/ABORT behavior and all
validation domains are unchanged. The five v1 gameplay pins and five v2
state pins in `src/tests/e1m1.cairo` passed without edits. The C2 pickup-order
and serialized combat regressions also pass.

## Remaining cost and validation

A final proving Scarb profile reports 288,048 steps (the native probe reports
288,045). The largest remaining inclusive costs are the roster reader
89,706, grid reader 53,049, rendered mobjs 25,669, canonical grid order 25,022,
output adapter 22,965 and derived heights 20,235. Dictionary squash adds
11,968 flat steps. These profile categories are not an additive accounting.

Further large gains require investigating the state lifecycle: the client
currently rebuilds and validates the whole serialized world at every VM
call. A persistent simulation session could amortize that work while keeping
a stateless checked segment boundary for proving, but needs its own API,
resource and equivalence design. This pass implements no such architecture
change and removes no validation.

Validation completed:

* Scarb dev and proving builds; format check.
* 40 `doom_game`, 7 `doom_run`, and 31 `doom_physics` tests.
* The real ABI comparisons above in both profiles.
* Physics step and code guards: all pass; historical code delta 36,017 words,
  lite 32,767, with all original budgets unchanged. The separate 12,000-word
  physics target remains open.

No heavy proof was run for this pass. Repository REUSE on the baseline tree
reports three pre-existing generated-string SPDX issues outside this scope
(`gen_things.py`, `doomruns_model.py`, `real_batch.py`), already handled on the
orchestrator's newer main branch.

<!-- SPDX-License-Identifier: GPL-2.0-only -->
# Reuse equal heights and copy changed spans

Measured against `bb9efb3` (engine `0c8a3a8`) with Scarb 2.16.0. This changes
neither movers nor serialized state: `refresh_heights` checks the *current*
derived array before rewriting a sector, and `set_felt` copies its prefix and
suffix through `append_span`. It preserves sequential writes, including repeated
writes to one sector. A disappearing mover still triggers the complete rebuild.
The condition is value equality, never the mover phase.

`main(n, sector, mode)` accepts the iteration count, sector and changed/unchanged
plane mode as executable inputs. It resets the input arrays each iteration, so
a changed-height case cannot become an unchanged-height case after its first
iteration. It returns both complete 182-sector arrays. Differential `n=10,20`
measurements remove genesis, output and bootstrap costs. Results include the
same harness loop/context overhead in both versions, rather than claiming the
net cost of a standalone memory copy.

| Mode at sector 98 | Before dev | Final dev | Before proving | Final proving | RC before → final |
|---|---:|---:|---:|---:|---:|
| Unchanged ceiling | 4061 | 244 | 4055 | 242 | 180 → 1 |
| Changed ceiling | 4061 | 2097 | 4055 | 2095 | 180 → 4 |
| Unchanged floor | 4067 | 247 | 4061 | 245 | 180 → 1 |
| Changed floor | 4067 | 2100 | 4061 | 2098 | 180 → 4 |

All measured cases use **zero additional bitwise cells per iteration**.
The equality guard alone gives proving 242/4068/245/4071 steps in row order;
its changed cases cost 13/10 extra steps. Narrow span copying removes that
regression and improves the changed cases too.

There is a bytecode tradeoff, not a D29 win:

| Full executable | Before dev | Final dev | Before proving | Final proving |
|---|---:|---:|---:|---:|
| genesis | 50746 | 50746 | 46434 | 46434 |
| step_tic | 125963 | 126055 | 108342 | 108462 |
| run_segment | 125836 | 125928 | 106855 | 106975 |

The guard alone adds 56 proving words; both changes add **120 proving words**.
The corresponding modeled program-hashing cost is about 1770 steps per proof
segment (14.75 × 120), not per simulated tic. Integration must weigh that
against measured real-tic savings. D29's 100000-word target remains exceeded.
No budgets, physics, RNG order, ABI or gameplay cadence change.

Validation: 30 specials tests and 61 game tests passed, followed by both new
refresh tests including a later-added duplicate-sector ordering case (62 distinct
game tests total). `set_felt` is checked at every index of lengths 1, 5, 15,
182 and 183 against an independent indexed oracle. All 24 full-output comparisons
(before/final × dev/proving × four modes × sectors 0,98,181) match, each with
366 output felts. Existing full game replay/hash and cross-boundary tests pass.

Reproduce a measurement on either checkout (results and frozen executables are
written outside the repository):

```sh
RAYON_NUM_THREADS=1 CARGO_BUILD_JOBS=1 \
  python3 cairo/doom/doom_game/bench_refresh/measure.py /tmp/refresh-measurement
ASDF_SCARB_VERSION=2.16.0 scarb --manifest-path cairo/Scarb.toml test -p doom_game -p doom_specials
```

The assembled subsystem benchmark on this branch changes only the walk scene's
whole-tic measurement: **83279.8 → 81316.8 steps** (−1963). All other recorded
operations match the root's current-baseline measurement exactly. The command
still exits 1 for three **pre-existing** thresholds: idle hash, idle deserialize
boundary, fight hash. The baseline has the same three failures; budgets were not
rebased. This scene sample is not a whole-corpus mean or p99.

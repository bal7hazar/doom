# D33 — boxed actor roster

Reference: `91719f8fca61426077712b2052a19e8f8e804da4`, Scarb 2.16.0.
The internal roster is now `Span<Box<Mobj>>` throughout physics, player,
monsters and game; `Patch.mo` retains the box as well. No conversion back to
a value roster runs between tics. An unchanged slot appends its pointer;
a changed actor still allocates all 27 fields. Schema 2, full state/render
outputs, D14, RNG, slot order and grid visitation order are unchanged.

Read actor fields through the box in the ticker. Keeping an `@Mobj`
snapshot live across its branches caused Cairo to copy 27 felts again;
removing that live value saved another 4,949 steps on the first idle tic.
The parser also keeps the box returned by `read_mobj` through validation.
All validation predicates and the exact removed-record comparison remain.

## Real measurements

`results.json` records immutable executable/input hashes and both profiles.
The two single-tic inputs are replay states before idle tic 300 and fight
tic 493. Actual command-loop frames exclude serialization/render boundaries;
they are not differences between averaged chunks or a p99 estimate.

| Proving measurement | Reference | Boxed |
|---|---:|---:|
| `step_tic` empty, native SimProgram | 275,020 | 266,505 |
| first idle call, native | 318,726 | 300,611 |
| first walk call, native | 334,835 | 305,746 |
| four walk tics, native | 503,761 | 413,384 |
| idle 300, actual tic frame | 39,433 | 29,833 |
| fight 493, actual tic frame | 190,594 | 168,845 |
| idle 300, monster subtree | 34,765 | 25,191 |
| `run_segment`, complete dev words | 129,752 | 129,086 |
| `run_segment`, complete proving words | 110,848 | 110,015 |

Idle 300 improves **24.35%** and fight 493 **11.41%**. The complete 700-tic
idle call improves 23.56% (28,254,976 → 21,599,331 Scarb steps, boundary
included). The 100,000-word target remains exceeded by **10,015**; no budget
was raised. Tables/framing contribute 22,993 proving words in both builds.
Attribution is source ownership, not a removal experiment: core 45,125 →
44,701; physics 11,561 → 11,456; game 9,550 → 9,416; player 6,618 unchanged;
monsters 5,930 → 5,760. Dev attribution was rebuilt with annotations only in
temporary source copies: all six dev executable files are byte-identical to
the unannotated frozen reference/candidate files.

Allocations are charged, including modified dormants. Inside idle 300,
`into_box<Mobj>` runs **28 → 48** times: 20 extra changed countdowns replace
the former direct 27-felt array writes. Those writes cost 756 → 1,296 VM
instructions. Actor array writes fall **5,670 → 210**, and
`store_temp<Mobj>` instructions **8,073 → 2,133**. Fight 493 allocates
123 → 120 records, actor array writes 11,394 → 422, and Mobj stores
16,362 → 4,401. A `FOREVER` dormant reuses its box when no other action runs.
These counts describe executions of nonempty Sierra `into_box<Mobj>`
statements; they are not a heap, AIR-size or RAM guarantee. The 43/128
instructions outside Sierra statement ranges are reported separately and
unchanged between the matching traces.

All physics/player/monsters regression benches pass with unchanged budgets.
Physics replacement of 210 slots falls 20,851 → 4,525 net steps. Player
fixtures pay 1–2 extra steps to construct their short boxed roster. Monster
microbenches improve unevenly: 29 dormant monsters 12,455.75 → 11,856.95;
eight awake 30,679.2 → 29,707.9; `awake_count` alone rises 1,240 → 1,269.
The player all-API size-minus-baseline difference is still 20,514 proving
words; source attribution is 18,772 and actual game linkage 6,618. The
monster all-API difference remains 17,682, ticker-only difference 13,958.
These distinct measurements must not be substituted for each other.

## Equivalence and reproduction

The 565 tests across 23 workspace targets pass, including the existing
physics/player/monster checksums, five pairs of game hashes, armor ordering,
D3 large tics, immediate missile damage, slot reuse/drops, C2 and malformed
state rejection. Two additional tests cover all four dormant phases with
countdowns 1/2/10/FOREVER, every Mobj field, static/removed slots, unchanged
RNG/events/grid, last patch wins and first free slot order.

Both profiles compare all output felts of the five full replays, their D14
outputs, variable serialized cuts (29/113/47 tics), and terminal boundaries.
The native SimProgram additionally compares 35 cases and rejects four
malformed ABI envelopes in both builds/profiles. No golden was regenerated.
The parent report preserves exact commands and local logs.

```sh
ASDF_SCARB_VERSION=2.16.0 scarb --manifest-path cairo/Scarb.toml --profile proving build -p doom_run
SIM_PROBE=/path/to/sim-probe-lines python3 cairo/doom/doom_game/bench_boundary/measure.py \
  --executables cairo/target/proving --reference /path/reference/proving --json /tmp/abi.json
python3 cairo/doom/doom_game/bench_sizing/compare.py \
  --reference /path/reference --profile proving --json /tmp/replays.json
BENCH_PROFILE=proving python3 cairo/doom/doom_monsters/bench/profile_loop.py \
  --scenario idle --tic 300 --out /tmp/idle300 --keep-trace
python3 cairo/doom/doom_game/bench_boxed/inspect.py \
  --sierra cairo/target/proving/step_tic.executable.sierra.json \
  --profile-dir /tmp/idle300 --tool infra/sierra_words/target/release/sierra_words \
  --json /tmp/idle300-counts.json
```

`inspect.py` checks the executable/input identities saved by the profiler,
uses the same exact frame accounting as `bench/trace_profile.py`, and counts
executed CASM instructions through the pinned `sierra_words` offsets.
Preserve the reference executables before editing sources; build nowhere
inside that reference target. No proof or browser cadence claim is made.

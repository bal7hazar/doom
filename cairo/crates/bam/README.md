# bam

**Does**: Doom's Binary Angle Measurement. `Angle` is a `u32` whose full
range is one turn, with wrapping `add`/`sub`/`neg` and a felt-to-angle
`reduce` for callers that accumulate several increments before wrapping once.
Trigonometry comes from a **packed quarter-wave table**: 2 048 non-negative
magnitudes from which `finesine`, `finecosine`, `sine`, `cosine` and
`sin_cos` rebuild all 8 192 entries of Doom's `finesine` by folding.
`tantoangle` (2 049 entries), `slope_div` (Doom's `SlopeDiv`) and
`point_to_angle` / `point_to_angle2` (Doom's octant-based `R_PointToAngle2`)
complete the crate; angles map to `fixed::Fixed` sines and cosines, and to
fine indices through `angle_to_fine_index`.

**Does not**: do geometry (no points, no lines, no distances — that is
`geom2d`), own any Doom-specific data, or provide `finetangent` (Doom uses
it only for the renderer's slopes, which are never proven here; it can be
added as a fourth table if `doom_physics` ever needs `P_AimLineAttack`'s
`finetangent` path).

**Invariants**:

* every operation on `Angle` is modulo 2^32 and **never panics on
  overflow** — Cairo's `u32 + u32` does, and a panic makes a segment
  unprovable (RISKS R4);
* `angle_to_fine_index` always returns an index in `[0, 8192)`, and
  `finesine`/`finecosine` accept exactly that range;
* `finesine(i) == -finesine(i + 4096)` and `finesine(i) == finesine(4095 - i)`
  hold **exactly** (the `(i + 0.5)` sampling makes the wave symmetric), which
  is what lets one quarter wave stand for the whole table; both identities
  are tested over all 8 192 indices;
* every value returned is a well-formed `fixed::Fixed` (non-negative encoded
  felt below 2^33), so the provability bound of `fixed` holds through this
  crate too.

## Tables: why a quarter wave and no bit-packing

S1 §5.9 turned table size into a per-tic cost: since S0 the bootloader
re-hashes the whole program every segment at `2340 + 14.7 x words`, and one
`const` felt is one word. The rule is: **pack when
`14.7 x (felts saved) / K > (extra steps per access) x (accesses per tic)`**.

| Option | felts | amortized steps/tic at K = 100 | extra steps per lookup | verdict |
|---|---:|---:|---:|---|
| Doom's full `finesine` (10 240) | 10 240 | 1 505 | 0 | rejected |
| **quarter wave (2 048) + folding** | 2 048 | **301** | **~28** (~560/tic over ~20 lookups) | **adopted** |
| quarter wave bit-packed, 3 magnitudes/felt | ~683 | 100 | ~50 (~1 000/tic) | rejected |

The third row is the one S1's "pack the cold bulk data" wording could be
read to recommend; the arithmetic rejects it, because `finesine` is *hot*
(~20 lookups per tic) rather than cold like `REJECT`. Measured, the fold
costs 45 steps against the 11 of a bare `Span` index, i.e. 34 extra steps
per lookup — close to the 28 estimated above.

`tantoangle` stays a flat 2 049-felt table: it is read once or twice per
`point_to_angle` and packing it would add a division to the hottest angle
routine.

## Measured step costs

`bench/` is a standalone Scarb package (outside the workspace, like
`doom_contracts`) with an executable measured by
`scarb execute --print-resource-usage`. `bench/measure.py` is the crate's
**step-budget test**: it re-measures every operation and exits non-zero if
one regresses by more than 10 % over `bench/budgets.json`.

```sh
cd bench && python3 measure.py          # measure + check budgets
python3 measure.py --update             # re-baseline after an intended change
```

Costs are **net of the baseline op that builds the same operands** — with a
loop-invariant operand the compiler hoists the call out of the loop and every
operation appears to cost 1 step.

| Operation | steps (net) | range checks | note |
|---|---:|---:|---|
| `add` | 10 | 2 | stays in `u32`; widening to `u64` costs 16 |
| `sub` | 11 | 2 | |
| `neg` | 10 | 2 | |
| `angle_to_fine_index` | 8 | 3 | one `u32` division |
| `reduce` | 17 | 6 | one `u128` modulo |
| `tantoangle` | 21 | 3 | one `Span` read + a `u32` conversion, both panic-free since S7 (16 with `at`/`unwrap`: the `unsafe-panic` build of Cairo 2.16 crashed on that form, S7 §3) |
| `finesine` | 45 | 4 | two comparisons + index + re-encoding |
| `finecosine` | 58 | 7 | `finesine` plus the quarter-turn wrap |
| `sine` | 51 | 6 | |
| `cosine` | 64 | 9 | |
| `sin_cos` | 76 | 8 | shared quarter-wave fold; previously 109 / 12 |
| `slope_div` | 45 | 12 | two `u128` divisions (Doom's `SlopeDiv`) |
| `point_to_angle` | 126 | 24 | S1 §5.6 measured 138 in the prototype; 118 before S7 |
| `point_to_angle2` | 130 | 24 | one `fixed::sub` more |
| turn + `sin_cos` (player step) | 86 | 10 | representative composite; previously 121 / 14 |

Bytecode: **8 681 words** for the benchmark executable, the two tables
(2 048 + 2 049 felts) and `fixed` included; this harness is not the D29 full-program budget. The shared-fold change
reduces this harness by 8 words but increases the proving `doom_run` program
by 62 words (106 855 → 106 917), so complete-game integration must account
for that fixed program-hash cost as well as the steps saved per call.

Two results that correct S1's expectations:

* **Share the quarter-wave fold, not just the index division.** S1's old
  pair saved only six steps because it still folded two independent lookups.
  The shared fold now saves 33 steps on the existing differential workload;
  opaque four-quadrant comparisons also improve in both dev and proving.
  The magnitudes use complementary indices `q` and `2047 - q`; tables and
  public angle representation stay unchanged. See `spikes/s14-cairo-costs`.
* **`add` is 10 steps, not 25.** S1 measured 25 for a `u64` round trip;
  keeping the wrap inside `u32` (`limit = 0xFFFFFFFF - b`) is 10.

## Tests

`scarb test -p bam` — 20 unit tests (`src/tests.cairo`) + 2 integration
tests (`tests/lib.cairo`):

* **reference values**: 161 `finesine` and 92 `tantoangle` samples taken from
  Doom's own `tables.c`, plus **1 000 `point_to_angle` vectors**. The Doom
  comparisons assert the documented deviation bounds (±1 ulp on `finesine`,
  ±16 BAM on `tantoangle`) and exactness on the anchors; the `point_to_angle`
  vectors are asserted **exactly**, and the generator additionally checks its
  own Python transcription against `atan2` on all 1 000 points (worst
  deviation 328 453 BAM = 0.0275°, the `tantoangle` granularity).
* **shared-fold equivalence**: the first and last angle of all 8 192 fine
  buckets (16 384 angles, including `u32::MAX`) match the unchanged separate
  sine and cosine paths exactly.
* **properties**: `add`/`sub` inverse and commutative over a deterministic
  sweep, wrap at a full turn, `sin(x) = -sin(x + 180°)` and
  `sin(x) = sin(180° - x)` over all 8 192 indices, `sin² + cos² = 1` within
  8 ulp, scale invariance and the 180° property of `point_to_angle`,
  monotonicity of the quarter wave.
* **edge cases**: `0`, `2^32 - 1`, the four cardinal directions and four
  diagonals, `point_to_angle(0, 0) = 0`, `slope_div` with a denominator below
  512 (Doom's `SLOPERANGE` fallback, which the 8 sub-512 vectors pin),
  saturation above 2048, `finesine` at the four quadrant boundaries.

Regenerate the tables and vectors with:

```sh
# tables.c comes from a doomgeneric/Chocolate Doom checkout; it is GPL-2.0
# and is NEVER committed here -- only the numeric samples are.
curl -sL -o /tmp/tables.c \
  https://raw.githubusercontent.com/ozkl/doomgeneric/master/doomgeneric/tables.c
python3 scripts/gen_tables.py --write --tables-c /tmp/tables.c
scarb fmt -p bam
```

## Coverage

`python3 bench/coverage.py` measures line coverage with `cairo-coverage`
0.5.0. The script copies the crate and its siblings to a temporary
directory and patches the manifests there (`snforge_std` instead of
`cairo_test`, gas back on, the three debug-info/inlining flags coverage
requires), because `cairo-coverage` only reads `snforge` traces and
`snforge` cannot compile this workspace as it stands -- `cairo/Scarb.toml`
sets `enable-gas = false` for `doom_run`'s executable target. Lines at or
below a file's `#[cfg(test)]` marker are excluded, so the figure is the
coverage of the code that ships. `cairo-coverage` 0.5.0 emits no `BRF`/`BRH`
records, so **branch** coverage cannot be reported by the tool; line
coverage is the proxy, and since `scarb fmt` puts every branch arm on its
own line a missed arm shows up as a missed line. The script exits non-zero
below 90 % (C7).

`bench/coverage.py` **cannot run for this crate**: coverage requires
`inlining-strategy = "avoid"`, and with it the 4 097 felts of `const` tables
make `universal-sierra-compiler` fail with

```
[ERROR] #2384->#2385: Got 'Offset overflow' error while moving [3] ...
```

The script is kept so that the failure is reproducible and so that the crate
picks coverage up as soon as the compiler handles it (the other four crates
of the geometry stack report 95 % to 100 %).

Coverage is therefore argued here: every public function is exercised, and
every branch of the fold (`idx >= 4096`, `half >= 2048`), of the wrap
(`add`, `sub`, `neg`), of `slope_div` (`den < 512`, clamp, normal) and all
**eight** octant branches of `point_to_angle` are reached by the vectors and
the cardinal/diagonal tests.


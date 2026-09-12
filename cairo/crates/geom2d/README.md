# geom2d

**Does**: the 2D predicates a Doom-like tic evaluates dozens of times.
`Point` and `Box` (Doom's `BOXLEFT`/`BOXBOTTOM`/`BOXRIGHT`/`BOXTOP`),
`DivLine` (Doom's `divline_t`), and — the heart of the crate — the
**stored half-plane predicate** `HalfPlane`: three biased coefficients per
line plus a per-point `hoist`ed term, from which `point_side`,
`point_side_alone`, `point_side_at` (the planar, three-array form),
`point_on_side` (from two vertices, for callers with no stored
coefficients) and `divline_side` (three-valued, for BSP ray traversal)
decide sides.
`bbox_reject` and `box_on_line_side` are the two halves of `PIT_CheckLine`,
in Doom's order. `intercept_fraction` is `P_InterceptVector`,
`approx_distance` is `P_AproxDistance`, `angle_between` forwards to
`bam::point_to_angle2`. `half_plane`, `diagonal`, `box_of_segment` and
`box_around` build the stored data (the first three offline, in `tools/wad`
or `doom_map`; `box_around` every tic, for `tmbbox`).

**Does not**: know what a sector, a linedef or a subsector is (`doom_map`),
descend a BSP (`bsp`), walk a grid (`blockmap`), or own any level data — it
takes spans and structs and returns values. It does not clip movement or
resolve collisions (`doom_physics`).

**Invariants**:

* `cross < 0` is `SIDE_FRONT` (0) and `cross >= 0` is `SIDE_BACK` (1), which
  is exactly `P_PointOnLineSide`'s numbering; a point **exactly on the line
  is back**, as in Doom. `divline_side` adds `SIDE_CROSS` (2) for that case,
  like `P_DivlineSide`.
* Reversing a line's two vertices flips every side (tested on 200 vectors).
* The half-plane sums and the hoisted term stay **below 2^53** for Doom's
  `int16` vertex range, so nothing this crate computes reaches the 2^72
  threshold of S0; asserted over the 1 000 reference vectors.
* `bbox_reject` rejects exactly when the two boxes do not overlap, with
  Doom's `<=` / `>=`: **touching boxes are rejected**. It never rejects a
  segment that really crosses the box (checked against 301 exactly-computed
  crossings).
* Nothing panics: `intercept_fraction` returns `0` on parallel lines, like
  the original.

## The representation, and why

S1 §5.5 measured that what should be stored is neither the line's vertices
nor its fields but **the predicate itself**. For a point whose encoded
coordinates are `X = x + 2^32`, `Y = y + 2^32`:

```text
cross(x, y) = A*y + B*x + C  >=  0
   <=>   Ab*Y + Bb*X + Cb  >=  K*(X + Y) + M
         └─ 3 reads, 2 muls, 2 adds ─┘   └── hoisted, once per point ──┘
```

`A`, `B` are the line deltas in integer map units and `C = ldy*v1x - ldx*v1y`
in raw 16.16; `Ab = A + 2^17`, `Bb = B + 2^17`,
`Cb = C - (A + B)*2^32 + 2^50` make all three non-negative. The right-hand
side is independent of the line, so a loop over a blockmap cell's lines
computes it **once** (3 steps) and then pays 18 steps per line.

Two consequences for consumers, both measured here:

* **Keep Doom's rejection order.** On a line the mobj is nowhere near — the
  common case — `bbox_reject` then `box_on_line_side` costs **29 steps**,
  the inverted order **71**. `bbox_reject` short-circuits (26 steps when the
  first comparison rejects, 57 when all four run) while `box_on_line_side`
  always evaluates both corners (66). The bbox test is also a correctness
  requirement: the half-plane predicate is about the *infinite* line.
* **Store the `diagonal` bit.** One `const` array read picks the pair of
  opposite corners `box_on_line_side` tests, instead of four half-plane
  evaluations.

### Known divergence from Doom

`point_side` uses the **exact** cross product; `P_PointOnLineSide` truncates
both sides of its comparison to 16.16 first (`FixedMul(ldy >> 16, dx)`
against `FixedMul(dy, ldx >> 16)`). The two can only disagree for a point
within one ulp (1/65536 map unit) of the line. `point_on_side_truncated`
reproduces Doom's rounding exactly for callers that need it, at 96 steps
against 18; on 200 random vectors the two agree 200/200. This is the
divergence S1 §7 predicted for vertical lines, and it is resolved in favour
of the exact form (decision D10: faithful Doom-like, not bit-exact).

## Measured step costs

`bench/` is a standalone Scarb package with an executable measured by
`scarb execute --print-resource-usage`; `bench/measure.py` is the crate's
**step-budget test** (it fails at +10 % over `bench/budgets.json`). Costs
are net of the baseline op that builds the same operands.

```sh
cd bench && python3 measure.py          # measure + check budgets
python3 measure.py --update             # re-baseline after an intended change
```

| Operation | steps (net) | range checks | note |
|---|---:|---:|---|
| `hoist` | 3 | 0 | once per point, not per line |
| `box_around` | 4 | 0 | `tmbbox` |
| `point_side` (hoisted) | 18 | 2 | S1 §5.5's figure exactly |
| `point_side_alone` | 21 | 2 | hoists for you |
| `divline_side` | 20 | 2 | three-valued |
| `point_side_at` (planar) | 60 | 5 | +42 for three `Span` indexes, 14 each |
| `point_on_side` (two vertices) | 73 | 12 | rebuilds the predicate; for callers without stored coefficients |
| `bbox_reject`, far line | 26 | 2 | short-circuits on the first comparison |
| `bbox_reject`, overlapping | 57 | 8 | all four comparisons |
| `box_on_line_side` | 66 | 4 | S1 measured 92; its budget was ≤ 100 |
| **`PIT_CheckLine`, Doom's order** | **29** | 2 | bbox first |
| `PIT_CheckLine`, inverted | 71 | 4 | half-plane first — S1 §5.7 confirmed |
| `approx_distance` | 65 | 11 | `P_AproxDistance` |
| `point_on_side_truncated` | 96 | 22 | Doom's rounding, 5x the exact form |
| `intercept_fraction` | 228 | 52 | `P_InterceptVector`: 4 `mul`, 4 `shr8`, 1 `div` |

Bytecode: **4 548 words** for the benchmark executable, `fixed` and `bam`
included.

`intercept_fraction` is the expensive one: 12x a side test. S1 §7's advice
stands — to *order* two intercepts, compare cross products instead of
computing both fractions.

## Tests

`scarb test -p geom2d` — 18 unit tests (`src/tests.cairo`) + 2 integration
tests:

* **reference values** from `scripts/gen_vectors.py`, which computes every
  expectation with exact Python integers **and** cross-checks it against a
  floating-point implementation of the same predicate (1000/1000 agreements;
  the generator aborts on any disagreement away from the line):
  1 000 `point_side` cases (the first ten are the degenerate ones: axis
  aligned lines, points exactly on the line, reversed orientations),
  600 `bbox_reject` cases, 600 `box_on_line_side` cases, 200
  `intercept_fraction` and 200 `approx_distance` cases. The Cairo
  `half_plane` builder is checked against the generator's coefficients on
  all 1 000 lines, so the offline tool and the runtime cannot drift apart,
  and the two-vertex `point_on_side` is checked against the same 1 000
  expectations.
* **properties**: reversing a line flips every side; the hoisted, standalone
  and planar forms agree; `bbox_reject` never drops one of the 301 segments
  that really cross the box (computed exactly with rational Liang–Barsky);
  `approx_distance` is symmetric in its arguments and in their signs; every
  half-plane sum stays below 2^54.
* **edge cases**: horizontal, vertical and both diagonal lines; points
  exactly on the line and one ulp off it; touching, degenerate and
  contained boxes; parallel divlines; zero deltas.

Regenerate with `python3 scripts/gen_vectors.py --write && scarb fmt -p geom2d`.

`cairo-coverage` (0.5.0, installed via asdf) was **not** run: it consumes
`snforge test --save-trace-data` traces and this workspace's runner is
`scarb cairo-test`. Coverage is argued instead: every public function is
exercised, and the vectors reach both outcomes of `point_side`, all three of
`divline_side` and `box_on_line_side`, both `diagonal` values, each of the
four comparisons of `bbox_reject` in isolation, and both branches of
`intercept_fraction` (parallel and not).

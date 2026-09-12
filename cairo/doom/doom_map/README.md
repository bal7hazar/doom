# doom_map

**Does**: owns the **compiled-in level** — Freedoom E1M1, generated from
`tools/wad`'s JSON by `scripts/gen_level.py` into `src/levels/e1m1.cairo` —
and the typed accessors that read it. `LevelMap` is a bundle of spans over
the generated `const` arrays, built by `load(LevelId::E1M1)`; `genesis` gives
the level id and the player start a run begins from. Every array is already
in the representation a generic crate consumes: `geom2d::HalfPlane`
coefficients (biases `2^17` / `2^50`) for linedefs and BSP partitions,
`bsp::Nodes` children with the `0x8000_0000` leaf flag, `fixed`
offset-encoded coordinates and sector heights, `blockmap::Grid` +
`PackedLists` for the blockmap, a bit-packed REJECT, the R2-A9 / D22
`CELL_NODE` location accelerator, and the THINGS of skill 2. `hot` bundles
the per-tic spans (D24) for `doom_physics`.

**Does not**: parse a WAD (that is `tools/wad`, offline TypeScript), hold any
mutable state (an opened door lives in `doom_game`, never in this crate's
constants), implement a rule (`doom_physics`, `doom_specials`), or ship
anything only the renderer needs — SEGS, textures, flats, sidedef geometry,
the VERTEXES lump and the BSP node bounding boxes are all absent, and the
client reads them from `client/public/levels/e1m1.json` instead.

**Invariants**:

* every accessor is total over the level's own index range and pure — the
  same `(level, index)` always gives the same value, and no accessor reads
  game state;
* every generated felt is non-negative and **below 2^72** (PLAN.md A7,
  asserted over every array by `test_every_constant_stays_below_2_pow_72`);
* the generated half-plane coefficients equal `geom2d::half_plane` of the
  linedef's two vertices, on all 1 000 pinned lines, and the generated
  diagonal bit equals `geom2d::diagonal` — so the offline builder and the
  runtime predicate cannot drift apart;
* `subsector_in_cell(cell, p)` returns exactly what `subsector_at(p)` returns
  for every `p` in `cell`;
* REJECT is symmetric and no sector blocks itself;
* the blockmap lists are sorted, deduplicated and in range, and
  `BM_START[cells]` is the total entry count.

## What is compiled in, and why it is shaped that way

S1 §5.9 measured that a `const` array element costs one word of compiled
bytecode (1.02 here, `span()` glue included) and that the bootloader
re-hashes the whole program on every proof segment for `2 340 + 14.7 × words`
steps. Program size is therefore a per-tic cost amortized over K tics, and
the layout of each group is decided by the arithmetic

```text
pack iff  14.7 × (felts saved) / K  >  (extra steps per access) × (accesses per tic)
```

at K = 100, not by taste.

| Group | Layout | Words | Why |
|---|---|---:|---|
| `L_AB` / `L_BB` / `L_CB` | planar | 3 525 | the predicate itself, read tens of times per tic; packing would cost more than it saves at any K |
| `L_BOX_LR` / `L_BOX_BT` | **packed** (2 `enc` per felt) | 2 350 | 2 350 felts saved for **+96 steps** on a full 4-corner unpack; but a `bbox_reject` short-circuits on the `LR` felt alone (48 steps), and the alternative planar form costs 4 700 words = 691 steps/tic amortized |
| `L_PACKED` (flags, special, tag, diagonal, both sectors) | **packed** (63 bits) | 1 175 | S1 §7's worked example: read 2–5 times per tic, saves 4 700 felts |
| `N_AB` / `N_BB` / `N_CB` / `N_CHILD0` / `N_CHILD1` | planar | 3 405 | the BSP descent's inner loop |
| `SS_SECTOR` | planar | 682 | 10+ reads per tic; packing 8-per-felt would save 596 words (88 steps/tic) and cost ~60 steps per read |
| `S_FLOOR` / `S_CEIL` | planar | 364 | `P_LineOpening`, every move |
| `S_META` (light, special, tag) | **packed** | 182 | read only when a special fires |
| `BM_START` / `BM_ITEMS` | planar | 2 929 | `blockmap::PackedLists`, the hottest list in `P_TryMove`; **note this is 1 699 words *less* than Doom's own offset/terminator blockmap** (4 628), because the terminators and the 16-bit offsets disappear |
| `CELL_NODE` | planar | 864 | one read on every location, the whole point of it |
| `REJECT_ROWS` + `POW2` | **packed** (64 bits/felt) | 610 | S1 §7's headline: flat REJECT is 33 124 felts = 4 870 steps/tic amortized, packed is 90 |
| `THINGS` | **packed** (64 bits) | 221 | read once, at genesis |
| scalars | — | 19 | counts, blockmap header, player start, bounds |
| **Total** | | **16 326** | measured at **16 762 words** (D22 removed the 1 578-word candidate lists) |

Two sizing decisions differ from S1 §7's suggestions, both deliberately:

* **REJECT is packed 64 bits per felt, not 124.** 124 bits would put every
  REJECT felt at ~2^124, far above the 2^72 threshold where S0 measured +33 %
  on the `range_check_9_9` component (A7, S1 §7 transverse rule 6). 64 bits
  costs 182 extra words (27 steps/tic amortized) and keeps the rule.
* **S1's "32 767 elements per `const` array" limit is no longer binding.**
  Bit-packing REJECT by rows makes the largest array `BM_ITEMS` (2 064); the
  row-packed REJECT only reaches 32 767 felts at ~1 400 sectors, more than
  any id or Freedoom map has. The generator asserts the limit and says what
  to do if a future map crosses it.

### The VERTEXES lump is not compiled in

A linedef's bounding box *is* its two endpoints (a segment's box is the box
of its endpoints, so they are two opposite corners of it), the stored
`diagonal` bit says which diagonal, and the signs of `ldx = ab − 2^17` and
`ldy = 2^17 − bb` say which end is `v1`. `linedef_v1`/`linedef_v2` recover
both exactly — checked against the WAD's own vertices on 1 000 lines — so
VERTEXES (2 392 words) and a linedef→vertex mapping (1 175) are simply not
needed: **3 567 words saved, 525 steps/tic amortized at K = 100**. Callers
that need a `geom2d::DivLine` for `P_InterceptVector` can use any point on
the line, and `linedef_v1` is one.

### The BSP node bounding boxes are not compiled in

`bsp::point_in_subsector` and `bsp::cross_bsp` never read `Nodes::bbox`; it
is renderer culling data. `nodes()` therefore hands `bsp` an **empty** bbox
span — 5 448 words saved — and `bsp::child_box` must not be called on this
bundle.

## R2-A9, and a correction to the WAD tool's accelerator

`tools/wad` derives a subsector's extent from the bounding box of its SEGS
and lists a subsector for every cell that box touches. That argument needs
the node builder to close each subsector's polygon with segs. **A vanilla
builder emits no minisegs** — all 2 057 of E1M1's segs reference a real
linedef — so a subsector's BSP *region* routinely extends far beyond the box
of its own segs: subsector 630 has two parallel segs spanning y ∈ [−36, 4]
while its region reaches y = −214. On a 200-point lattice over E1M1, **81 of
200 points** land in a cell whose WAD-tool candidate list does not contain
the subsector `R_PointInSubsector` returns for them. The list is not
conservative for the query physics actually makes.

`scripts/gen_level.py` therefore builds the accelerator from the
**regions** instead, and — decision D22 — keeps only the half that answers
in one read:

* `CELL_NODE` — the deepest child id whose region **contains** the whole
  cell (a partition is linear, so its sign over an axis-aligned box is
  decided by the four corners). `subsector_in_cell` starts the descent there
  and answers exactly what a descent from the root answers, **in every case,
  after one `Span` read** — which is what S1 §7 demands of a location
  accelerator ("a partial accelerator is worse than none": the uniform-cell
  shortcut cost 520 steps/tic *more* than it saved).
* The cell → subsector *candidate lists* of the first version
  (`ACCEL_START`/`ACCEL_PACKED`, 1 578 words) were removed by D22: nothing
  in the simulation queries them once `CELL_NODE` exists.

Measured on E1M1: mean descent depth **11.36 from the root, 4.15 from
`CELL_NODE`**, i.e. **1 252 → 789 steps** per location including
`blockmap::cell_of` (92 steps) — and **1 252 → ~690** once the mobj carries
its own cell (R2-A11), a **45 % cut** on what S1 §5.6 found to be 35 % of an
optimized tic.

## Measured step costs

`bench/` is a standalone Scarb package; `bench/measure.py` is the crate's
**step-budget and bytecode-budget test** (it fails at +10 % over
`bench/budgets.json`, or above 20 000 words of data). Costs are net of the
baseline op that builds the same operands.

```sh
cd bench && python3 measure.py          # measure + check budgets
python3 measure.py --update             # re-baseline after an intended change
```

| Operation | steps (net) | range checks | note |
|---|---:|---:|---|
| `subsector_sector`, span hoisted | **9** | 1 | one `Span` read |
| `subsector_sector` through `@LevelMap` | 60 | 1 | **+51 for the snapshot** — see below |
| `descent_start` | 60 | 1 | idem |
| `linedef_half_plane` | 76 | 3 | three reads |
| `linedef_flags` | 76 | 7 | one read, one modulo |
| `sector_floor` + `sector_ceiling` | 76 | 5 | two reads |
| `blockmap` cell list (4 entries) | 101 | 5 | `list_range` + `list_item` ×4 |
| `node_side` | 114 | 8 | `geom2d::point_side_at` |
| `linedef_diagonal` | 150 | 11 | one read, one `u128` div/mod |
| `linedef_box` (packed) | 172 | 32 | two reads, two splits |
| `linedef_special` / `linedef_sectors` | 178 | 21 | one read, two fields |
| `reject` | 198 | 24 | two reads, one bit |
| `sector` (full record) | 222 | 33 | |
| `thing` | 242 | 42 | four fields |
| `linedef_v1` | 335 | 38 | box + two sign tests |
| `linedef` (full record) | 503 | 97 | cold path: tests, `doom_specials` |
| `subsector_in_cell` (R2-A9) | **789** | 65 | `cell_of` included |
| `subsector_at` (descent from root) | 1 252 | 84 | the ground truth |

### The `@LevelMap` snapshot costs ~51 steps per call

`LevelMap` has 24 fields, and Cairo copies all of them at every `@LevelMap`
call site: the same `SS_SECTOR` read costs **9 steps** with the span hoisted
into a local and **60** through the accessor. Every field is `pub` for
exactly that reason. **`doom_physics` hoists the spans it needs once per
operation** (D24) and indexes them directly in its inner loops, keeping the
accessors for cold paths and for readability; the `linedef_*` accessors are
worth the snapshot only outside `PIT_CheckLine`'s per-line loop. `hot(@m)`
returns the `HotMap` bundle of exactly those spans (sector heights excluded:
they are dynamic once a door moves, so the physics takes them from the game
state).

## Regenerating the level

```sh
export ASDF_NODEJS_VERSION=22.22.2
cd tools/wad && npm install
./scripts/fetch-freedoom.sh                      # never commit the WAD
npm run extract -- --wad <freedoom1.wad> --map E1M1 --out /tmp/wadout/
python3 cairo/doom/doom_map/scripts/gen_level.py --json /tmp/wadout/e1m1.json --write
```

The generator prints the per-array word table, re-verifies R2-A9
conservativeness against the arrays it just emitted, fails above
`--max-words` (20 000, docs/G0.md D4), and runs `scarb fmt`. It also writes
`bench/manifest.json`, which `measure.py` cross-checks against the compiled
size — a drift between the two means an array was dead-code-eliminated or the
one-word-per-element rule stopped holding.

## Tests

`scarb test -p doom_map` — **25 tests** (`src/tests.cairo`), against
expectations in `src/tests/vectors.cairo` that the generator computes **from
the WAD JSON**, never from the emitted arrays:

* **generated data vs the WAD**: every lump count, every span length, sector
  and linedef spot values, the 42 non-zero linedef specials and the single
  exit switch, 654 two-sided / 547 blocking lines, the 16 special sectors and
  tags 1–6, 2 064 blocklist entries over 494 non-empty cells with 26 at most;
* **predicate pins**: the generated `(ab, bb, cb)` equal `geom2d::half_plane`
  on 1 000 linedefs, the diagonal bits equal `geom2d::diagonal`, the boxes
  equal `geom2d::box_of_segment`, the recovered `v1`/`v2` equal the WAD's own
  vertices, and the stored predicate agrees with `geom2d::point_on_side` on
  40 line/point pairs;
* **REJECT**: symmetric over all 33 124 pairs (23 490 blocked, 70.9 %), and
  no sector blocks itself;
* **blockmap**: ranges ordered, ids in range, sorted and deduplicated, end
  sentinel correct;
* **accelerator**: on 400 sampled points — a lattice over the whole bounding
  box (which reaches the void) plus 200 subsector centroids — the Cairo
  descent matches the Python one and `subsector_in_cell` equals
  `subsector_at`; every `CELL_NODE` id is in range;
* **things**: 221 of 292 survive the skill-2 filter, each either carries
  `MTF_NORMAL` without `MTF_NOTSINGLE` or is a start, 29 monsters, 12 starts,
  angles are multiples of 45°, positions inside the map bounds, and the
  Player 1 start matches `genesis`;
* **provability**: every element of every array converts to a `u128` and
  stays below 2^72.

## Coverage

`python3 bench/coverage.py` measures line coverage with `cairo-coverage`
0.5.0: **1 test, 105/105 production lines = 100 %** of the accessor code in
`src/lib.cairo`.

It cannot run on the real E1M1 data. `cairo-coverage` refuses to run unless
the manifest sets `inlining-strategy = "avoid"`, and with that flag
`universal-sierra-compiler` fails on this crate with `Offset overflow` --
16 326 felts of `const` arrays push a jump offset past the `i16` the CASM
encoding allows. (Verified: the failure is the *data*, not the tests; it
reproduces with a single one-line test.) The script therefore swaps
`src/levels/e1m1.cairo` for a **miniature level of the same shape** -- five
linedefs chosen to reach all four sign combinations of `linedef_v1`, one BSP
node, two subsectors, two sectors, a 2 x 2 blockmap, a two-row REJECT and two
things -- built by importing `scripts/gen_level.py`, so fixture and shipped
data come out of the same code. What is measured is the accessor code, on
data whose *values* do not matter; the 25 committed tests are what check the
real E1M1 values, under `scarb test`.

On top of the figure: the fixture reaches both arms of every `if` in
`linedef_v1`/`linedef_v2`, both children of the BSP node, a cell whose
descent starts at the root and two whose descent starts at a leaf, a blocked
and an unblocked REJECT pair.

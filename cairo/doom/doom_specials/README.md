# doom_specials

**Does**: owns the **dynamic half of a level** — everything Doom's sector
specials change — and the rules that change it. `SpecialsState` holds the
plane heights that have moved, the light thinkers, the counted secrets, the
spent once-only linedefs and the exit flag; `specials_ticker` runs every
active thinker for one tic; `use_line`, `cross_line` and
`player_in_special_sector` are the three ways a special is started.
Semantics are linuxdoom-1.10's `p_spec.c`, `p_doors.c`, `p_plats.c`,
`p_floor.c`, `p_lights.c` and `p_switch.c`, restricted to what Freedoom E1M1
carries (`tools/wad/REPORT-e1m1.md`): linedef specials **1, 2, 11, 23, 26,
62, 88, 117** and sector specials **1, 7, 9, 12**.

**Does not**: touch geometry. `P_UseLines`' `USERANGE` trace and the
line-crossing test inside `P_TryMove` belong to `doom_physics`, which finds
the line and hands its id over; `P_ChangeSector` — "is a mobj in this sector
now too tall to fit?" — arrives as the one-method `SectorBlocking` callback,
so that `doom_physics` is not a dependency. It does not own the level
(`doom_map` does), does not know what a texture is (a switch is a render
event), does not implement a special this map does not carry (crushers,
teleporters, donuts, elevators, glowing lights, the level timer — and
`scripts/gen_specials.py` **fails** rather than silently omitting a sector if
a future map needs one), and does not keep the `BUTTONTIME` switch timer,
which changes nothing the simulation can observe.

**Invariants**:

* a sector has **at most one plane thinker** (`sec->specialdata`): `EV_Do*`
  skips a sector that already has one, and `EV_VerticalDoor` reverses the
  existing one instead of adding a second;
* a plane never overshoots its destination — `T_MovePlane` clamps exactly at
  it, Doom's strict comparison included, so a plane that lands *on* the
  destination reports `pastdest` only on the following tic;
* a thinker that finishes is removed and **latches** its final height into
  the slot array, so `floor_of` / `ceiling_of` are continuous across the
  removal and no thinker leaks;
* `next_light == next_light_tic(lights)` always (a derived cache, asserted by
  the tests);
* a once-only linedef fires exactly once: its id joins `used` and
  `line_special` reports 0 for it forever after;
* a secret counts once: `sector->special` is cleared with the tally;
* every serialized felt is non-negative and below 2^72 (PLAN.md A7).

## The contract with `doom_physics` and `doom_game`

**Sector heights are read from here, never from `doom_map`.**
`doom_map::sector_floor` / `sector_ceiling` return the level's *initial*
heights; a lift parked at the bottom or a door standing open is invisible to
a caller that reads them. `P_LineOpening`, gravity, `P_CheckSight` and the
renderer go through

```cairo
let tables = doom_specials::sector_tables(@m, @lm);   // once per segment
let view   = doom_specials::heights(@state, tables);  // once per tic
let floor  = doom_specials::floor_of(@view, sector);  // in the inner loop
let ceil   = doom_specials::ceiling_of(@view, sector);
```

`sector_tables` hoists the four level spans out of the two bundles
(`doom_map::LevelMap` alone costs ~51 steps per `@` call, D24); `heights`
adds the three that come from the state. Taking the view once per tic and
indexing it is the difference between 42 steps a read and ~120.

Two interfaces are **expected from the rest of the game**, both deliberately
tiny, because `doom_physics` is being written in parallel with this crate:

| Interface | Who implements it | What it is |
|---|---|---|
| `SectorBlocking::nofit(sector, floor, ceiling)` | `doom_game`, over `doom_physics`' blockmap walk | `P_ChangeSector(sector, crush = false)` (p_map.c): with the planes there, is any mobj in the sector too tall to fit? A closing door reverses when it answers yes. `NeverBlocked` is the stand-in until then. |
| `Actor { is_player, blue_key }` | `doom_game`, from `player_t` | Everything `P_UseSpecialLine` and `P_CrossSpecialLine` read off the `mobj_t` that touched the line. |

And `doom_game` is expected to call, per tic, in Doom's own order
(`P_Ticker`): the triggers first (from `P_PlayerThink` / `P_TryMove`), then
`specials_ticker`, then `player_in_special_sector`. It turns
`SpecialsState::exit` into D14's `status = 2 (EXIT)`, adds `secrets` to the
segment output, and splices `serialize` into the `GameState` buffer.

## Why the dynamic state is not a full array

Doom keeps the mutable sector fields *in* `sectors[]`. Cairo has no in-place
array write, so a full 182-sector array would be rebuilt on every tic a door
moves — 182 appends, ~1 500 steps — and hashed in full every time the state
is sealed (D16). Two observations remove the need:

1. **Which sectors can ever change is static**, and
   `scripts/gen_specials.py` derives the set from the map: the back sector of
   every manual-door line, the tagged sectors of every remote door / lift /
   floor line, the light-special sectors and the secret sectors. On E1M1 that
   is **15 ceilings, 5 floors, 9 lights and 13 clearable specials**, not 182.
   So the state is one small array per kind of change, indexed by a generated
   slot; a sector without a slot always reads `doom_map`. A write copies 15
   felts, not 182, and the whole dynamic sector state is **33 felts**.
2. **A plane that is moving right now lives in its thinker** — exactly what
   `sec->specialdata` points at in Doom — so the slot array is written
   **once**, when the thinker finishes and latches its height, instead of
   every tic. `ceiling_of` looks at the (short, usually empty) mover list
   first, then the slot array, then `doom_map`.

That is the *dirty-list* answer to the full-array/dirty-list question, with
the lookup made O(1) by a generated `sector → slot` map rather than a scan.
Serialization is proportional to what can change, not to the level: **10
steps per dynamic sector slot** against 30 budgeted.

The one deliberate departure from vanilla's representation is the light
thinker's timer: Doom counts down (`if (--flash->count) return;`), this
crate stores the **absolute tic of the next flip**. The two hold the same
information (`count = next - tic`), and the absolute form lets the ticker
skip all nine of E1M1's always-running light thinkers with a single
comparison on the 39 tics out of 40 where none is due —  1 step instead of
~200. `scripts/reference.py` models the vanilla countdown and the tests
compare the two tic by tic.

`Mover` likewise drops Doom's `speed`, `topwait` and slot back-pointer: all
three are constants of the thinker's kind or one table lookup away
(`speed_of`, `wait_of`, `slot_of`), so they are derived rather than stored —
three felts less in the hashed state and one source of truth. (Measured, it
buys no steps: the per-tic cost of carrying a thinker is the array rebuild,
not the field count.)

## The generated tables

`scripts/gen_specials.py` reads **`doom_map`'s own compiled constants** — no
WAD, no `tools/wad` run — so the tables cannot drift from the map they
describe, and regenerating is one command:

```sh
python3 cairo/doom/doom_specials/scripts/gen_specials.py --write
```

| Group | Layout | Words | Why |
|---|---|---:|---|
| `CEIL_SLOT` / `FLOOR_SLOT` / `LIGHT_SLOT` / `SPECIAL_SLOT` | planar | 728 | `doom_physics` reads a sector height through the first two tens of times per tic; packing would add ~25 steps to every read |
| `ADJ_START` + `ADJ_PACKED` | start planar, ids **packed** 8 × 8 bits | 250 | `getNextSector` over `sec->lines`, deduplicated — read only when a special fires, so `14.7 × 454 / 100 = 67` steps/tic saved beats `50 × 0.03` |
| `TAG_KEYS` / `TAG_START` / `TAG_PACKED` | keys planar, items packed | 36 | `P_FindSectorFromLineTag`, same arithmetic |
| `*_SECTORS` (slot → sector) | planar | 42 | read once, at `P_SpawnSpecials` |
| `SHIFT8` | planar | 8 | the packed-felt shifts |
| **Total** | | **1 064** | measured at **1 194 words** (`load`'s `span()` glue) |

Sector adjacency replaces Doom's `sec->lines` because every
`P_Find*Surrounding` is a min or a max over the *neighbours'* heights or
light levels — duplicate lines between the same pair of sectors cannot
change an answer — and it is roughly half the size. A two-sided line facing
the same sector on both sides makes that sector its own neighbour, as
`getNextSector` does; E1M1 has 7 such lines.

## Measured step costs

`bench/measure.py` is the crate's **step-budget and bytecode-budget test**
(it fails at +10 % over `bench/budgets.json`, or above 3 000 words of data).
Costs are net of the baseline op that builds the same operands.

```sh
cd bench && python3 measure.py          # measure + check budgets
python3 measure.py --update             # re-baseline after an intended change
```

| Operation | steps (net) | range checks | vs target |
|---|---:|---:|---|
| `ceiling_of`, static sector, view hoisted | **42** | 1 | — |
| `floor_of`, slotted sector | 50 | 2 | — |
| `specials_ticker`, 0 thinkers | 123 | 1 | target 50 |
| `specials_ticker`, E1M1's 9 lights | 319 | 9.2 | **21.8 per light**, target 60 ✓ |
| …per running door (moving) | 350 | 6 | target 150 |
| …per running lift (moving) | 377 | 6 | target 150 |
| …per running door (waiting) | 207 | 6 | target 150 |
| `use_line`, manual door | 1 202 | 99 | target 400 |
| `find_lowest_ceiling_surrounding` | 538 | 68 | — |
| `serialize` (114 felts) | 1 164 | 38 | **10 per dynamic sector slot**, target 30 ✓ |
| `fields` | 82 | 8 | — |

Three targets are missed, and the measurements say why rather than the
budgets being relaxed quietly:

* **The empty ticker costs 123 steps, not 50.** 35 of those are the call
  itself — `SpecialsState` is seven spans plus two scalars, so eleven felts
  go in and eleven come out whatever the function does — and the rest is the
  two skip tests and the (empty) event array. Hoisting the level side into
  `SectorTables` already took this from **269** to 123 by removing the
  `@LevelMap` (24 fields) and `@SpecialsMap` (14 fields) snapshots from the
  per-tic path; what is left is the state's own width. It is the floor for
  "return a nine-field record unchanged" in Cairo 2.16.
* **A running thinker costs 207 steps before it does anything.** Measured
  against a door that only counts down, that is the mover list being rebuilt
  (Cairo arrays are append-only) plus the dispatch. Shrinking `Mover` from
  ten fields to seven changed it by **1 step**, and collapsing the five-arm
  match to three by **0** — the cost is the `Array`/`Span` round trip, not
  the payload. Moving a plane adds ~145 on top (`T_MovePlane`, the
  `nofit` callback and the `SECTOR_MOVED` cue). E1M1 never has more than a
  handful of movers at once, so the realistic worst case is ~1 000 steps of
  a ~30 000-step tic.
* **`use_line` costs 1 202 steps**, three quarters of it
  `P_FindLowestCeilingSurrounding` walking the packed adjacency. Unpacking
  an 8-bit id costs ~60 steps against a planar read's 9, and storing
  adjacency planar would fix that — but it would cost 454 extra words, which
  by `doom_map`'s own arbitration rule (`pack iff 14.7 × felts_saved / K >
  extra_steps × accesses_per_tic`, K = 100) is **67 steps per tic, every
  tic**, against ~150 steps on a trigger that happens at most once per Use
  press. Packed wins by more than an order of magnitude; `use_line` pays for
  it, and amortized over 35 tics it is 34 steps per tic.

Bytecode: **1 194 words** of generated tables (`bench/size` −
`bench/baseline`, same crate graph and the same accessor code on both sides;
analytic total 1 064 plus `load`'s `span()` glue), budget 3 000. At
`2 340 + 14.7 × words` that is ~19 900 steps of bootloader program-hashing
per proof segment.

## Tests

`scarb test -p doom_specials` — **30 tests** (`src/tests.cairo`), against
`src/tests/vectors.cairo`, which `scripts/reference.py` computes from an
independent Python transcription of the vanilla thinkers reading the same
E1M1 constants. Two things are modelled the *vanilla* way there on purpose,
so the Cairo side's shortcuts are checked rather than mirrored: the light
thinkers count down, and the sector state is a full per-id array.

```sh
python3 scripts/reference.py            # run the model, print a summary
python3 scripts/reference.py --write    # regenerate src/tests/vectors.cairo
```

* **reference values**: the nine light thinkers `P_SpawnSpecials` creates and
  the three `P_Random` draws they consume (a synchronised strobe draws none);
  the `topheight` of all 25 manual-door lines
  (`P_FindLowestCeilingSurrounding − 4 × FRACUNIT`); every tagged special's
  sectors; the nine light levels every ten tics for 200 tics; and a scripted
  **700-tic run** that uses the first DR door (linedef 55 → sector 10) at tic
  10, the first switch lift (linedef 594, tag 1 → sector 98) at tic 200 and
  walks the repeatable lift trigger (linedef 593) at tic 400 — 28 sampled
  heights, the six phase-change tics (door open at 72, closing at 222 =
  72 + `VDOORWAIT`, gone at 285; lift at the bottom at 234, back up at 339 =
  234 + `PLATWAIT`, gone at 374) and a checksum folding every tic of the run;
* **properties**: a door's ceiling is monotone between its endpoints and
  never leaves them, no thinker leaks and the final height is latched, a W1
  line fires once while SR and WR repeat, the `next_light` cache always
  equals `min(lights.next)`, a quiet tic returns an identical state, the
  serialized record is exactly as long as `fields` promises and every felt is
  below 2^72;
* **edge cases**: a door re-triggered while closing reverses, one
  re-triggered while open closes for a player but not for a monster ("JDC:
  bad guys never close doors"), a lift re-triggered while waiting is ignored,
  the blue door needs the key and a monster never gets in, a secret counts
  once and only with both feet on the floor, the exit switch sets EXIT on the
  spot, a blocked door goes back up, the back side of a line is not usable,
  a monster may trigger the walk lift but not the W1 door, and the blazing
  door moves four times a normal one's distance per tic.

## Coverage

`python3 bench/coverage.py` measures line coverage with `cairo-coverage`
0.5.0: **491/492 production lines = 99.8 %**.

It cannot run on the real E1M1 data, for the same reason `doom_map`'s cannot:
`cairo-coverage` refuses to run unless the manifest sets `inlining-strategy =
"avoid"`, and under that flag `universal-sierra-compiler` fails with `Offset
overflow` on any program linking `doom_map`'s 17 904 felts of `const` arrays.
The copied tree therefore gets a **miniature level of the same shape**, built
by importing `doom_map`'s `scripts/gen_level.py` and this crate's
`scripts/gen_specials.py` so that fixture and shipped data come out of the
same emitters. It carries one of every special implemented here — a DR door,
a blue-key one, a secret one, a blazing one, a W1 remote door, an SR lift, a
WR lift, an S1 floor, an S1 exit switch, flashing, strobing, secret and
damaging sectors, a two-sided line facing itself, a manual door with no back
sector, a switch whose tag no sector carries — and `src/tests.cairo` is
replaced by a module that drives all of them. What is measured is the
coverage of the **rules**, on a map whose sector ids do not matter; the 30
committed tests are what check the real E1M1 values, under `scarb test`.

The single uncovered line is the `NO_SLOT` arm of the thinker-removal path,
which is unreachable by construction (`EV_Do*` refuses to start a thinker on
a slotless sector) and exists so the function stays total instead of
panicking on a hypothetical bad table (R4-A2).

## Transitional

`src/compat.cairo` still exports the Phase-0 skeleton's `Door`, `DoorState`,
`start_opening` and `think_door`, re-exported at the crate root, because
`doom_game::spawn_sample_door` imports them. That is the `doom_specials` half
of the D17 clean-up; it disappears with the PR that ports `doom_game` onto
`SpecialsState`. Nothing in the real code path touches it.

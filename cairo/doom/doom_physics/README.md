# doom_physics

**Does**: the movement, collision, sight, hitscan and damage rules of a
Doom-like tic, over `doom_map`'s compiled-in level and `doom_things`'
tables — the `p_map.c`, `p_maputl.c`, `p_mobj.c`, `p_sight.c` and
`p_inter.c` half of linuxdoom-1.10 (GPL-2.0-only; semantics derived, no C
copied), as pure functions on a `Mobj` value:

* `Mobj` (27 felts, `push_felts` is the serialization schema for
  `doom_game`) and the fixed-capacity list helpers (`push`, `replace`,
  `first_free`, `removed_mobj`, `MAX_MOBJS`);
* `ThingGrid`, the blockmap's per-cell thing lists (`link`/`unlink`/
  `things_in`/`rebuild`), with `set_thing_position`/`unset_thing_position`/
  `place`/`locate` keeping `cell`, `subsector`, `sector` in sync (R2-A11);
* `check_position`/`try_move` (`PIT_CheckLine` in Doom's order,
  `PIT_CheckThing`, the four height rules), `slide_move` (vanilla, three
  traces) and `slide_move_lite` (the documented fallback), `xy_movement`
  (`MAXMOVE`, halves, friction, `STOPSPEED`) and `z_movement` (gravity,
  floats, clamps);
* `check_sight` (REJECT first, then the vanilla opening/slope test on every
  crossed line) and `check_sight_cached` (R2-A3);
* `traverse`/`path_traverse` (`P_PathTraverse` over the blockmap ray),
  `aim_line_attack` and `line_attack` (`PTR_AimTraverse`, `PTR_ShootTraverse`,
  puffs and blood as events);
* `damage_mobj`/`kill_mobj` (thrust, pain chance through `prng`, `MF_JUSTHIT`,
  retaliation, death and gib states through `fsm::enter`, the zombieman's
  clip and the shotgun guy's shotgun as dropped items);
* `spawn_mobj`, `spawn_map_thing`, `spawn_player`, `spawn_missile` (the
  imp's fireball, `P_CheckMissileSpawn` included), `explode_missile`,
  `set_state`.

**Does not**: run the tic loop, own the mobj list or apply anything to a
mobj other than the one it was handed — every cross-mobj effect is
reported (`MoveEvent::{CrossSpecial, Touch, MissileHit}`, `Hit`, the
dropped item, `DamageOutcome`) and `doom_game` applies it; dispatch state
actions (`fsm` returns the action id, `doom_monsters`/`doom_player` run it);
implement a monster's or the player's decisions (`P_Move`, `A_Chase`,
`P_PlayerThink`, weapons, armor, pickups' effects); move sectors
(`doom_specials` — the crate reads the *current* heights it is given).

**Invariants**:

* `try_move` never leaves a thing straddling a blocking line, standing
  where `ceiling - floor < height`, up a step over 24 units or (for a walker
  without `MF_DROPOFF`/`MF_FLOAT`) over a ledge deeper than 24 — the 300
  E1M1 moves of `scripts/model.py` agree bit-exactly, `floorz`/`ceilingz`/
  `dropoffz` included;
* after a move, `cell` is `blockmap::cell_of(x, y)` (or `NO_CELL` off the
  grid), `sector` is the sector of `(x, y)`, and the thing is linked in
  exactly one cell of the grid;
* `z_movement` keeps `floorz <= z` and `z + height <= ceilingz`; friction
  brings a walker's momentum to exactly zero;
* `check_sight` answers what Doom's BSP walk answers (500 E1M1 pairs, both
  the REJECT verdict and the traversal, against an exact-rational and a
  float model);
* a hitscan hits the nearest blocking crossing, in Doom's order (200 E1M1
  shots against a float ray cast); every crossing is processed once;
* no `Array` is built on the `try_move` path (R2-A10); every felt written
  to memory stays below 2^72 (A7); nothing on the proving path panics on
  game data (a full list refuses a spawn, an off-grid thing hits nothing).

## Shape, and the decisions behind it

**Every internal call is narrow (S7).** `World` is passed once, at the
public entry point; inside, a function takes a five-felt [`Level`] (the
`HotMap` behind a `Box` — a field read through the pointer is free — plus
the two height spans), the moving thing as the eleven fields
`P_CheckPosition` reads (`Mover`) or as a `Box<Mobj>` re-boxed only when
it moves, and every loop lives in its own small function with a narrow
return type and **no panic site**: in Cairo 2.16 a panic site costs the
enclosing function its whole return width in bytecode (the `PanicResult`
store is zero-padded to the widest variant), a return is copied into every
branch that reaches it at that same width, and a struct pushed at a call
costs one word and one step per felt. docs/spikes/S7.md measures each of
those rules; `bench/attribute.py` shows where every word of this crate
goes.

**A mobj is a value; the list is an `Array<Mobj>` rebuilt by the tic loop.**
S1 §7 measured a `Felt252Dict` at 51 steps per insert/get pair on every
access of every tic, against 11 for a `Span` read; the tic loop copies each
mobj once anyway. A write to a mobj the loop has already passed (a missile
spawned later in the list hitting the player at index 0) is `replace`,
measured at **22 700 steps on a 210-slot list (108 per slot)** — so
`doom_game` should batch such patches and apply them in one rebuild at the
end of the tic, and write forward patches in place as its pass reaches the
index. A removed mobj keeps its slot (`removed_mobj`, `KIND_NONE`) so that
every `target` index stays valid; `first_free` finds one to reuse.

**The blockmap's thing lists are a `Felt252Dict<Nullable<Span<u32>>>`
keyed by cell** (`ThingGrid`). Doom's `bnext`/`bprev` pointers cannot live
in an immutable array; here a cell's list is read with one dict `get` and
rewritten (a handful of appends) only when a thing changes cell — a thing
that stays in its cell, the common case, costs nothing. The grid is derived
data (`rebuild` recreates it from the mobjs' `cell` fields at the start of a
segment) and is not part of the hashed state. Doom links every mobj without
`MF_NOBLOCKMAP`; so does this crate, and `PIT_CheckThing` skips what cannot
collide, exactly as in C — so a corpse needs no relink when `A_Fall`
clears `MF_SOLID`.

**`try_move` locates once, and only when it must.** Doom descends the BSP
twice per successful move (`P_CheckPosition` for the destination sector,
`P_SetThingPosition` after). The descent is the most expensive step of a
move (`locate`: **740 steps** with `CELL_NODE`, D22, and more where the
cell's node is near the root), so `check_position` folds the straddled
lines' openings first and descends only if a line was straddled or the step
is longer than the radius (a missile): a shorter step that straddles nothing
cannot have crossed a linedef, so the sector is unchanged. `subsector` is
then the one of the last relocation (nothing in the physics reads it; the
sector is what REJECT and the heights use).

**Line-of-sight walks the blockmap ray, not the BSP.** `doom_map` compiles
no SEGS in, so the subsectors' lines are not available at run time. The
crate walks the cells the sight line crosses (`ray::Ray`, Doom's DDA in
trace fractions, four divisions up front and none after) and applies
`P_CrossSubsector`'s test to every linedef of every cell. The verdict is a
pure function of the *set* of crossed lines — `topslope`/`bottomslope` only
narrow, a one-sided line or a closed opening blocks regardless of order —
so the two walks agree; `scripts/model.py` checks an exact transcription
of this walk against a float transcription of Doom's own BSP walk on every
emitted pair (500/500). S1 §7 recommended this ("ligne de vue par rayon
blockmap"). A line in two visited cells is tested twice (S1 §7 rejects
cross-cell deduplication at 4.6×); the second test re-narrows to the same
slopes.

**Hitscans process the crossings cell by cell.** The ray's segment inside
cell *k* spans the fractions `[entry_k, entry_k+1)`, and a listed line is
crossed *in that cell* exactly when its `P_InterceptVector` fraction lies
in the span; the cell's few crossings (plus the things whose centre is in
the cell, as Doom finds them) are sorted and handed to a `Traverser`, and
the walk stops at the first refusal. Measured, this took the 1 740-unit
shot down E1M1's hall from **58 000 to 8 500 steps** (a global sort was
22 000 of it) and a room shot to 6 600.

**Puffs and blood are events.** `Hit::Wall`/`Hit::Thing` carry the point
where `P_SpawnPuff`/`P_SpawnBlood` would have put one. As a mobj each would
cost a `locate` (740) plus a slot, a link and four state transitions, for a
purely visual effect the simulation never reads back; `doom_game` hands the
hit to the renderer through its snapshot instead. `spawn_missile` and the
item drops stay mobjs (the simulation does read them back).

**The sight cache (R2-A3)** keeps the verdict on the looker for `ttl` tics
while the target has not changed sector; the three cache fields are part of
the serialized record, so a segment restarted from a hash behaves like the
continuous run.

### Serialization schema

`push_felts` appends the 27 felts of a mobj in this order:

```text
kind, x, y, z, angle, momx, momy, momz, radius, height, flags,
health + 2^31, state, tics, target, reaction_time, threshold,
move_dir, move_count, cell, subsector, sector, floorz, ceilingz,
sight_expires, sight_sector, sight_ok
```

`Fixed` fields are their `enc` (< 2^33), `health` is signed (a gibbed corpse
is below `-spawnhealth`) and biased by 2^31, everything else is a `u32` or
a bit — every felt is non-negative and below 2^72 (asserted by
`test_serialization_schema`). Doom's `sprite`/`frame` are derived from
`state` by the renderer; `lastlook` and the spawn point are not needed in a
single-player run.

### Known departures from vanilla

* The *set* of tested lines comes from the blockmap (see above); the
  three-valued `P_DivlineSide` is kept for sight, the exact `geom2d`
  predicates elsewhere (D10: faithful, not bit-exact).
* A shot on a sky ceiling still reports a puff (`doom_map` carries no flat
  names); missiles hitting a sky wall explode instead of vanishing.
* `check_position` remembers at most `MAX_SPECIAL_CROSS = 4` straddled
  special lines (Doom: 8); no move on E1M1 straddles more.
* `P_ShootSpecialLine` is not reported (E1M1 has no gun-activated special).
* `spechit` is deduplicated (Doom relies on `validcount`), so a special line
  listed in two cells fires once.

## Measured step costs

`bench/` is a standalone Scarb package; `bench/measure.py` is the crate's
**step-budget and bytecode-budget test** (it fails at +10 % over
`bench/budgets.json`). Every scene is on the real Freedoom E1M1, in the
start hall (the open area east of the Player 1 start), with one linked
player moved back and forth by 4 units so that nothing is hoisted and the
thing grid does not grow. Costs are net of the baseline op that builds the
same operands.

```sh
cd bench && python3 measure.py          # measure + check budgets (both feature sets)
python3 measure.py --update             # re-baseline after an intended change
python3 attribute.py                    # words per function / helper / stored type / panic path
python3 size_avoid.py                   # the bytecode under both inlining strategies
```

| Operation | steps (net) | range checks | task budget | note |
|---|---:|---:|---:|---|
| `try_move`, 1 cell, ≤ 8 lines, no things (player) | **865** | 37 | ≤ 1 000 | 964 before S7; no descent (see above) |
| `try_move`, 1 cell, one thing checked | 930 | 41 | — | +65 for one `things_in` read and one `PIT_CheckThing` |
| `try_move`, monster whose box spans 2 cells (the doorway) | 3 575 | 306 | — | the doorway cells are line-dense (4 316 before S7) |
| `check_sight`, REJECT answers | 313 | 20 | ≤ 100 | `reject_of` 72 + ~20 in the crate; the rest is the public call pushing the 67-felt `World` and two 27-felt `@Mobj` |
| `check_sight`, 300 u across the hall, visible | 6 172 | 905 | ≤ 2 500 | 3 cells, 39 candidate lines (22 dismissed on the packed box at ~45, 13 on the side tests at ~130), 4 crossings with slopes at ~550 (7 703 before S7) |
| `check_sight`, 900 u down the hall | 8 059 | 1 202 | — | 9 715 before S7 |
| `line_attack`, wall 188 u away (a room shot) | 5 208 | 786 | ≤ 8 000 | stops at the first wall (6 608 before S7) |
| `line_attack`, wall 1 740 u away | 6 906 | 977 | ≤ 8 000 | 14 cells (8 478 before S7) |
| `aim_line_attack`, 1 024 u, wall at 188 | 4 985 | 759 | — | 6 339 before S7 |
| `xy_movement` + `z_movement`, walking player | 1 477 | 82 | ≤ 300 | includes the 865-step `try_move` (1 704 before S7) |
| `set_thing_position`, same cell | 882 | 65 | ≤ 900 | `locate` 665 + one relink (none when the thing is already last in its cell) — 1 158 before S7 |
| `locate` | 665 | 63 | — | `cell_of` + the `CELL_NODE` descent |
| `damage_mobj`, pain + thrust | 1 240 | 83 | — | `point_to_angle2`, `sin_cos`, two RNG draws (1 471 before S7) |
| `spawn_mobj` | 1 069 | 90 | — | `locate` + `info_of` + `state_entry` |
| `replace`, 210-slot list | 20 851 | 4 | — | 99 per slot |
| `slide_move` (vanilla), wall 24 u ahead | 11 088 | 1 393 | — | three traces (4 divisions each) + two `try_move` (16 314 before S7) |
| `path_traverse`, 188 u, lines + things | 2 993 | 451 | — | the collector, for tests |

Where the budgets are missed, the profile (`cairo-profiler`, method of S1
§2; docs/spikes/S7.md §5) says why:

* **A sight traversal is now dominated by its crossings.** A candidate
  line the trace's bounding box excludes costs ~45 steps (one read of the
  packed `L_BOX`, one `u128` divmod, two comparisons), one that reaches
  the side tests ~130, and a crossed two-sided line with a height
  difference ~550: `P_InterceptVector` (4 `mul`, 4 `shr8`, 1 `div`) and
  one or two slope `div`s, Doom's arithmetic to the bit. The 300-unit hall
  trace has four such crossings — 2 200 steps before a single candidate is
  looked at — so ≤ 2 500 is out of reach for it without changing the
  arithmetic (D10 would allow an exact-rational slope test; S7 §5 costs
  it) or the candidate set (a per-line "never blocks sight" flag kept by
  `doom_game`, S7 §7). The levers in the callers stand: the R2-A3 cache
  (`ttl` ≥ 8), `A_Look` at 1/4 cadence, `A_Chase` asking only when
  `movecount` reaches zero.
* **`xy_movement` + `z_movement` at 1 477** is the 865 of `try_move` plus
  the passes, the clamp and the friction; the public call itself pushes the
  67-felt `World` and the 27-felt `Mobj` (94 steps) that a narrower
  `World` for `doom_game` would save (S7 §7).

### Bytecode

`bench/size` calls every public entry point once on the loaded level,
`bench/baseline` loads and touches the same data and calls none: the
difference is the crate's code in the program the bootloader re-hashes
every segment (S1 §5.9). **35 873 words** with the default features,
**32 678** without `vanilla_slide` (the stairstep alone) — down from
**56 961** before docs/spikes/S7.md, for the same API and the same
results. `measure.py` guards both figures against regression (+10 %) and
prints the 12 000 S7 set out to reach; `attribute.py` attributes every
word (`infra/sierra_words` compiles the Sierra to CASM exactly as
`cairo-execute` does and gives each statement its offset range).

Where the words went, and where they go now (S7 §1-2):

| words | before S7 | after | how |
|---|---:|---:|---|
| `store_temp<PanicResult>` — the zero-padded return enum stored at every panic site and every return point, at the function's whole return width | 17 558 | 2 822 | panic-free loops and primitives (`get` + `match`, wrapping counters, `felt_ge_narrow`, `to_u128`, `NonZero` literals), narrow return types, one return per wide function |
| `World` (67 felts) and `Mobj` (27) pushed at calls | 4 650 | 1 660 | `Level` (5 felts), `Mover` (11), `Box<Mobj>` |
| comparisons (`u128s_from_felt252` + `U128PartialOrd`) | 8 500 | 4 640 | `felt_ge_narrow`: 38 words per site against 57 |
| constant-argument specialisations (a second copy of a loop body) | ~4 000 | ~260 | no literal as a loop-carried start (`opaque_zero`), opaque harness arguments |
| two monomorphisations of `traverse` | 6 000 | 1 110 | one concrete walker, a small generic dispatch |
| the rest: the algorithm's own comparisons, reads and divmods (~15 words per comparison, ~11 per `Span` read, ~10 per `u128` divmod) | | ~25 000 | see S7 §6 for what a 12 000-word physics would have to give up |

A Cairo function's bytecode grows with what it pushes at each call, what
it re-stores at each branch merge and at each return, and with every
panic path; S7 §8 turns the measurements into the code-style rules for
`doom_player`/`doom_monsters`/`doom_game`.

## Tests

`scarb test -p doom_physics` — **30 tests**:

* **reference vectors** (`src/tests/e1m1.cairo`, from `scripts/model.py`
  over the WAD JSON, never from the Cairo code): 300 random E1M1 moves
  (187 accepted, 113 blocked) bit-exact on the verdict, the blocking line,
  `tmfloorz`/`tmceilingz`/`tmdropoffz`, the crossed specials and the cached
  cell; 40 friction runs of 12 tics; 500 sight pairs (126 REJECTed, 288
  blocked, 86 visible) against the exact walk *and* the float BSP walk;
  200 shots (line hit exact, puff within 2 units); the 350-tic scripted
  walk from the Player 1 start through the start room's doorway and back,
  checked at every 50th tic against the model and against a **pinned
  Poseidon checksum** of all 350 serialized states;
* **damage / pain / death chains** against `info.c`: painchance through
  `rndtable` from cursor 1, `MF_JUSTHIT`, retaliation and `BASETHRESHOLD`,
  death and gib states, quartered height, the clip and shotgun drops with
  `MF_DROPPED`, the barrel's silence, a corpse taking no damage;
* **things**: blocking, `Touch` for a `MF_PICKUP` mover only, `MissileHit`,
  over/under, a missile sparing its kin;
* **properties**: `z` between floor and ceiling while falling and landing
  hard; momentum decaying to exactly zero; `cell` equal to `cell_of` after
  every accepted move; `locate` equal to `doom_map::subsector_at`; every
  E1M1 map thing spawning on its floor (or hanging from its ceiling) with
  29 monsters and the ambush flag; the serialization schema below 2^72;
* **edge cases** (`src/tests/synthetic.cairo`, a six-sector strip the module
  builds itself out of `geom2d` predicates): a 16 step, a step of *exactly*
  24, a 32 step, a 32 ledge (player drops, monster refuses, floater
  ignores), a 8-unit gap, a closed door (zero opening), the ceiling rule and
  `floatok`, teleport and noclip, one-sided walls, `ML_BLOCKING`,
  `ML_BLOCKMONSTERS`, a special crossed vs straddled, a diagonal wall, box
  corners on a wall's end, the void off the grid, the same special listed in
  two cells; slides along and perpendicular to walls, the diagonal
  projection, the stairstep; `MAXMOVE` halving, `STOPSPEED` with and
  without input, air, corpses, missiles; gravity, hard landings, ceilings,
  floaters; sight through steps, a closed door, a low ceiling, REJECT, the
  cache; a shot along a wall the shooter touches, from exactly on it, at
  max range, into the top wall, at and over a monster, through a corpse,
  at a closed door.

## Coverage

`python3 bench/coverage.py` measures line coverage with `cairo-coverage`
0.5.0 (the method of the other crates: a patched copy of the
`cairo/{crates,doom}` tree, `doom_map`'s miniature level in place of E1M1 —
the real data does not compile under `inlining-strategy = "avoid"` — and
the self-contained `synthetic` module as the test suite):
**14 tests, 741/784 production lines = 94.5 %**. The misses are the
`MF_SKULLFLY` arms (no lost soul on E1M1), the `mass == 0` guard, the
fall-forward RNG branch, `Ray`'s westward/southward border stops and the
`MAX_SPECIAL_CROSS` overflow arms.

## Regenerating

```sh
# The WAD JSON of tools/wad (never committed), see doom_map/README.md.
python3 scripts/model.py --json /tmp/wadout/e1m1.json --write
scarb fmt -p doom_physics
```

`model.py` prints how many sight pairs it dropped for disagreement between
its two models or for a thin slope margin (0 and 0 on E1M1, seed 1), and
refuses to write if the walk script touches a wall (the model has no
slide). A changed `WALK_CHECKSUM` in `src/tests/e1m1.cairo` must be
regenerated on purpose, never silently (PLAN.md §3.1 rule 5).

## Open questions for `doom_player`, `doom_monsters`, `doom_game`

* **Applying events.** `MoveEvent::Touch` → `P_TouchSpecialThing`
  (`doom_player`); `CrossSpecial(line, oldside)` → `doom_specials`;
  `MissileHit(thing)` → `damage_mobj(thing, missile, missile.target,
  (P_Random() % 8 + 1) * info.damage)` then `explode_missile`; `Hit::Thing`
  → `damage_mobj(thing, shooter, shooter, damage)`; a `DamageOutcome.drop`
  → `push`/`first_free` + `set_thing_position`. Whether backward patches are
  batched per tic (recommended, one `replace` pass) is `doom_game`'s.
* **Sector heights.** `World.floor`/`ceil` are spans; a moving door means
  `doom_game` rebuilds a 182-felt array on the tics where a sector moves
  (~2 200 steps). An overlay for the few moving sectors would be cheaper;
  the physics would need a `floor_of`-style accessor instead of raw spans.
* **The sight budget.** With ~110 steps per candidate line, a sight
  traversal in a line-dense area costs 7 000–10 000 steps: `doom_monsters`
  should use `check_sight_cached` with `ttl` ≥ 8 and keep `A_Look` at 1/4
  cadence (D3), and budget ~1 traversal per tic across the 8 awake monsters.
* **Bytecode (D23).** 35 873 words after S7 (32 678 without
  `vanilla_slide`), against 12 000 targeted: S7 §6 lists what a 12 000-word
  physics would have to drop and §3 what the compiler-level switches
  (`unsafe-panic`, `inlining-strategy`) buy; a decision on the budget
  itself is needed at P1.9.
* **A narrower `World` for the callers.** Every public call pushes the
  67-felt `World` (the `HotMap` by value *and* behind `hot`) and returns
  the 27-felt `Mobj`: ~100 steps and ~100 words per call site. Once
  `doom_game` is the only caller, `World` can shrink to the `Level` plus
  the two table handles.
* **Sky.** A sky flag per sector (one bit in `doom_map`'s `S_META`) would
  let `line_attack` and `xy_movement` drop puffs/missiles on the sky as
  Doom does.
* **`subsector` after a short move** is the one of the last relocation
  (same sector); if the renderer ever needs the exact subsector, `locate`
  on demand.

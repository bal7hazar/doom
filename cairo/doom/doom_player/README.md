# doom_player

**Does**: the player half of a Doom-like tic — `p_user.c`, `p_pspr.c` and
the player's share of `p_inter.c` from linuxdoom-1.10 (GPL-2.0-only;
semantics derived, no C copied), over `doom_physics`' geometry and
`doom_things`' tables:

* `Player` (36 felts, `push_felts` is the serialization schema for
  `doom_game`) and `spawn`/`reborn`, Doom's own starting loadout;
* `player_think` — `P_PlayerThink` for one already-decoded ticcmd word
  (D15): `P_MovePlayer`/`P_Thrust` (turn, forward and side thrust through
  `bam`'s `finesine`/`finecosine`, the `onground` rule), `P_CalcHeight`
  (the bob, the view-height spring, `viewz`), the weapon-change buttons,
  `P_UseLines`' `USERANGE` trace, `P_MovePsprites`, and the counters;
* the whole psprite chain of `p_pspr.c` for the five weapons `doom_things`
  carries — `P_SetPsprite`, `P_BringUpWeapon`, `P_CheckAmmo`,
  `P_FireWeapon`, `P_DropWeapon`, and `A_WeaponReady`, `A_ReFire`,
  `A_Lower`, `A_Raise`, `A_Punch`, `A_Saw`, `A_FirePistol`,
  `A_FireShotgun`, `A_FireCGun`, `A_Light0`/`1`/`2`, with `P_BulletSlope`
  and `P_GunShot` on top of `doom_physics::aim_line_attack`/`line_attack`;
* `P_TouchSpecialThing` for every item Freedoom E1M1 carries, with the
  `P_Give*` rules underneath and D14's item counter;
* `P_DeathThink`, and `P_DamageMobj`'s **armor absorption** in front of
  `doom_physics::damage_mobj` (which documents that it wants damage already
  net of armor), with `PST_DEAD` for D14's `status = 1`.

**Does not**: move the player (that is `doom_physics::xy_movement`, which
`doom_game` runs in the thinker pass **after** `player_think`, exactly as
`P_Ticker` does); own the mobj list, the specials state or the tic counter;
apply anything to a mobj other than the player's own — a shot, a pickup and
a use are **reported** (`PlayerEvent`), the same contract `doom_physics`
uses for `MoveEvent` and `Hit`; run the monsters (`doom_monsters`); decide
what a linedef does (`doom_specials`).

**Invariants**:

* `health` stays in `[0, 200]` and `mo.health` mirrors it after every
  pickup; `ammo[t] <= max_ammo(t)` for every type, and the backpack doubles
  each maximum exactly once;
* `viewheight` stays in `[VIEWHEIGHT/2, VIEWHEIGHT]` while alive and reaches
  exactly `6` units when dead; `bob <= MAXBOB`;
* the psprite chain always lands on a state with tics left or on none at
  all: the zero-tic chain is bounded by `doom_things::MAX_ZERO_TIC_CHAIN`
  and an action's re-entry into `P_SetPsprite` by `MAX_PSPR_DEPTH = 4`, so
  no input can make the proving path loop (R4-A2);
* a `BT_USE` press traces once — a held button does nothing until it is
  released — and reports at most one special line;
* every serialized felt is non-negative and below 2^72 (PLAN.md A7), and
  nothing on the proving path panics on game data.

## The contract with `doom_game`

**Per-tic order** (`P_Ticker`, and what the crate assumes):

```text
for the player:
  1. sector = mo.sector, on_floor = (mo.z == floor_of(sector))
  2. doom_specials::player_in_special_sector(...)      -> damage, secret
  3. doom_player::player_think(env, …, word, damage, secret, ref events)
  4. doom_specials::use_line(...) for each PlayerEvent::Use
then the thinker pass:
  5. doom_physics::xy_movement / z_movement on every mobj, the player first
     - XyOutcome::Stopped        -> doom_player::player_stopped
     - MoveEvent::Touch(item)    -> doom_player::touch_special, then remove
     - MoveEvent::CrossSpecial   -> doom_specials::cross_line
  6. doom_specials::specials_ticker
  7. leveltime += 1
```

`player_tic` does 1–4 in one call for a caller that wants it; the hot path
(`player_think`) does not depend on `doom_specials`' types, so a `doom_game`
that keeps its own specials state pays nothing for them.

**What `doom_game` must do that this crate deliberately does not**:

| | |
|---|---|
| run `fsm::advance` on the player's **mobj** (its `S_PLAY_RUN*` cycle) | `doom_player` only enters states, it never ticks the mobj machine |
| apply `PlayerEvent::Shot((hit, damage))` | `damage_mobj(thing, player, player, damage)` on a `Hit::Thing`, and hand the point to the renderer as a puff or blood |
| apply `PlayerEvent::Picked` / remove a taken item | `touch_special` returns `true`; the mobj list is `doom_game`'s |
| `count_kill` when a `DamageOutcome` whose source was the player reports `counts_kill` | D14's `kills` |
| pass `env.mobjs[me]` as the player's mobj **at the start of the tic** | `line_attack` reads the shooter's position from the list; `P_PlayerThink` runs before anything moves, so the two agree |
| turn `Player::playerstate == PST_DEAD` into D14's `status = 1` | and `SpecialsState::exit` into `status = 2` |
| seed both RNG streams at `prng::from_index(1)` (D24) | so the draws match Doom's `P_Random` order |

## Shape, and the decisions behind it

**A `Player` is a value beside the `Mobj` that `doom_physics` owns.** Both
are taken by `ref`; nothing else is mutated. Doom's `player_t` fields that a
single-player, no-cheat, no-network run never reads are dropped
(`didsecret`, `message`, `colormap`, the frag table, the four unreachable
powers), and what is a pure function of something else is derived rather
than stored: `maxammo` from `backpack`, the flash psprite's `sx`/`sy` from
the weapon's (Doom copies them every tic). `cheats` is kept, always zero,
because `P_PlayerThink` and `P_CalcHeight` branch on it and a fork that
wants `CF_NOCLIP` should not have to change the hash schema.

**`Env` boxes the `World`.** A `doom_physics::World` is nineteen spans plus
a grid, about 56 felts, and Cairo copies a struct at every call boundary —
the lesson D24 records and `doom_physics` measured as ~740 steps of
argument plumbing on `xy_movement`. The psprite chain is four calls deep on
an idle tic and only three of its actions ever trace a shot, so the world is
put in a `Box` (one felt) and unboxed where it is actually read.

**The use-line trace goes through `path_traverse`, not through a second
instance of `doom_physics`' generic `traverse`.** Implementing the
`Traverser` trait here would monomorphise a function that is ~3 600 Sierra
statements in `doom_physics` (D4: 60–77 words per monomorphisation, and far
more for one that large). `path_traverse` returns the crossings already
sorted nearest-first, which is exactly what `PTR_UseTraverse` walks.

**Two planar-`const` rewrites were measured and reverted.** S1 §5.9's rule
("one bytecode word per `const` element against ~18 per `if` arm") holds for
a *data* table read in a loop. It does not hold for a **dispatch** whose
arms are calls: turning `P_TouchSpecialThing`'s 22-arm `if` tree into three
planar columns plus an eleven-arm operation dispatch cost **+8 000 words and
+153 steps**, because every arm still exists, each now takes a variable
rather than a constant argument, and each keeps the whole `Player` + `Mobj`
live set alive. The same for `weapon_bit`: **+1 300 words** for a six-element
table. Both are back to `if` trees, and this is why.

### Serialization schema

`push_felts` appends the 36 felts of a player in this order:

```text
mo, playerstate, health, armor_points, armor_type,
ammo_clip, ammo_shell, ammo_cell, ammo_misl, backpack,
weapons, ready_weapon, pending_weapon, cards, strength,
viewz, viewheight, deltaviewheight, bob,
psp_state, psp_tics, psp_sx, psp_sy, flash_state, flash_tics,
extralight, damagecount, bonuscount, attacker, attackdown, usedown,
refire, cheats, killcount, itemcount, secretcount
```

`Fixed` fields are their `enc` (< 2^33), `weapons` and `cards` are bitsets,
everything else is a `u32` or a bit — every felt is non-negative and below
2^72, asserted by `test_every_serialized_felt_is_small`. `fields()` returns
the count for `state_hash::open` (D16). The four ammo counters are separate
fields rather than a `[u32; 4]`: a fixed-size array *inside a struct* makes
`universal-sierra-compiler` 2.19.3 fail under the `inlining-strategy =
"avoid"` that `cairo-coverage` requires, and four fields also read for free
where the array cost a `Span` index.

### Known departures from vanilla

* **`S_PLAY_ATK2` does not exist in `doom_things`' table.** Vanilla's
  muzzle-flash actions put the player mobj in that full-bright frame; no
  `mobjinfo` field and no weapon chain reaches it, so the generator does not
  emit it. This crate uses `S_PLAY_ATK1`, which `A_WeaponReady` sends back to
  `S_PLAY` on the next ready tic either way: the difference is one sprite
  frame on the tic a gun fires. Regenerating `doom_things` with that one
  extra state would remove it (open question below).
* **The chaingun always shows its first flash frame.** Vanilla picks
  `flashstate + (psp->state - S_CHAIN1)`, so the two frames alternate;
  `doom_things`' compacted ids do not keep `S_CHAINFLASH2` adjacent to
  `S_CHAINFLASH1`. Renderer-only, on a weapon that is not obtainable on
  E1M1 at skill 2 (no chaingunner in Doom 1, and the pickup is
  `MTF_NOTSINGLE`).
* **The rocket launcher and the plasma rifle are left on the floor.**
  Both are gettable in Doom but have no slot in the five-weapon roster
  `doom_things` generates; both are multiplayer-only placements on E1M1, so
  nothing spawns them at skill 2. Half-applying them (the ammo but not the
  weapon) would be worse than refusing them.
* **`onground` is recomputed in `P_CalcHeight`** instead of being the
  file-static `P_MovePlayer` last wrote. The two differ only on the tic
  after a teleport, and E1M1 has no teleporter.
* **`BT_USE` on a dead player does not start `PST_REBORN`.** A proven
  single-player run has no respawn: the segment ends with D14's `status = 1`.
* **Skill 2 only**: vanilla's `sk_baby` halving of incoming damage and
  doubling of ammo pickups is absent (D3).

## Measured step costs

`bench/` is a standalone Scarb package; `bench/measure.py` is the crate's
**step-budget and bytecode-budget test** (it fails at +10 % over
`bench/budgets.json`). The player stands at E1M1's Player 1 start, linked in
the thing grid; every iteration restores the player and mobj records and
rebuilds the tic's `Env`, so nothing accumulates and nothing is hoisted.
Costs are net of the baseline op that builds the same operands.

```sh
cd bench && python3 measure.py          # measure + check budgets
python3 measure.py --update             # re-baseline after an intended change
python3 size_split.py                   # where the bytecode goes, module by module
python3 coverage.py                     # line coverage
```

| Operation | steps (net) | range checks | task target | note |
|---|---:|---:|---|---|
| `player_think`, idle (pistol ready, no input) | **2 775** | 102 | ≤ 400 | see below |
| `player_think`, walking forward | 3 002 | 127 | — | +227 for the turn, two `P_Thrust` and the run frame |
| `move_psprites`, one `A_WeaponReady` tic | **1 448** | 33 | ≤ 80 | the bulk of the idle think |
| `calc_height` | 475 | 46 | — | `finesine`, the spring, four `Fixed` compares |
| `touch_special`, health bonus | **514** | 12 | ≤ 200 | the 22-arm `switch` and two `ref` records |
| `push_felts` (36 felts) | **18** | 3 | ≤ 60 fields ✓ | 0.5 steps a felt |
| `damage_player`, armor absorption | 1 241 | 43 | — | 1 100 of it is `doom_physics::damage_mobj` |
| `use_lines`, `USERANGE` trace | 1 435 | 112 | — | `path_traverse` over one or two cells |
| `player_think`, use held | 4 191 | 210 | — | the same, plus the whole think |
| `player_think`, firing the pistol | **113 932** | 12 000 | — | see below |

Three figures need saying out loud rather than a relaxed budget.

* **The idle think is 2 775 steps, not 400.** 1 448 of it is one psprite
  tic, and that tic is four calls deep (`move_psprites` → `tick_slot` →
  `set_psprite` → `run_action` → `a_weapon_ready`) with a `Player` (36
  felts) and a `Mobj` (27) crossing each boundary by `ref` — 126 felts in
  and out per level before any work happens — plus `finesine` +
  `finecosine` (103) for the weapon bob and `fsm::enter` (44). This is the
  same wall `doom_physics` hit and named: in Cairo 2.16 the cost of a
  faithful transcription is the argument plumbing, not the arithmetic. The
  400 in the task assumed the rules alone. Two structural fixes exist and
  are not in this PR: shrink `Player`, or let the psprite chain work on a
  four-field `Psprite` value instead of the whole record.
* **`touch_special` at 514** is two `ref` records through a
  three-way-split `switch`; the split is there because a single 22-arm
  function overflows the CASM jump offsets under the coverage build (below).
* **Firing the pistol costs 114 000 steps**, and none of it is this crate's:
  `P_BulletSlope` makes **three** `P_AimLineAttack` traces of 1 024 units
  when the first two find no target, and `P_GunShot` one `P_LineAttack` of
  2 048 — four traversals down E1M1's long start hall at
  `doom_physics`' measured ~8 500 steps each, and rather more here because
  the start hall is line-dense in every direction the aim tries. That is
  ten times D2's 12 000 steps/tic budget on the tic a shot leaves the
  barrel. It is Doom's own algorithm; the levers are all in `doom_physics`
  (a cheaper per-line test) or in the game design (D3), and it is the
  crate's first open question.

### Bytecode

`bench/size` calls every public entry point once on the loaded level;
`bench/baseline` links the same crate graph **and calls every
`doom_physics` / `doom_specials` / `bam` / `fsm` / `ticcmd` function
`doom_player` reaches**, with `op`-derived arguments so that constant
propagation does not prune one side and not the other. The difference is
**39 890 words** of `doom_player` code — 589 000 steps of bootloader
program-hashing per segment (S1 §5.9) — against the **4 000** the task
allots. `bench/size_split.py` switches one module's calls on at a time:

| step | cumulative words |
|---|---:|
| `state` (the record, `spawn`, `push_felts`) | ~0 |
| `+ inter` (`P_Give*`, `P_TouchSpecialThing`, `P_DamageMobj`, and through `P_DropWeapon` the whole action tree) | 13 600 |
| `+ weapon` (what the action tree did not already pull in) | 15 400 |
| `+ think` (`P_PlayerThink`, `P_CalcHeight`, `P_UseLines`) | 27 000 |
| `+ tic` (the `doom_specials` wiring) | 39 400 |

The shape is the one `doom_physics`' README diagnoses for its own 57 000
words: **a Cairo function's bytecode grows with its live set at every
branch**, and every branch here has a `Player`, a `Mobj`, an `Env`, a grid,
an RNG and an event array live. `inlining-strategy = "avoid"` cannot be
measured against it (the real E1M1 constants do not compile under that
flag), and the two planar-table rewrites tried made it *worse*, not better
(above). `measure.py` guards the measured figure against regression (+10 %)
and prints the D23 target; reconciling D23 with a faithful transcription —
a narrower mutable bundle, fewer call levels, or a revised budget now that
S4b priced 32 k words at ~6 % of a segment — is the same open question
`doom_physics` left for `doom_game`/P1.9, with this crate's 39 k on top of
its 57 k.

## Tests

`scarb test -p doom_player` — **132 tests**, in two modules:

* **`src/tests/e1m1.cairo`, 35 reference tests** against
  `src/tests/vectors.cairo`, which `scripts/model.py` computes from an
  independent Python transcription of `p_user.c`, `p_pspr.c` and
  `p_inter.c` (never from the Cairo code), over the same `doom_things`
  tables:
  - 10 `P_Thrust`/`P_MovePlayer` vectors (angle, forward, side, turn) and
    5 friction runs of 12 tics replayed **on the real E1M1** through
    `doom_physics::xy_movement`, bit-exact on momentum and position;
  - 12 `P_CalcHeight` vectors — the bob, its `MAXBOB` clamp, the view-height
    spring in both directions, the airborne branch, the ceiling clamp;
  - a **121-tic psprite script** (hold fire, switch to the fist, punch,
    switch back, fire again) checked every tic on the weapon and flash
    states, their tics, the clip, `refire`, `extralight`, the ready and
    pending weapons **and the RNG cursor** — the number of draws a shot
    makes is geometry-free, so the model predicts it exactly;
  - 32 pickup vectors (health and armor caps at 100 and 200, green over
    blue, clip against box, a dropped clip's half, the backpack's doubling,
    a found weapon's two clips against a dropped one's one, the item and
    bonus counters, the berserk pack's heal-and-switch);
  - 12 damage vectors (green armor's third, blue's half, armor running out,
    the `damagecount` cap, death);
  - a **350-tic scripted run** from the Player 1 start — walk out and back,
    turn, strafe, empty the pistol at the far wall, punch, walk again, press
    Use — sampled every 25th tic and folded into a **pinned checksum** over
    all 350 tics of `(x, y, angle, momx, momy, viewz - z, psprite, flash,
    clip, refire, ready weapon, RNG cursor)`. Positions are relative to the
    spawn point and the eye is `viewz - mo.z`, so the model needs no BSP
    descent and no sector heights; the test asserts on every tic that the
    player is still on the ground, and `model.py` refuses to write if any
    scripted tic would reach `P_XYMovement`'s halving branch (where
    `doom_physics`' `floor`/`ceil` split and C's `trunc`/`>>` diverge).
* **`src/tests/synthetic.cairo`, 97 rule tests** that assert no coordinate
  and no linedef id, so they run on any level — every branch of every
  action, the `P_CheckAmmo` fallback order down to the fist, the lower/raise
  round trip, a dead player's parked weapon, the zero-tic chain, the three
  arms of a dying player's turn, the seven shotgun pellets, the chaingun's
  dry click, berserk's ×10 punch, every gettable kind and every refusal,
  the properties (health ≤ 200, armor ≤ 200, ammo ≤ its maximum), and the
  `doom_specials` wiring of `player_tic`.

```sh
python3 scripts/model.py            # run the model, print a summary
python3 scripts/model.py --write    # regenerate src/tests/vectors.cairo
```

A changed `WALK_CHECKSUM` must be regenerated on purpose, never silently
(PLAN.md §3.1 rule 5).

## Coverage

`python3 bench/coverage.py` measures line coverage with `cairo-coverage`
0.5.0, on `doom_map`'s miniature fixture level (the real E1M1 constants do
not compile under the `inlining-strategy = "avoid"` the tool requires) with
`doom_specials`' tables regenerated from it: **95 tests, 459/501 production
lines = 91.6 %**.

It runs the suite in **several passes and takes the union of the covered
lines**, because `doom_player` links `doom_map`, `doom_things`,
`doom_physics` *and* `doom_specials`, and the whole graph in one program
under `avoid` walks into two `universal-sierra-compiler` 2.19.3 limits:
`Offset overflow` (a function's frame past what an `i16` CASM offset
reaches — with nothing inlined, a handful of calls into
`P_TouchSpecialThing` in one test is enough), and an internal
`assertion failed: Deferred(Const) does not match ZeroSized` that appears
only once the whole suite compiles. The script halves a group that will not
compile until every group does; a line counts as covered when any pass
covered it, which is what one pass over the whole suite would have
reported. Both limits are also why `src/tests/synthetic.cairo` is written
one behaviour per test, and why `P_PlayerThink` and `P_TouchSpecialThing`
are each split into two or three functions in the shipped code.

`test_player_tic_wires_the_specials_in` is the one test that does not
compile even alone (it is the only path that reaches
`doom_specials::use_line`), so `src/tic.cairo` is not in the coverage
figure; `scarb test` runs it on the real level. The other misses are
`use_lines`' walk and the gun actions' bodies, which the fixture level's
2 × 2 blockmap cannot exercise — E1M1 does, under `scarb test`.

## Open questions

* **114 000 steps for one pistol shot** (above). `P_BulletSlope`'s three
  auto-aim traces are Doom's, but at `doom_physics`' ~110 steps per
  candidate line they blow through D2's 12 000 steps/tic on the tic a gun
  fires. Options: cache the aim for a few tics the way R2-A3 caches sight,
  shorten `AIMRANGE`, or accept a p99 spike and let D1's segment cutter
  absorb it. Needs a decision with `doom_physics` and `doom_game`.
* **39 890 words of bytecode against a 4 000-word slice** (above), on top of
  `doom_physics`' 57 000. D23's 12 000 for all code is not reachable with
  this transcription style; the budget or the style has to give, and P1.9 is
  where that is decided.
* **`S_PLAY_ATK2` and `S_CHAINFLASH2`** are the two states `doom_things`'
  generator does not emit because only C action code reaches them. Adding an
  "extra states" list to `scripts/gen_things.py` would remove both
  departures above for ~10 words.
* **The idle think at 2 775 steps.** Shrinking the mutable bundle the
  psprite chain carries is worth ~1 000 steps a tic and is a `Player`
  layout change, so it belongs with `doom_game`'s state design, not here.
* **Sound.** Every `S_StartSound` is dropped (the simulation never reads one
  back). `doom_game`'s snapshot will need a cue for the client, most
  cheaply as another `PlayerEvent`.

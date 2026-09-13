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

**Inside the crate, everything crosses a call behind a pointer** (S7 §8
rule 3). `Env` is 16 felts, `Player` 36 and `Mobj` 27; a tic goes eight
levels deep (`player_think` → `buttons` → `move_psprites` → `tick_slot` →
`set_psprite` → `run_action` → `A_WeaponReady`), and Cairo pushes every
felt of every one of them at every level *and* stores the function's whole
return width again at each of its return points and panic sites.
`bench/attribute.py` had the psprite chain at **88 felts of parameters and
72 of return** at every level. So `env::enter` boxes the three records once
at each public entry point and the inside of the crate (`*_in`) carries
`Box<Env>`, `Box<Player>`, `Box<Mobj>` — one felt each, and the same
functions now measure **12 in and 11 out**. The public signatures are
unchanged. The public boxing adapters now inline at the caller; the
boxed algorithms remain shared, avoiding a wide call immediately before
converting the records to pointers.

Reading a field through a box is free (`unbox` emits nothing, the field is
a double dereference). What a box costs is a **write**: rebuilding a boxed
`Player` measures 111 steps, so each step of the tic rebuilds the record it
changes exactly once (`buttons` folds the weapon switch and the use latch,
`calc_height_in` the four view fields, `damage_player_in` the five a hit
changes), the pure halves are split out (`thrust_of`, `spring`,
`absorb_of`, `requested_weapon`), and **a record is not rebuilt to write
the values it already holds** — `set_slot` and `A_WeaponReady` hit that
case on every tic a weapon is simply up (a self-looping "ready" state, zero
bob), and `P_MovePlayer` with an empty command is a no-op.

**Direct table accesses and arithmetic use panic-free helpers** (S7 §8
rule 1); `bam` still has checked operations upstream. A panic site is not
an error path in Cairo 2.16, it is 72 felts of zero-padding: the `Err`
variant of the enclosing function's `PanicResult` is stored at the full
width of its `Ok`, and "may panic" propagates to every caller, which then
carries a propagation path of *its* width. `src/num.cairo` re-exports
`doom_physics::maputl`'s panic-free scalars and adds the ones this crate
needs; table reads go through `rd32`/`get` + `match`, the state machine
through `doom_physics::spawn::state_entry` and the RNG through its `roll`
(the twins S7 §9 parked there), divisions through `NonZero` literals, and
the constant angles are folded into `const`s. That took the crate's
`PanicResult` stores from 12 600 words to about 1 900 before the
final adapter inlining; the remaining checked paths propagate through `bam`'s `reduce`/`sub`/`finesine`, which still
panic (S7 §9 has them on the list).

**No literal at a call site that the lowering can specialise on** (S7 §8
rules 4 and 7). `give_ammo(ref p, AM_CLIP, 5)` in each arm of `take_ammo`
gave the compiler **nine copies of `give_ammo`, 3 562 words**; two arms
calling `a_melee(…, false)` and `a_melee(…, true)` gave two copies of a
2 184-word function. Each `if` tree now picks the *values* and calls once.

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
cd bench && python3 measure.py          # steps + both word figures, checked
python3 measure.py --update             # re-baseline after an intended change
python3 attribute.py --top 40           # where every word goes (S7 §3.1)
python3 size_split.py                   # the words, module by module
python3 coverage.py                     # line coverage
```

The "before" column is this tree measured *before* the S7 §8 pass, after
the S7 physics merge (which is why it differs from the figures the earlier
revision of this README quoted — a pistol shot was 113 932 steps then).

| Operation | steps (net) | range checks | before S7 |
|---|---:|---:|---:|
| `player_think`, idle | **1 303.5** | 101.7 | 2 784 |
| `player_think`, walking | 1 671.5 | 135.7 | 3 018 |
| `move_psprites`, ready tic | 705.5 | 34.7 | 1 456 |
| `calc_height` | 413 | 52 | 474 |
| `touch_special`, health bonus | 473 | 16 | 522 |
| `push_felts` (36 felts) | 18 | 3 | 18 |
| `damage_player`, armor absorption | 1 331 | 42 | 1 300 |
| `use_lines`, `USERANGE` trace | 1 507 | 161 | 1 485 |
| `player_think`, use held | 2 726.5 | 258.7 | 4 249 |
| `player_think`, pistol at a target 128 u ahead | **9 309** | 998 | — |
| `player_think`, pistol into the empty hall | **98 944** | 13 266 | 100 790 |

The resumed S8 audit found a failing damage benchmark at 1 477 steps
against the existing 1 430-step tolerance limit. Inlining the public boxing
adapter brought it to 1 331; its 1 300-step baseline was not raised. The
same change removes 168 steps from idle and walking, 145 from the ready
psprite tic and 104 from the public height calculation. No operation's
recorded budget was raised; improved baselines were tightened.

Idle still misses its original 400-step target, and pickups miss 200.
The previous profile found about 490 steps in boxed-record rebuilds; a
narrow psprite state would be a separate structural change. The shooting
policy remains vanilla: a miss takes three 1 024-unit aim traces, about
66 001 steps together in this hall, plus a 30 294-step pellet trace. A hit
stops on the first aim trace. The aim-policy alternatives below remain
proposals; these optimizations change neither aim nor RNG order.

### Bytecode

The S8 audit keeps **three distinct measurements**, on Scarb 2.16.0.
`bench/size` exercises the public facade, including the optional
`player_tic` convenience API; `bench/baseline` calls the lower-crate
functions. Scalar facade arguments derive from `op`, including pickup
kind, damage, weapon/slot/depth, commands and movement. A literal pickup
kind had previously folded away most of the dispatch: the old harness
under-counted it by **5 628 words**. More literals remained in the recovered
harness and were removed during this audit. Use the corrected figures.

| Metric | dev | proving (`unsafe-panic = true`) |
|---|---:|---:|
| Full `bench/size` executable, including data/header | 71 568 | 64 690 |
| Full `bench/baseline` executable | 47 977 | 44 336 |
| Historical difference: size minus baseline | **23 591** | **20 354** |
| Player code attributed by source stack | 20 650 | 18 809 |
| Player constant data | 21 | 21 |
| Player source contribution, code + own constants | **20 671** | **18 830** |

**The historical proving difference remains 354 words above 20 000.**
It did not pass that target. Its final 20 354 compares with 20 928 in the
recovered partial harness; after making the remaining arguments opaque,
the intermediate figure was 21 476, before the final wrapper/loop changes.
The earlier 22 796 pre-S7 figure and 18 963 after-S7 figure used a folded
harness and are not complete measurements of the shipped facade.

D29's allocation remains **20 000 proving words**. `measure.py` now adds a
strict guard on source contribution, without a 10% tolerance and without
an `--update` bypass. The historical differences retain their separate
10% regression guards and their over-allocation warning. Passing the new
source guard is not reported as passing the old differential target.
`bench/test_measure.py` tests the exact boundary, a one-word overage,
re-baselining, and an oversized consumer whose small harness would pass.

`attribute.py` joins Sierra statement offsets from `infra/sierra_words`
to source stacks. A code word is charged once when a player function owns
its Sierra function or appears in the stack, including a public wrapper
inlined into a caller. Shared out-of-line lower-crate functions remain
outside that total. The 21 words in the four player tables are counted
once per `const_as_box` declaration with player as closest non-core source;
shared `bam`/map/things tables and executable/segment headers remain with
their own component. The **1 524-word** difference between the proving
differential and player source contribution belongs to differing harness
call sites and lower-crate linkage; source attribution exposes that
residual instead of silently assigning it to player.

The facade harness does not establish what `doom_game` links: that crate
calls `player_think` directly and does not use `player_tic`. To inspect the
real consumer, build its proving executable with statement/function debug
annotations, then run:

```sh
python3 bench/attribute.py --sierra /path/to/doom_run.executable.sierra.json --json /tmp/player-words.json
python3 bench/measure.py --consumer-sierra /path/to/doom_run.executable.sierra.json
```

The optional consumer check applies the same strict 20 000-word limit.
The consumer must be built from the same player revision and proving
profile; the Sierra format does not encode the Scarb profile name. The
whole `doom_run` executable still needs its independent D29 100 000-word
guard at integration. The branch's Cairo workspace has no root `proving`
profile yet; both player benchmark manifests compile the complete linked
crate under that profile.

The final style change inlines the public boxing adapters, groups pickup
returns and moves both `player_tic` event loops outside its wide live set.
The shared boxed algorithms, API, serialized state and game rules remain
the same. `bench/size_split.py` also handles statements wrapped by
`scarb fmt`; its dev increments are diagnostic, not source ownership:

| Enabled modules | Difference from baseline | Increment |
|---|---:|---:|
| state | −27 059 | — |
| + inter | 2 631 | 29 690 |
| + weapon | 4 161 | 1 530 |
| + think | 11 217 | 7 056 |
| + tic | 23 591 | 12 374 |

The negative first row occurs because this partial program lacks lower
code the baseline calls; later increments can include that code. Neither
these increments nor the all-API source total replaces the consumer check.

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

The audited 350-tic checksum remains **4760390154965462**. The generator
was run without `--write`; no fixture was regenerated. Its SPDX string
was split across adjacent Python literals to satisfy REUSE 6.2.0 while
preserving the generated header and GPL-2.0-only license byte for byte.

A changed `WALK_CHECKSUM` must be regenerated on purpose, never silently
(PLAN.md §3.1 rule 5).

## Coverage

`python3 bench/coverage.py` measures line coverage with `cairo-coverage`
0.5.0, on `doom_map`'s miniature fixture level (the real E1M1 constants do
not compile under the `inlining-strategy = "avoid"` the tool requires) with
`doom_specials`' tables regenerated from it: **95 tests, 548/585 production
lines = 93.7 %** (`inter` 131/132, `state` 65/65, `num` 6/6, `weapon`
196/213, `think` 142/160).

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

The two `player_tic` tests are the ones that do not compile even alone
(they are the only paths that reach `doom_specials::use_line`), so
`src/tic.cairo` is not in the coverage figure; `scarb test` runs them on
the real level. The other misses are
`use_lines`' walk and the gun actions' bodies, which the fixture level's
2 × 2 blockmap cannot exercise — E1M1 does, under `scarb test`.

## Open questions

### An aim policy for a missed shot — for D10 / D3, proposed not decided

A shot that finds a target costs **9 309 steps**; the same shot into empty
space costs **98 944**, of which **66 001 is `P_BulletSlope`'s three
`P_AimLineAttack` traces** (22 000 each, 1 024 units through a line-dense
hall) and 30 294 the pellet. D2 budgets 12 000 steps a tic. The
short-circuit is already vanilla's, so the three options are about the
*policy*. The first aims to preserve behavior; it still needs validation:

1. **Prove there is nothing to aim at, and skip all three traces.** When no
   shootable thing's box can meet a 1 024-unit segment from the shooter,
   every one of the three traces returns `Aim { slope: 0, target: NO_MOBJ }`
   by construction (only `Aimer::thing` ever writes `aim`), and
   `P_BulletSlope` therefore returns exactly `fixed::ZERO`. An unimplemented squared-
   distance test per shootable mobj against `(AIMRANGE + 2·radius)²` in the
   field is estimated at ~15 steps a thing (not benchmarked): **~450 steps for E1M1's 29 monsters, ~4 000
   for a full 256-slot list**, against 66 001 potentially saved on a geometrically empty miss and
   nothing changed for a hit. **Behavior preservation requires a conservative bound and tests**;
   the figures above are estimates, not measured gains. The proposal needs
   an orchestration decision after S8 about
   where it lives (here, over `env.mobjs`, or in
   `doom_physics::aim_line_attack` where every caller would get it). The
   cost is paid on hits too, which is why it is a proposal and not a commit:
   the trade depends on how many mobjs `doom_game` keeps in the list.
2. **A shorter `AIMRANGE` for the two side traces** (vanilla: 1 024 units
   for all three, offset ±1 << 26 ≈ 5.6°). At 256 units the two side traces
   cost ~5 500 each instead of 22 000: a miss becomes ~63 000. *Consequence*:
   the horizontal auto-aim stops helping beyond 256 units. At 1 024 units
   the ±5.6° cone is ±100 units wide, which is exactly the assistance that
   lets a player hit an imp across a room without lining it up; cutting it
   makes distant off-axis shots miss that vanilla would land, and any
   recorded demo diverges. It is also the option that helps least.
3. **One straight trace only.** A miss becomes 22 000 + 30 294 ≈ 52 000, a
   hit dead ahead is unchanged. *Consequence*: no auto-aim except on a
   target the centre ray already crosses. Because Doom has no free look,
   `bulletslope` is also the *vertical* aim: a monster on a higher or lower
   floor that is slightly off-axis would be shot flat and missed, where
   vanilla adjusts. This is the largest gameplay change of the three and
   the one a player would notice first.

There is a fourth, orthogonal lever the README already listed: cache the
aim for a few tics the way R2-A3 caches sight. It helps a held trigger (the
chaingun) and does nothing for a single shot.

### The rest

* **The all-API differential is still 20 354 proving words**, 354 over
  D29's 20 000 allocation. Exact player source is 18 830 including its
  constants; consumer linkage and the full `doom_run` budget must be
  checked independently, as described above.
* **`S_PLAY_ATK2` and `S_CHAINFLASH2`** are the two states `doom_things`'
  generator does not emit because only C action code reaches them. Adding an
  "extra states" list to `scripts/gen_things.py` would remove both
  departures above for ~10 words.
* **The idle think at 1 303.5 steps** (was 2 775, later target 1 200).
  Public-wrapper overhead has been removed. A narrower mutable psprite
  bundle may save more rebuilds, but that is a separate state-design
  decision and was not implemented here.
* **Sound.** Every `S_StartSound` is dropped (the simulation never reads one
  back). `doom_game`'s snapshot will need a cue for the client, most
  cheaply as another `PlayerEvent`.

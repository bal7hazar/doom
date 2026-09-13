# doom_monsters

D33 migrates the shared roster to `Span<Box<Mobj>>` and `Patch.mo` to
`Box<Mobj>`. The ticker returns an array of those boxes, preserving unchanged
actors and allocating changed countdowns. The [current assembled measurements](../doom_game/bench_boxed/README.md)
include those allocations: idle tic 300 improves by 24.35%, fight tic 493 by
11.41%. Historical S7/S8 measurements below retain their original value-roster
reference; they are not the current per-tic copy cost.

**Does**: the monster AI of a Doom-like tic — the `p_enemy.c` half of
linuxdoom-1.10 (GPL-2.0-only; semantics derived, no C copied) — for the five
kinds Freedoom E1M1 can put in front of the player (zombieman, shotgun guy,
imp, demon, spectre), on top of `doom_physics`:

* the action functions, one per action id of `doom_things`: `A_Look`
  (`P_LookForPlayers`, the sector `soundtarget`, `MF_AMBUSH`), `A_Chase`
  (`P_Move`, `P_TryWalk`, `P_NewChaseDir` over Doom's direction tables,
  `movecount`, `threshold`, `P_CheckMeleeRange`, `P_CheckMissileRange`,
  `MF_JUSTATTACKED`, the active sound), `A_FaceTarget`, the four attacks
  (`A_PosAttack`, `A_SPosAttack`, `A_TroopAttack`, `A_SargAttack`) and the
  four passive ones (`A_Pain`, `A_Scream`, `A_XScream`, `A_Fall`);
* `P_MobjThinker` for a monster or a missile ([`think::mobj_thinker`]):
  movement under Doom's two guards, then `fsm::advance`, then the action id
  the countdown produced, dispatched by **one `match`** (D15) that also runs
  whatever action the state it entered carries, up to `MAX_ACTION_CHAIN`
  deep;
* [`monsters_ticker`], the whole tic under D3's schedule: every monster and
  missile moves and counts down, dormant monsters look one tic in four
  phased by their index, awake ones chase inside a round-robin window of 8;
* a flat [`MonsterEvent`] per effect the caller has to apply — a sound, a
  puff, blood, a crossed special, a door to push, a kill, a dropped item, a
  wake-up.

**Does not**: own the mobj list, hash it, or move anything that is neither a
monster nor a missile (`doom_game` does the tic loop, the player is
`doom_player`'s, the barrels and items are nobody's until they are shot);
implement geometry (`doom_physics` answers every `P_TryMove`, `P_CheckSight`,
`P_LineAttack`, `P_DamageMobj`, `P_SpawnMissile`); apply a special line
(`doom_specials` owns the switch and door state — a crossed or bumped line
comes back as an event); carry sounds as data beyond the ids it reports; know
anything about a renderer.

**Invariants**:

* a monster only ever moves through `doom_physics::try_move`, so it never
  ends a tic straddling a blocking line — checked on all 200 `P_NewChaseDir`
  vectors with `check_position` after the fact;
* `move_dir` is always a direction or `DI_NODIR`, and `move_count` is always
  what `P_Random() & 15` can produce;
* **RNG consumption is a function of the inputs alone**, never of the
  geometry: `P_CheckMissileRange` draws whatever the distance,
  `P_NewChaseDir` draws its two bytes whatever the walk does, and a see or
  death sound draws exactly when its family is one of the contiguous runs of
  `info.c`. C2 rests on this;
* nothing this crate does to a mobj other than the one it was handed is
  written in place: a damaged target, a dropped item and a spawned fireball
  come back as a [`Patch`] and are applied in one rebuild at the end of the
  tic (the `doom_physics` README's rule);
* the schedule is a pure function of `tic` and of the awake set at the start
  of the tic, so a segment restarted from a state hash schedules exactly as
  the continuous run did; with 8 awake monsters or fewer nothing is ever
  de-scheduled;
* no `Array` is allocated per candidate direction, no `if`-tree stands in
  for a table, nothing wide crosses a call and nothing this crate writes
  itself can panic (docs/spikes/S7.md §8, see *Shape*), and every felt
  written stays below 2^72 (A7).

## Shape, and the decisions behind it

**A state carries an action id, and the dispatcher is one `match`.** Cairo
has no function pointers; `doom_things` gives every state an id and
`fsm::advance` hands it back (D15). `think::dispatch` compares it against the
eleven ids this crate owns and ignores the rest (the weapon and flash actions
are `doom_player`'s). Doom's `P_SetMobjState` runs the action of every state
it enters, so an action that changes the state returns the new state's
action and `run_chain` runs it too — `A_Look` → `seestate` → `A_Chase` →
`missilestate` → `A_FaceTarget` is a real three-deep chain, and
`MAX_ACTION_CHAIN = 4` bounds it, because nothing on the proving path may
loop freely.

**The sound roster lives here.** `doom_things` deliberately carries no
sounds, but `A_Look` and `A_Scream` **draw a `P_Random`** when the kind's
sound belongs to one of `info.c`'s contiguous families (`posit1..3`,
`bgsit1..2`, `podth1..3`, `bgdth1..2`), and `A_Chase` draws one on every call
for its active sound. Those draws are part of the replayable stream, so the
five columns of `mobjinfo` they read are `const` arrays in [`tables`], with
this crate's own compact numbering (the renderer maps ids to samples).

**`A_Look` runs on the cadence, not on the frame.** D3 and S1's R2-A3 say
"`A_Look` one tic in four, phased by mobj id". Vanilla only *reaches*
`A_Look` when the two-frame idle loop turns over, which on this roster is one
tic in ten — and gating that on `tic % 4 == id % 4` would be worse than
useless, because ten and four share a factor: a given monster's transitions
only ever land on two of the four phases, and half the roster would never
look at all. So the cadence is what it says: a dormant monster looks on its
own phase whatever frame it is showing, and never twice on one tic. That is
*more* responsive than vanilla (every 4 tics rather than every 10) for a
quarter of the cost of looking every tic, and it draws nothing unless it
actually wakes.

**Hearing is the REJECT row, not a flood.** Vanilla `P_NoiseAlert` floods the
sector graph from the sector the shot was fired in (`P_RecursiveSound`,
stopping at closed openings and at the second `ML_SOUNDBLOCK` line) and
leaves a `soundtarget` on every sector it reaches. `doom_map` compiles **no
sector→lines index**, so that flood would have to rebuild the sector graph
from all of E1M1's linedefs — a five-figure cost, paid on every shot, and a
new dictionary of derived state. The REJECT row of the two sectors answers a
strictly narrower question in one packed table read (~150 steps, R2-A2, and
it is the table `check_sight` consults first anyway): sectors that REJECT
each other are exactly the ones with no line of sight at all. That is the
cheaper of the two options the task offers, and it is what [`Noise`] and
`actions::hears` implement.

It is conservative in the safe direction — a monster round a fully occluded
corner does not hear a shot that vanilla would wake it with — and the
departure is visible on E1M1: from the Player 1 start, **no** skill-2 monster
can see the player and the only two whose sector is not REJECTed are
`MF_AMBUSH`, so firing there wakes nobody (`test_the_start_alcove_is_quiet`
pins it). Vanilla's flood would wake several. Reconciling that needs a
`sector -> lines` accelerator in `doom_map`, priced in the open questions
below; until then `doom_monsters` under-wakes rather than over-wakes, which
is also the direction D3's cap of 8 prefers.

**Cross-mobj writes are patches.** The ticker walks the list once, building
the next one; a monster that damages the player (index 0, already passed)
runs `damage_mobj` **inline**, so the RNG order is Doom's, but on a *copy*
that is recorded as a [`Patch`] and written back in a single rebuild at the
end of the tic. Reads inside the tic go through [`read_mobj`], which prefers
a pending patch, so two hits on the same target in one tic compose. A tic
with no patch pays nothing for the mechanism.

**Nothing wide crosses a call (docs/spikes/S7.md §8).** A struct pushed at
a call costs one word of bytecode and one step per felt; a `ref` parameter
is pushed twice, once in and once out; and every panic site of a function
stores its **whole return width**, zero-padded, so a call of anything that
can panic costs the caller that width again. The crate was paying all three
at once: a 72-felt `Ctx` and a 27-felt `ref mo: Mobj` through the six levels
of `monsters_ticker` → `mobj_thinker` → `think_state` → `run_chain` →
`dispatch` → an action → `p_move`, for parameter lists of 93 to 125 felts
and return types of 30 to 41 for functions that answer a `bool`. So:

* the **public API is the boundary** — every public function still takes
  `Ctx` and the actor by `ref` — and each of them converts once and calls an
  `_in` twin that carries the one-pointer `Env` (a boxed six-felt payload,
  with `World` itself boxed too) and the actor as a
  `Box<Mobj>`, unboxed into a local at the top of a function and re-boxed
  once, where it is written;
* what only needs a `P_Random` takes the `rndtable` span, what only needs
  the target's position takes two `Fixed`s, and what only needs the actor's
  `kind` takes a `u32` and answers with a flag (`run_passive`);
* there is **no panic site in this crate's own code**: `get` + `match`
  reads, `wrapping` counters, `NonZero` literal divisions, `to_u128`/`low32`
  conversions, and the panic-free twins `doom_physics::spawn::roll`,
  `state_entry` and `set_state_in`. What is left is propagation from
  `doom_physics`, `bam` and `geom2d`;
* no loop-carried counter starts at a literal, which is what made the
  compiler emit a second, specialised copy of seven loop bodies.

That pass took the crate from 33 046 to 21 220 words with the same 55 tests,
the same 700-tic checksum and the same reference vectors, and took a tic of
29 dormant monsters from 22 092 to 13 185 steps. The `Bytecode` section
below attributes what is left.

**A dormant, still monster takes a fast path.** A monster asleep with no
momentum, standing on its floor, has exactly one thing to do per tic: count
its idle frame down (and look, on its phase). Doing that in the ticker's own
loop rather than through `mobj_thinker` skips four call boundaries, and it is
the path 29 of E1M1's 30 monsters are on for most of a run. Measured:
**51 513 → 21 890 steps/tic** for the whole dormant roster, and **13 185**
after the S7 pass. The loop also classifies each slot *through the list's
snapshot* and materialises the 27 felts of a `Mobj` only where the slot is
about to be written — one copy per mobj per tic instead of two, and none at
all for a mobj that is not this crate's.

### Known departures from vanilla

* **`P_NoiseAlert`** — see above.
* **`P_LookForPlayers`' `lastlook` walk** re-tests the same player up to
  three times when only one is in the game; the answer is identical every
  time and each repeat is a full `P_CheckSight`, so the loop runs once per
  player here. No `P_Random` is drawn either way.
* **A blocked `P_Move` does not open a door.** Vanilla walks `spechit` and
  calls `P_UseSpecialLine(actor, ld, 0)`, returning whether any line was
  usable. This crate reports the blocking line as an `EV_USE` event for
  `doom_game` to hand to `doom_specials`, and counts the move as refused —
  so the monster also picks a new chase direction on the tic it bumps into a
  door, one tic earlier than vanilla.
* **Sight is cached for 8 tics** (`SIGHT_TTL`, R2-A3): a monster can believe
  it still sees a target for up to 8 tics after the line breaks, unless the
  target changed sector.
* **Puffs and blood draw nothing**, because `doom_physics` reports them as
  events instead of spawning mobjs; vanilla's `P_SpawnPuff`/`P_SpawnBlood`
  each draw three `P_Random`s. The whole stream is shifted with respect to a
  vanilla demo — D10 asks for the same formulas and tables, not a bit-exact
  harness.
* **Damage to a mobj the ticker does not own** is applied to a patch; a
  second, unrelated read of that mobj *inside `doom_physics`* (a hitscan
  looking for targets, say) sees the pre-tic copy. Only infighting can reach
  this on E1M1.
* `MF_FLOAT`'s arm of `P_Move` and `MF_SKULLFLY` are unreachable on this
  roster (no cacodemon, no lost soul); they are not implemented, only guarded.

## API

```cairo
// One tic. `players` are the mobj indices of the players; `noise` is the
// last P_NoiseAlert. Returns the rebuilt list, the advanced RNG and the
// tic's events; `g` is updated in place (canonical order is hashed in schema 2).
pub fn monsters_ticker(
    w: World, mobjs: Span<Box<Mobj>>, ref g: ThingGrid, players: Span<u32>,
    noise: Noise, tic: u32, rng: Prng,
) -> (Array<Box<Mobj>>, Prng, Array<MonsterEvent>);

pub struct Noise { pub source: u32, pub sector: u32 }   // NO_MOBJ = silent
pub fn silence() -> Noise;

pub struct MonsterEvent { pub kind: u32, pub who: u32, pub a: u32, pub b: u32, pub at: Point }
// kind: EV_SOUND, EV_PUFF, EV_BLOOD, EV_CROSS, EV_USE, EV_KILLED, EV_DROP, EV_WAKE

pub const SIGHT_TTL: u32 = 8;      // R2-A3 cache
pub const LOOK_CADENCE: u32 = 4;   // D3
pub const WINDOW: u32 = 8;         // D3

pub fn is_dormant(w: World, mo: @Mobj) -> bool;
pub fn is_awake(w: World, mo: @Mobj) -> bool;
pub fn awake_count(w: World, mobjs: Span<Box<Mobj>>) -> u32;
pub fn in_window(rank: u32, tic: u32, n: u32) -> bool;
pub fn mobj_thinker(...) -> bool;                       // one mobj, one tic
pub fn read_mobj(mobjs: Span<Box<Mobj>>, patches: Span<Patch>, i: u32) -> Box<Mobj>;
```

`actions` also exports every action function and `p_move`/`new_chase_dir`/
`look_for_players`/`check_melee_range`/`check_missile_range` for
`doom_game`'s and the tests' use.

Every one of those sixteen entry points takes the 72-felt `Ctx` and the
actor by `ref`, and is the **boundary**: it converts once and calls a narrow
`_in` twin (see *Shape* above). A caller that reaches for one of them in a
loop pays the conversion each time — the bench measures it at 67 steps for
the `World` and 27 for the actor — which is why `doom_game` should call
`monsters_ticker` and let the crate dispatch. It is also 4 979 words of the
crate's compiled size (3 754 under the `proving` profile): the *Bytecode*
section reports the size with and without the public surface.

### The D3 schedule, stated exactly

On tic `t`, with `n` awake monsters (alive, `MF_COUNTKILL`, and not in a
state whose action is `A_Look`) enumerated in list order and ranked
`0..n-1`:

* the window starts at `(8 t) mod n` and covers eight consecutive ranks,
  wrapping — `in_window(r, t, n) = (r + n - 8t mod n) mod n < 8`;
* if `n <= 8` every rank is in the window on every tic (vanilla);
* every rank is visited within `ceil(n / 8)` tics, and exactly `min(n, 8)`
  are visited per tic (both checked for every `n < 25` and every phase);
* a monster that wakes during a tic is not in that tic's window (the awake
  set is the one at the start of the tic) and is scheduled from the next;
* the dormant cadence is `tic % 4 == index % 4`;
* **movement is never scheduled away**: `P_XYMovement` and `P_ZMovement` run
  for every monster and missile on every tic on which Doom itself would run
  them (there is momentum to spend, or the thing is off its floor).

## Measured step costs

`bench/` is a standalone Scarb package; `bench/measure.py` is the crate's
**step-budget and bytecode-budget test** (it fails at +10 % over
`bench/budgets.json`). Every scene is on the real Freedoom E1M1; each
iteration of a ticker op is one real tic of a scene built once before the
loop, so the number is what a tic costs in a run (see the *Bytecode*
section below for how to run it).

| Operation | steps (net) | range checks | task budget | before S7 |
|---|---:|---:|---:|---:|
| `monsters_ticker`, player only | **530** | 9 | — | 603 |
| `monsters_ticker`, +1 dormant monster | 439 | 12 | ≤ 60 | 746 |
| `monsters_ticker`, 29 dormant (all of E1M1) | **13 185** | 412 | — | 22 092 |
| … the same with nobody to look for | 10 183 | 251 | — | 18 547 |
| … of which `A_Look` (cadence + R2-A3 cache) | **104**/monster | — | ≤ 60 | 122 |
| `monsters_ticker`, 5 awake | **13 359** | 718 | — | 16 493 |
| `monsters_ticker`, 8 awake (D3's own cap) | **30 711** | 1 937 | — | — |
| `monsters_ticker`, 20 awake | **61 425** | 3 802 | — | 72 860 |
| `A_Chase`, walking step, sight cached | 3 872 | 154 | ≤ 1 800 | 3 787 |
| … of which `P_Move` (i.e. `doom_physics`) | **3 352** | 131 | — | — |
| `A_Look`, one sight traversal | 4 521 | 550 | — | 4 719 |
| `A_Look`, woken by a noise | 784 | 34 | — | 623 |
| `P_NewChaseDir` | 3 805 | 158 | — | 3 789 |
| `P_CheckMissileRange`, sight cached | 754 | 31 | — | 493 |
| `awake_count` over 30 mobjs | 1 729 | 61 | — | 1 793 |
| rebuilding a 30-mobj list | 2 697 | 150 | — | 2 697 |

The "before S7" column is `main` at `632e742`, i.e. with the S7 pass on
`doom_physics` already in but none of it here.

**Five of those went up, and all five are the public boundary.** `A_Chase`,
`P_NewChaseDir`, `A_Look` and `P_CheckMissileRange` are benched through the
*public* entry point, which now boxes the 67-felt `World` and the 27-felt
actor on the way in (94 steps) so that the six call levels below it carry
seven felts instead of ninety-nine. Inside a tic — the only thing a run
pays — every scene got cheaper: −40 % on the dormant roster, −19 % on five
awake, −16 % on twenty. A handful of steps also went into the panic-free
forms themselves: a `get` + `match` read and a `NonZero` divmod cost two or
three steps more than the panicking `at` and `%` (S7 §4.3), which is what
buys 4 000 words.

**Physics against AI.** `P_Move` alone on the bench's chaser is 3 352 of
`A_Chase`'s 3 872 steps: the AI's own share of a chase step — two
countdowns, the 45° turn, the melee and missile tests answered from the
R2-A3 cache, the active-sound draw — is **520 steps**, 13 %. On the twenty-
awake scene the split is the same in kind: what D3's window bounds is eight
`try_move`s and the occasional `check_sight`, not this crate's arithmetic.

**Against D2's 12 000 steps/tic.** Five awake monsters cost **17 540** and
twenty cost **81 311**, both over budget. The profile says where it goes, and
almost none of it is this crate's arithmetic:

* a zombieman's shot is `aim_line_attack` (4 985) + `line_attack` (5 208) +
  `damage_mobj` (1 240) ≈ **11 400 steps**, all `doom_physics`; five awake
  monsters fire about one shot every five tics between them;
* a sight traversal in a line-dense room is 7 700–9 700 steps
  (`doom_physics`' own figure). The R2-A3 cache with `ttl = 8` already cuts
  it to one traversal per monster per eight tics — without the cache the
  five-monster scene would be roughly twice as expensive;
* `A_Chase`'s walking step is 3 872, of which 3 352 is one `try_move` for a
  20-unit-radius monster (the `doom_physics` README measures 3 575 in a
  line-dense cell against 865 for a player in an open one), and it runs one
  tic in four because `info.c` gives the run frames 4 tics each.

Subtracting the physics, the AI's own share is about **520 steps per awake
monster per tic**. The levers are therefore all in `doom_physics` and in
D3's cap; the twenty-awake figure is what D3 exists to prevent, and it is
reported here so that the cap can be re-priced if the physics costs come
down. With eight awake monsters — D3's own ceiling — the scene is measured
at **30 711 steps/tic**, against a p99 allowance of 25 000.

**The dormant roster** is the other half of the story: 29 sleeping monsters
cost 13 185 steps/tic, of which 3 002 (104 each) is `A_Look` on its cadence.
The rest is the countdown, the schedule's own pass (`awake_count`, 1 729)
and one materialised copy of a 27-felt `Mobj` per slot per tic — the S7 pass
removed the second copy (the classification now reads through the list's
snapshot), and what is left is a property of the `Array<Mobj>` state
representation, which `doom_game`'s tic loop pays for every mobj whether
this crate touches it or not. Cutting it means changing that representation,
not the AI.

### Bytecode

`bench/size` calls the crate's entry points once; `bench/baseline` is the
same package with the same level data **and the same `doom_physics` calls**
and no `doom_monsters` call, so the difference is this crate's own code.
Four figures, because two axes matter:

|  | `dev` | `proving` |
|---|---:|---:|
| whole public surface | 21 220 | 17 963 |
| the ticker alone (what `doom_game` links) | 16 241 | **14 209** |

* `bench/size`'s default `full_api` feature calls all sixteen entry points
  that take a `Ctx`; `--no-default-features` calls only what `doom_game`
  calls. The difference — **4 979 words on `dev`, 3 754 under `proving`** —
  is the price of the public boundary (a 72-felt `Ctx` and a 27-felt actor
  pushed at the call, boxed in the wrapper, and stored again on the
  wrapper's panic-propagation path).
* the `proving` profile sets `unsafe-panic = true` (D29): a panic becomes a
  trap, which R4-A2 accepts for the proved program since a panic there was
  unprovable anyway. It was worth **−10 600 words** on this crate before the
  pass (S7 §6) and is worth −3 250 now, because the panic sites it was
  deleting are gone from the source. Building under it is also the compile
  test S7 §6 asks for: it compiles clean, no repeat of the `bam::tantoangle`
  ICE.
* **docs/DECISIONS.md D29 budgets this crate at 15 000 words**, and the
  figure it is about is the last one: **14 209, inside the budget**
  (211 000 steps of bootloader program-hashing per segment). `measure.py`
  fails at +10 % over it and guards all four against regression.

Where the words were, and where they are now (`bench/attribute.py`, which
gives every Sierra statement its CASM offsets through `infra/sierra_words`
and joins them to the statement → source-function map):

| words | before | after | how |
|---|---:|---:|---|
| `store_temp<PanicResult>` — the zero-padded return enum stored at every panic site and every return point, at the function's whole return width | 11 935 | 5 066 | no panic site left in this crate's own code, and the propagation that remains is stored at a return width of 6 to 16 felts instead of 30 to 41 |
| `store_temp<Ctx>` — the 72-felt context pushed at every call of the chain | 4 980 | 780 | the six-felt `Env`, a `Box<World>`; what is left is the public boundary and the harness |
| `store_temp<Mobj>` — `ref mo` in and out at every level, and `@Mobj` targets | 4 883 | 2 965 | `Box<Mobj>` through the chain, re-boxed only where written; the target boxed or reduced to the two coordinates it is read for |
| constant-argument specialisations (a second copy of a loop body) | 18 | 6 (2 of them `doom_physics`') | `opaque_zero(n)` as every loop-carried start |
| parameter / return widths of the chain | 93–125 / 30–41 | 11–24 / 6–16 | all of the above |

The 14 000 that remain are the algorithm under this code generation, as S7
§7 concluded for the physics: `P_NewChaseDir`'s ten attempts (1 725 words),
the ticker's own pass (1 581), `P_MobjThinker` with its missile arms
(1 519), `A_Chase` (1 414), `P_LookForPlayers` and `A_Look` (1 908), the
eleven-arm dispatcher (779) and the four attacks (~2 000). A comparison
costs ~15 words in this compiler, a `Span` read ~11, a divmod ~10, and the
27 felts of a `Mobj` have to be written wherever one is actually written.

```sh
cd bench && python3 measure.py          # steps + the four bytecode figures
python3 measure.py --update             # re-baseline after an intended change
python3 attribute.py --top 40           # where every word goes
python3 coverage.py                     # line coverage
```

## Tests

`scarb test -p doom_monsters` — **55 tests**:

* **reference vectors** (`src/tests/e1m1.cairo`, from `scripts/model.py`,
  never from the Cairo code): 200 `P_NewChaseDir` cases on E1M1 bit-exact on
  `movedir`, the resulting position, `movecount` and the RNG cursor; 150
  `P_CheckMissileRange` probability cases with the real `rndtable`; 80
  `P_CheckMeleeRange` pairs (distance rule and sight); 150 `A_Look` wake-ups
  (sight plus the 180° blind arc); the `info.c` chain entries of all five
  kinds; a **300-tic chase** of a zombieman after a target it never gets to
  see (pure `A_Chase`/`P_Move`/`P_NewChaseDir`), compared with the model at
  every tenth tic on position, `movedir`, `movecount`, state, `tics` and the
  RNG cursor;
* **the scripted 700-tic scenario** on E1M1: the player stands one room past
  the start and fires once; six zombies wake, walk up and open fire, 11 are
  awake at the peak (so the round robin really slides), 277 events are
  reported and the list grows from 30 to 35 (fireballs and dropped clips).
  Pinned by a **Poseidon checksum** of every mobj's 27 serialized felts plus
  the RNG cursor at every 50th tic, and by the counts above;
  `test_the_start_alcove_is_quiet` pins the acoustics of the start spot;
* **properties** (`src/tests/props.cairo`): a monster that steps ends
  somewhere `P_CheckPosition` accepts, with the floor it recorded;
  `threshold` decrements on every `A_Chase` and clears when the target dies;
  the round robin visits every rank within `ceil(n/8)` tics and exactly
  `min(n, 8)` per tic, for every `n < 25` and every phase; nothing is
  de-scheduled at or below the cap; RNG consumption is a function of the
  inputs;
* **paths** (`src/tests/paths.cairo`, level-independent): every arm of
  `A_Look` (silence, noise, `MF_AMBUSH`, a dead noise maker), of `A_Chase`
  (no target, `MF_JUSTATTACKED`, the melee and missile branches, the turn
  toward each of the nine `movedir`s), of the four attacks and the four
  passive actions, of `P_NewChaseDir` (all four diagonals, the sweep), of
  the dispatcher (one case per action id, driven through `mobj_thinker`),
  and of the ticker (things that are not ours, a missile, a patch applied, a
  removal at `S_NULL`, more than eight awake, the dormant fast path);
* **tables** (`src/tests/synthetic.cairo`): `opposite[]` is an involution,
  `xspeed`/`yspeed`/`diags` against `p_enemy.c`, the sound roster against
  `info.c` and its alignment with `doom_things`' kind numbering, the event
  ids, and the scheduler's constants and degenerate cases.

## Coverage

`python3 bench/coverage.py` measures line coverage with `cairo-coverage`
0.5.0 (the method of the other crates: a patched copy of the
`cairo/{crates,doom}` tree, `doom_map`'s miniature level in place of E1M1 —
the real data does not compile under `inlining-strategy = "avoid"` — and
`src/tests/{paths,synthetic}.cairo` as the suite, the two files that assert
shapes rather than coordinates): **40 tests, 372/400 production lines =
93.0 %**. The misses are `A_Chase`'s "look for a new target and find one"
arm, three arms of `P_NewChaseDir`'s fallback sweep that the miniature level
never forces, the missile-hit arms of `mobj_thinker` (no room to fly there),
and a handful of guard clauses. `src/tables.cairo` is data and is excluded,
as are `src/tests.cairo` and `src/tests/`.

`cairo-coverage` 0.5.0 emits no `BRF`/`BRH` records, so **branch** coverage
cannot be reported by the tool; line coverage is the proxy, and since
`scarb fmt` puts every branch arm on its own line, a missed arm shows up as a
missed line.

## Regenerating

```sh
# The WAD JSON of tools/wad (never committed), see doom_map/README.md.
python3 scripts/model.py --json /tmp/wadout/e1m1.json --write
scarb fmt -p doom_monsters
```

`model.py` loads `doom_physics/scripts/model.py` for the geometry
(`P_TryMove` in exact integers, `P_CheckSight` in exact rationals) and reads
the `info.c` numbers out of `doom_things/src/tables.cairo`; everything else —
the direction tables, the probability rules, the RNG order, the state walk —
is transcribed here from the C semantics, not from the Cairo. It searches for
a chase pair that stays out of sight for the whole 300 tics and refuses to
emit if it cannot find one. A changed `SCENARIO_CHECKSUM` in
`src/tests/e1m1.cairo` must be regenerated on purpose, never silently
(PLAN.md §3.1 rule 5); the test prints the value it computed.

## Interfaces for `doom_game`

* **Call it once per tic**, after the player's think and after
  `doom_specials` has moved the sectors (`monsters_ticker` reads the heights
  through `World`), with `players` = the player mobj indices and `noise` =
  the last `P_NoiseAlert` (set `Noise { source: player_index, sector:
  player.sector }` when the player fires, `silence()` at genesis). `Noise` is
  two `u32`s and belongs in the hashed state.
* **Apply the events**: `EV_CROSS(line, side)` →
  `doom_specials::cross_line(..., Actor { is_player: false, blue_key: false })`;
  `EV_USE(line)` → `doom_specials::use_line` for a monster (a door a monster
  bumped into); `EV_DROP(kind)` → give the item a slot (`first_free`/`push`)
  and `set_thing_position` it at the corpse; `EV_KILLED` → the kill counter
  of the segment output (D14); `EV_SOUND`/`EV_PUFF`/`EV_BLOOD`/`EV_WAKE` →
  the renderer snapshot, nothing in the simulation reads them back.
* **The RNG stream** is the gameplay one (`P_Random`), seeded at
  `prng::from_index(1)` (D24). Do not interleave a cosmetic stream into it.
* **The thing grid** is derived: `rebuild` it at the start of a segment and
  hand the same `ref` to the player think and to this ticker in the same tic.
* **The schedule** is stateless; `doom_game` passes its own `tic` and needs
  to store nothing for it. If it ever wants the awake count for the HUD, use
  `awake_count` — the ticker computes it anyway.

## Open questions

* **The public boundary.** 4 979 words of the crate's `dev` size (3 754 of
  its `proving` size) are the sixteen public entry points that take a
  72-felt `Ctx` and the actor by `ref`, plus the harness's calls to them.
  Making `Ctx` carry a `Box<World>` and the entry points a `Box<Mobj>` would
  delete almost all of it — the internals already work that way — at the
  price of an API change for `doom_game` and the tests. Worth deciding once
  `doom_game` is the only caller, together with the narrower `World` the
  `doom_physics` README asks for.
* **Steps/tic (D2).** Eight awake monsters cost 30 711 steps/tic against a
  12 000 average and a 25 000 p99, and 87 % of it is `doom_physics`. Either
  the hitscan and sight get cheaper, or D3's cap comes down, or the attack
  cadence gets a budget of its own. This crate's own share is ~520 steps per
  awake monster per tic.
* **A panic-free `fsm::advance`.** A local twin built on
  `doom_physics::spawn::state_entry` was measured at **+20 steps per mobj
  per tic** — the ticker advances every mobj's countdown, awake or not —
  against ~120 words, and was dropped. It becomes worth having the day `fsm`
  itself gets the panic-free accessor S7 §9 asks for, which would cost
  nothing at the call site.
* **`P_NoiseAlert`.** A faithful flood needs a `sector -> lines` index in
  `doom_map` (about 470 entries for E1M1, ~1 000 words of data) and a
  bounded BFS. With that index the flood is a few thousand steps per shot;
  without it, the REJECT proxy under-wakes as described above. Worth
  revisiting when `doom_map` is next regenerated.
* **The list representation.** One materialised copy of a 27-felt record
  per mobj per tic, before anything thinks — the S7 pass removed the second
  one, and the remaining ~2 700 steps/tic for E1M1's 30 mobjs are the
  `Array<Mobj>` itself (`bench` op 15 measures the floor at 90 per slot with
  a field written). If `doom_game` finds a cheaper representation, every
  crate that ticks a list gains.
* **`MF_SHADOW`.** The spectre never spawns at skill 2, so `A_FaceTarget`'s
  spread against a shadow target is implemented but only reached by a test.


### R2: fixed ticker cost on the complete roster

The 2026-09-13 pass keeps the same public functions, actor visitation order,
D3 ranks/cadence, physics guards and event order. Its reference is `b11fd7f`,
which already includes canonical grid serialization and per-impact player
armor. `Env` is now one pointer to its six-felt payload. A linear boxed
`Pass` owns the grid, RNG, pending patches, events, spawn cursor and player
defense; an inactive slot carries that pointer, and an acting monster opens
and rebuilds the record once. Its destructor forwards the grid's dictionary
squash on panic. The two roster scans use `Span::pop_front`, keeping the
same slot index for D3 while removing the separate bounds-checked lookup.
A combined `MF_COUNTKILL | MF_MISSILE` mask rejects non-actors in one test.

Measured inside the real `doom_run::step_tic` consumer, Scarb 2.16.0 proving
profile, with identical serialized inputs and complete profiler stacks:

| Fixture | Before | After | Change |
|---|---:|---:|---:|
| E1M1 idle tic 300, all 210 slots: monster subtree | 46,802 | 34,765 | -25.72% |
| Fight tic 493: monster subtree | 136,183 | 123,418 | -9.37% |
| Ticker's own disjoint cost, idle | 29,888 | 22,503 | -24.71% |
| `awake_count` disjoint cost, idle | 6,732 | 3,581 | -46.81% |
| Ticker-only attributed code, proving | 14,574 | 14,101 | -473 words |
| Complete `run_segment` program, proving | 116,287 | 115,814 | -473 words |

Direct CASM counters in the ticker loop explain the reduction: `store_temp`
falls from 20,244 to 13,620 executed instructions, copies of `Env` from
2,508 to 219, `ThingGrid` from 1,230 to 27, and each of the patch/event array
headers from 820 to 18. Mobj copies (6,696) and output `array_append`
instructions (5,670 = 210 × 27) remain identical. Those counters exclude
out-of-line callees and are not added to the disjoint profiler costs.

The first-pass 25% idle reduction is met. The 15,000-word ticker allocation
is still met; the whole-program 100,000-word target and whole-tic 12,000-step
target remain open. Traversal algorithms and the mandatory output Mobj
copies remain; the combat spike still spends most of its cost in physics.
No replay hash or budget is raised by this pass. Across complete proving
replays, including input loading and final serialization/snapshot, total
execution cost falls by 22.52% (idle), 13.60% (walk), 11.35% (door), 12.05%
(fight) and 14.98% (death). These whole-execution percentages are separate
from the single-tic subtree figures above.

`bench/profile_loop.py` derives a real pre-tic state from a golden replay,
or accepts an existing arguments file to use exactly the same state across
revisions. It runs the real executable, then `cairo-profiler` at depth 512
(default depth 100 truncates this recursive loop). The report records the
executable/input SHA-256 and checks the observed depth is below the limit.
For example, from this package's directory:

```sh
ASDF_SCARB_VERSION=2.16.0 scarb --manifest-path ../../Scarb.toml --profile proving build -p doom_run
python3 bench/profile_loop.py --scenario idle --tic 300 --out /tmp/monster-idle
python3 bench/profile_loop.py --scenario fight --tic 493 --out /tmp/monster-fight
```

Use `--profiler /path/to/cairo-profiler` if the pinned 0.17.0 binary is not
selected by the shell. To compare a revision, preserve its executables,
Sierra files and `arguments.json`, then use `--arguments` with that file.
`--keep-trace` preserves the trace for the game's `statement_costs.py` tool.

`bench/compare_replays.py` compares every output felt of the five game
replays against a preserved baseline workspace, both whole and resumed
from serialized states every 25 tics. The companion `bench/ticker_probe`
executes the raw monster API on those real boundary states and returns
all Mobj fields, RNG, defense, every event payload/position and the canonical
grid order. These raw passes cover the boundary scenes; they are not a log
of `step_tic`'s unexposed internal cues. Reports contain output digests only
after exact array equality has passed, never replacement expectations.

Build `doom_run` and an identical copy of `bench/ticker_probe` against both
workspaces before comparing. With `reference/cairo` an archived baseline:

```sh
ASDF_SCARB_VERSION=2.16.0 scarb --manifest-path bench/ticker_probe/Scarb.toml --profile proving build
python3 bench/compare_replays.py --reference /tmp/reference/cairo --json /tmp/monster-equivalence.json
```

The same harness accepts `--profile dev` after building both workspaces and
probes under dev. The validation run passed 247 exact comparisons per
profile across all five logs, 118 serialized cuts and 47 raw probe events;
every output digest also matched between dev and proving. The existing
56 monster tests, including their 700-tic checksum, remain unchanged; `bench/measure.py` continues to enforce every
recorded operation and code-size budget.

### Passive runs outside the actor loop (D29 integration base 3e210317)

`next_actor` copies consecutive passive slots in a separate small loop and
returns the next monster or missile to the ticker. The passive loop carries
only the input cursor and output array, rather than the ticker's environment,
pass record, scheduling state and other live values. Every record remains in
its original position. The actor's D3 index is the output length before that
actor is appended; no additional index advances through passive slots.

The predicate is unchanged, including its short-circuit for `KIND_NONE` even
when a direct caller supplies inconsistent flags. `awake_count` still reads
the complete initial roster before any actor runs. Ranks, look cadence, RNG,
patch application, spawned-slot selection and dictionary visitation order
remain unchanged. No persistent cache, schema field or public interface is
introduced. Two edge-case tests cover interleaved passive/actor runs, original
indices, removed slots with flags, and empty or fully passive lists.

Validation: 567 Cairo tests across 23 targets; 35 native ABI cases plus four
malformed envelopes rejected per profile; 70 exact comparisons of five full
replays, serialized cuts, D14 and terminal boundaries per profile. Physics,
player and monster benchmarks retain their existing limits. The measured
ledger is `bench/passive-runs.json`.

| Complete executable | dev before → after | proving before → after |
|---|---:|---:|
| run_segment | 125854 → 125836 | 106878 → 106855 |
| step_tic | 125981 → 125963 | 108365 → 108342 |
| genesis | 50746 → 50746 | 46434 → 46434 |

| Proving frame | before → after steps | boundary before → after | Mobj allocations |
|---|---:|---:|---:|
| idle300 | 30012 → 26298 | 266508 → 266508 | 48 → 48 |
| fight493 | 170333 → 166596 | 267743 → 267743 | 120 → 120 |

These are two exact frame measurements, not the mean or p99 across all
2946 replay tics. The complete proving program remains **106855 words**, so
the unchanged 100000-word D29 guard still fails by **6855**. No proof, AIR,
RAM or browser-throughput improvement is inferred from this VM experiment.

Reproduce with the existing game `bench_sizing/compare.py` (immutable base
executables via `--reference`, each profile), `bench_boundary/measure.py`,
then `doom_monsters/bench/profile_loop.py --arguments ... --keep-trace` and
`doom_game/bench_boxed/inspect.py` on the two fixed pre-tic arguments. Keep
Scarb 2.16.0 and the existing profiles, and check the executable/input SHA
recorded by every report. No expected values or thresholds are regenerated.

Small rosters with few passive slots pay the extra helper return per actor.
These dev benchmark tradeoffs remain inside the existing limits. Raw steps
are per iteration before subtracting the operand baseline:

| Scene | raw steps before → after | differential net before → after |
|---|---:|---:|
| monsters_ticker, 29 dormant monsters | 12854.95 → 13249.95 | 12400.95 → 12806.95 |
| monsters_ticker, 8 awake monsters (D3's cap) | 29976.1 → 30077.1 | 29968.1 → 30069.1 |
| 29 dormant monsters, nobody to look for | 9845.7 → 10240.7 | 9391.7 → 9797.7 |

The 29-dormant raw cost rises 3.07%; eight-awake raw cost rises 0.34%. The
full-roster improvement is not a universal ticker speedup.

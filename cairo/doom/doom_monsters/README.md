# doom_monsters

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
* no `Array` is allocated per candidate direction, spans are hoisted out of
  every loop (D24), no `if`-tree stands in for a table, and every felt
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

**A dormant, still monster takes a fast path.** A monster asleep with no
momentum, standing on its floor, has exactly one thing to do per tic: count
its idle frame down (and look, on its phase). Doing that in the ticker's own
loop rather than through `mobj_thinker` skips four call boundaries that each
copy the ~60-felt `World` inside `Ctx`, and it is the path 29 of E1M1's 30
monsters are on for most of a run. Measured: **51 513 → 21 890 steps/tic**
for the whole dormant roster.

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
// tic's events; `g` is updated in place (derived data, never hashed).
pub fn monsters_ticker(
    w: World, mobjs: Span<Mobj>, ref g: ThingGrid, players: Span<u32>,
    noise: Noise, tic: u32, rng: Prng,
) -> (Array<Mobj>, Prng, Array<MonsterEvent>);

pub struct Noise { pub source: u32, pub sector: u32 }   // NO_MOBJ = silent
pub fn silence() -> Noise;

pub struct MonsterEvent { pub kind: u32, pub who: u32, pub a: u32, pub b: u32, pub at: Point }
// kind: EV_SOUND, EV_PUFF, EV_BLOOD, EV_CROSS, EV_USE, EV_KILLED, EV_DROP, EV_WAKE

pub const SIGHT_TTL: u32 = 8;      // R2-A3 cache
pub const LOOK_CADENCE: u32 = 4;   // D3
pub const WINDOW: u32 = 8;         // D3

pub fn is_dormant(w: World, mo: @Mobj) -> bool;
pub fn is_awake(w: World, mo: @Mobj) -> bool;
pub fn awake_count(w: World, mobjs: Span<Mobj>) -> u32;
pub fn in_window(rank: u32, tic: u32, n: u32) -> bool;
pub fn mobj_thinker(...) -> bool;                       // one mobj, one tic
pub fn read_mobj(mobjs: Span<Mobj>, patches: Span<Patch>, i: u32) -> Mobj;
```

`actions` also exports every action function and `p_move`/`new_chase_dir`/
`look_for_players`/`check_melee_range`/`check_missile_range` for
`doom_game`'s and the tests' use.

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
loop, so the number is what a tic costs in a run.

```sh
cd bench && python3 measure.py          # measure + check budgets
python3 measure.py --update             # re-baseline after an intended change
python3 coverage.py                     # line coverage
```

| Operation | steps (net) | range checks | task budget | note |
|---|---:|---:|---:|---|
| `monsters_ticker`, player only | **598** | 5 | — | the tic's fixed cost: `Ctx`, `awake_count`, `apply` |
| `monsters_ticker`, +1 dormant monster | 740 | 14 | ≤ 60 | the marginal cost of one sleeping monster |
| `monsters_ticker`, 29 dormant (all of E1M1) | **21 890** | 446 | — | 755 per monster per tic |
| … of which `A_Look` (cadence + R2-A3 cache) | **118**/monster | — | ≤ 60 | `21 890 − 18 467`, over 29 monsters |
| `monsters_ticker`, 5 awake | **17 540** | 694 | — | see below |
| `monsters_ticker`, 20 awake | **81 311** | 3 760 | — | the window holds the *thinking* to 8 |
| `A_Chase`, walking step, sight cached | 5 123 | 182 | ≤ 1 800 | ~4 300 of it is `doom_physics::try_move` |
| `A_Look`, one sight traversal | 5 463 | 508 | — | the uncached case |
| `A_Look`, woken by a noise | 750 | 36 | — | REJECT answers; no traversal |
| `P_NewChaseDir` | 5 117 | 186 | — | up to ten `P_TryWalk`s |
| `P_CheckMissileRange`, sight cached | 472 | 27 | — | |
| `awake_count` over 30 mobjs | 1 792 | 88 | — | 60 per slot: the schedule's own pass |
| rebuilding a 30-mobj list | 2 697 | 150 | — | 90 per slot, the floor everything stands on |

**Against D2's 12 000 steps/tic.** Five awake monsters cost **17 540** and
twenty cost **81 311**, both over budget. The profile says where it goes, and
almost none of it is this crate's arithmetic:

* a zombieman's shot is `aim_line_attack` (6 339) + `line_attack` (6 608) +
  `damage_mobj` (1 471) ≈ **14 400 steps**, all `doom_physics`; five awake
  monsters fire about one shot every five tics between them;
* a sight traversal in a line-dense room is 7 700–9 700 steps
  (`doom_physics`' own figure). The R2-A3 cache with `ttl = 8` already cuts
  it to one traversal per monster per eight tics — without the cache the
  five-monster scene would be roughly twice as expensive;
* `A_Chase`'s walking step is 5 123, of which ~4 300 is one `try_move` for a
  20-unit-radius monster (the `doom_physics` README measures 4 316 in a
  line-dense cell against 964 for a player in an open one), and it runs one
  tic in four because `info.c` gives the run frames 4 tics each.

Subtracting the physics, the AI's own share is about **500–800 steps per
awake monster per tic**. The levers are therefore all in `doom_physics`
(which is being size-optimised in parallel) and in D3's cap; the twenty-awake
figure is what D3 exists to prevent, and it is reported here so that the cap
can be re-priced if the physics costs come down. With eight awake monsters —
D3's own ceiling — the scene costs about **29 000 steps/tic** as the physics
stands today, against a p99 allowance of 25 000.

**The dormant roster** is the other half of the story: 29 sleeping monsters
cost 21 890 steps/tic, of which only 3 423 (118 each) is the AI. The rest is
one materialised copy of a 27-felt `Mobj` per slot per tic plus the ticker
loop's own live set — a property of the `Array<Mobj>` state representation,
which `doom_game`'s tic loop pays for every mobj whether this crate touches
it or not. Cutting it means changing that representation, not the AI.

### Bytecode

`bench/size` calls every public entry point once; `bench/baseline` is the
same package with the same level data **and the same `doom_physics` calls**
and no `doom_monsters` call, so the difference is this crate's own code:
**34 014 words** (502 000 steps of bootloader program-hashing per segment,
S1 §5.9), against the 5 000 D23 allots to it. Where it goes is the same
place `doom_physics`' 57 000 goes: a Cairo function's bytecode grows with the
live set at every branch and with every struct it passes, and this crate
passes a `Ctx` that contains a ~60-felt `World` through four call levels and
twelve `ref` parameters, across a dispatcher with eleven arms. The measured
figure is guarded against regression (+10 %) by `measure.py`; how to
reconcile D23 with a faithful `p_enemy.c` on top of a faithful `p_map.c` is
the same open question `doom_physics` left for `doom_game`/P1.9, and the two
crates should be re-budgeted together.

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

* **Bytecode (D23).** 34 014 words for this crate against a 5 000 budget, on
  top of `doom_physics`' 57 000 against the same. The levers are structural
  (a narrower context than `World` per function, fewer call levels, fewer
  `ref` parameters through the dispatcher) or budgetary (S4b priced 32 k
  words at ~6 % of a segment). The two crates should be re-budgeted in one
  pass, not separately.
* **Steps/tic (D2).** With the physics as it stands, eight awake monsters
  cost ~29 000 steps/tic against a 12 000 average and a 25 000 p99. Either
  the physics' hitscan and sight get cheaper, or D3's cap comes down, or the
  attack cadence gets a budget of its own. This crate's own share is
  500–800 steps per awake monster per tic.
* **`P_NoiseAlert`.** A faithful flood needs a `sector -> lines` index in
  `doom_map` (about 470 entries for E1M1, ~1 000 words of data) and a
  bounded BFS. With that index the flood is a few thousand steps per shot;
  without it, the REJECT proxy under-wakes as described above. Worth
  revisiting when `doom_map` is next regenerated.
* **The list representation.** 90 steps per mobj per tic just to copy a
  27-felt record out of one `Array<Mobj>` and into the next, before anything
  thinks — 2 700 steps/tic for E1M1's 30 mobjs, more once the items are in
  the list. If `doom_game` finds a cheaper representation, every crate that
  ticks a list gains.
* **`MF_SHADOW`.** The spectre never spawns at skill 2, so `A_FaceTarget`'s
  spread against a shadow target is implemented but only reached by a test.

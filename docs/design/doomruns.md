# `DoomRuns` — the consumer contract of the fact registry (P4.2)

> Specification and **measured** cost of the contract that turns one verified batch fact into
> game records. Code: `cairo/doom_contracts/crates/doom_runs/` (+ `crates/recursion_outputs/`),
> model and drive: `cairo/doom_contracts/tools/doomruns_{model,drive}.py`, receipts:
> `cairo/doom_contracts/results/doomruns_receipts.json`. Measured on **starknet-devnet 0.10.0**
> (Starknet 0.14.4) at the S5 mainnet price snapshot, 2026-09-12. Nothing was sent to a public
> network. Upstream half of the design: `docs/design/onchain-verifier.md` §6.

## 0. Verdict

| Target (P4.2) | Result |
|---|---|
| < 5 % of a fact's verification (3.81e9 L2 gas) for N = 25 segments | **0.68 %** (25 segments, one game) to **3.34 %** (25 segments, 25 games) — the worst shape, 25 one-segment games, is 127.1 M |
| one `submit_batch` ≤ 90 % of the 1.21e9 invoke cap | **58.3 %** at the largest batch driven (480 leaves, 96 games); N = 25 is **2–10 %** |
| max N per call | **≈ 400 leaves / 80 games** per invoke (4 324 calldata felts, 49.8 % of the cap), bounded by the ~4 990-felt calldata policy, not by gas; beyond that, `register_member` splits the batch |
| leaf recomposition byte-identical to the proved root | the S4 `N = 1..4` real root proofs recompose to the `output_hash` the on-chain verifier returned (`recursion_outputs` tests), and the 10-felt batches match an independent Python model |
| replay publication optional and verified | `+0.5 %` gas at N = 1, **+11.1 M (+24 %)** for 25 segments of packed log (575 felts); every log folded and compared to its segment's `inputs_commitment` before it is emitted |
| declare (once) | 1.179e9 L2 gas ≈ **35.9 STRK**; class 8 572 sierra felts (10 % of the cap), 19 860 casm felts (24 %) |

Per game, at the S5 mainnet snapshot (30.5 gFri, 0.0288 $/STRK): a five-game batch of 25
segments costs **1.41 STRK ≈ 0.041 $** to record — **0.28 STRK ≈ 0.008 $ per game**, against
the ≈ 15 STRK per game of the fact itself at M = 8. The consumer is ~2 % of a submission's
total cost.

## 1. Where it sits

```
browser → wrapper: segments → leaf proofs → one recursive tree per batch (M games)
                                     │
        root proof (96 k felts) ─────┴──→ StwoCircuitRouter (P4.0), 5–6 tx, 3.81e9 gas
                                              └─ registers fact = poseidon(circuit_hash ‖ output_hash)
                                                                 │  is_valid(fact)
 GET /v1/batches/{id} → leaves[] (fold order) ──→ DoomRuns.submit_batch ──→ Run records,
        + the ten public felts of each segment          (this document)      leaderboards,
        + the packed input logs (optional)                                   Replay events
```

`DoomRuns` never sees a proof. It re-derives the same `output_hash` the verifier computed, from
data that is 10 felts per segment, and asks the router whether that fact exists. Everything
after that gate is bookkeeping over **proven** values.

## 2. Interface

```cairo
fn submit_batch(version_id: u32, leaves: Array<LeafOutput>, members: Array<Member>,
                replay: Array<ReplayLog>) -> u32;          // number of members accepted
fn register_member(version_id: u32, leaves: Array<LeafOutput>, member: Member,
                   replay: Array<ReplayLog>) -> bool;      // the one-member split

fn get_run(run_id: felt252) -> Run;                        // finished runs (EXIT)
fn get_attempt(run_id: felt252) -> Run;                    // DEAD runs
fn is_run_registered(run_id: felt252) -> bool;             // either of the two
fn leaderboard(version_id: u32, kind: u8, offset: u32, limit: u32) -> Array<BoardRow>;
fn leaderboard_len(version_id: u32, kind: u8) -> u32;
fn player_run_count(player: ContractAddress) -> u32;
fn player_runs(player: ContractAddress, offset: u32, limit: u32) -> Array<felt252>;
fn batch_fact(version_id: u32, leaves: Array<LeafOutput>) -> felt252;   // check before paying
fn run_id_of(version_id: u32, level_id: u32, leaves: Array<LeafOutput>) -> felt252;
fn get_version(version_id: u32) -> Version;
fn genesis_of(version_id: u32, level_id: u32) -> felt252;
fn owner() -> ContractAddress;  fn is_frozen() -> bool;

fn add_version(version_id: u32, version: Version);         // owner, before the freeze
fn set_genesis(version_id: u32, level_id: u32, genesis: felt252);
fn freeze();                                               // one-way
```

`LeafOutput` is the ten public felts of D14 in `Serde` order — `version, h_in, h_out,
tic_start, tic_end, status, inputs_commitment, kills, items, secrets` — i.e. exactly the tail
of the leaf bootloader's preimage. `Member` is `{player, level_id, leaf_start, leaf_len}`: a
half-open range of **leaf positions in fold order**, which is what `GET /v1/batches/{id}`
returns as `leaves[]`. `ReplayLog` is `{leaf_index, packed}`, the packed input log of one
segment (7 tics per felt).

Events: `RunSubmitted`, `AttemptRecorded`, `MemberRejected {member_index, player, reason,
leaf_start, leaf_len}`, `Replay {run_id, leaf_index, tic_start, tic_end, packed}`,
`VersionAdded`, `GenesisSet`, `Frozen`.

**The fold order is the leaves array.** The wrapper must place a game's segments contiguously
and in segment order; a batch whose leaves are in any other order simply recomposes to a
different `output_hash` and fails the fact gate.

**`fact_inputs` are not passed.** Everything the fact needs is either pinned (the
multiverifier's circuit hash, the leaf circuit hash and the program hash come from the version
table) or recomputed (the `output_hash`). A caller cannot choose them, so it cannot aim at
another batch's fact.

## 3. The version table

One entry per `(verifier version, circuit registry, program)`:

| field | what it pins |
|---|---|
| `program_hash` | `preimage[0]` of every leaf — the executable that produced the segments |
| `program_hash_function` | `'blake'` or `'poseidon'`: the same executable hashed the other way has another hash (S4b), so the **pair** is pinned |
| `leaf_circuit_hash` | the leaf verifier circuit of the registry (8 u32 words, stored as two u128 limbs) |
| `multiverifier_hash` | the root node's circuit hash — the first half of the fact |
| `registry_name` | e.g. `'doom'`, `'doom_fold4_min'` (documentation/inspection) |
| `verifier_router` | the P4.0 router that registers facts for that registry |

Governance is add-only: `add_version` refuses to overwrite an existing id, there is no upgrade
path, and `freeze()` closes the table for good (R3-A6). A new verifier version or a new season
is a **new entry** (and a new router), never a mutation. Freezing does not stop submissions —
it pins the rules.

**Genesis.** `genesis(version_id, level_id)` is a **constant per (version, level)**, pinned by
the owner with `set_genesis` before the freeze, and it is what the first segment's `h_in` must
equal. In production it is the Poseidon hash of that level's initial `GameState` (the value
`state_hash::hash_game_state` returns for a fresh game), which is what makes the level
declaration in `Member.level_id` trustworthy: declaring the wrong level fails the `h_in` check,
because another level has another initial state. A level with no pinned genesis rejects its
members (`unknown level`). The seed, skill and level are program constants for this season
(R10-A4), so the pair `(program_hash, genesis)` is the whole "which game is this" statement.

*Limitation, deliberate for now*: the genesis values are pinned by hand by the owner. P4.3 must
publish how each one was computed (a reproducible `doom_game` run) so that anyone can check the
table.

## 4. Validation

### Batch level — these revert the whole call

| check | message |
|---|---|
| the version exists | `doomruns: unknown version` |
| the batch is non-empty | `doomruns: empty batch` |
| the recomposed fact is registered by the version's router | `doomruns: fact not registered` |

The recomposition is `recursion_outputs`: each leaf's preimage `[program_hash, out_0…out_9]`
is blake2s-hashed with the Cairo0 felt encoding, the leaves are folded two-to-one in order
(unpaired last entry carried up, a single leaf folded with itself), and
`output_hash = blake2s(multiverifier_hash ‖ root.output)`. Then
`fact = poseidon(multiverifier_hash ‖ output_hash)`, the 16 u32 words the router hashes.
Any tampered output word — one extra kill — moves the fact and the call reverts.

### Member level — these skip **one** member, with a `MemberRejected` event (D18)

| reason | rule |
|---|---|
| `bad range` | `leaf_len == 0` or `leaf_start + leaf_len > leaves.len()` |
| `unknown level` | no genesis pinned for `(version_id, level_id)` |
| `bad genesis` | `h_in[0] != genesis(version, level)` |
| `bad tic start` | `tic_start[0] != 0` |
| `bad layout` | a segment's `version` field is not `1` |
| `abort segment` | any segment reports `ABORT` (3) — a provably invalid execution (D14/R4-A2) |
| `tic gap` | `tic_end[i] != tic_start[i+1]`, or `tic_end < tic_start` inside a segment |
| `chain break` | `h_out[i] != h_in[i+1]` |
| `early terminal` | a non-final segment is not `RUNNING` |
| `unfinished` | the last segment is still `RUNNING` |
| `already registered` | this run id is already recorded (see §5) |
| `replay incomplete` | replay data supplied for part of the member's range only |
| `replay length` | a published log is not `ceil(tics / 7)` felts long |
| `replay commitment` | a published log does not fold to that segment's `inputs_commitment` |

`DEAD` (1) on the **last** segment is accepted and recorded as an **attempt**: a `Run` in the
`attempts` map, an `AttemptRecorded` event, no leaderboard entry, no player-index entry. `EXIT`
(2) on the last segment is a finished run. `ABORT` is refused outright — it is the status a
segment returns instead of trapping (R4-A2), so accepting it would record a run the engine
itself declared invalid.

Why per member and not per batch: the wrapper verifies every leaf before folding it, so an
invalid member is improbable; if one appears anyway, it must not cost the other players their
already-paid verification (D18).

## 5. Run ids and replay protection (R10-A1)

```
run_id = poseidon('HP.RUN' ‖ version_id ‖ level_id ‖ genesis ‖ n_segments
                  ‖ inputs_commitment[0..n] ‖ h_out[last] ‖ tic_end[last])
```

The per-segment `inputs_commitment` chain (D13) *is* the identity of a run: it is the fold of
the exact inputs the proof consumed. Two consequences:

- the same inputs cannot be recorded twice, by anyone — the id does not contain the submitter,
  so a copycat replaying someone else's log hits `already registered`;
- the id is computable off chain (`run_id_of` is also a view), so a client can check
  `is_run_registered` before paying.

Cutting a run into different segments changes the commitments (D13 is per segment, not
chained), hence the id: the *same game re-cut* would be a different record. That is the price
of D13's re-cutting robustness, and it does not open a door — re-cutting requires re-proving
every segment, and the leaderboard entry would be a second, honestly proved run of the same
inputs. If that ever matters, the fix is a canonical cut rule in the wrapper, not a contract
change.

## 6. Replay publication (D13 / R10-A3)

`replay` is an **optional**, ascending-by-`leaf_index` array. For a member it must cover the
whole range or none of it. Each log is checked with the ported commitment fold —
`commit_log(packed) = inputs_seed() then 2-to-1 Poseidon per felt`, the function
`cairo/crates/state_hash` implements and `bench/reference.py` models — against that segment's
`inputs_commitment`, and its length against the segment's tic span. Only then is it emitted as
a `Replay` event, so what the chain publishes is exactly what the proof consumed.

Cost: +0.5 % at N = 1 (23 felts of log), **+11.1 M gas (+24 %)** for 25 segments of a 160-tic
cut (575 felts). It is worth paying for a leaderboard entry and skipping for a bulk backfill,
which is why it is a per-call decision rather than a contract mode.

## 7. Leaderboards — why top-N on chain

Two boards per version: `KIND_SCORE = 0` (higher `score` first) and `KIND_TIME = 1` (lower
`tics` first, stored as `u32::MAX - tics` so both boards are one descending key). Each keeps
**`BOARD_SIZE = 10`** entries of `{run_id, key}`.

The cheap option is the one implemented, and it is cheap because of the **cutoff gate**: when
the board is full, a run that does not beat the tenth entry costs *one storage read* and stops.
Only a run that enters the board pays the shift (at most 10 reads + 11 writes). Measured: the
same 25-game batch costs 127.1 M on empty boards (every run inserts) and **100.7 M** once they
are saturated — a 21 % spread, and that is the pessimistic case where each run beats the
previous one.

The alternative — events + indexer — was rejected for the *top ten* because the podium is what
the game shows on chain and what a contract may later read (prizes, seasons). Everything
**below** the top ten is exactly the events + indexer design: `RunSubmitted` carries score,
tics and stats, `player_runs` indexes a player's runs, and a full ranking is an indexer's job.
`score = 100·kills + 25·items + 500·secrets` (season 1) is computed on chain from the last
segment's cumulative counters, so the board cannot be gamed by the submitter.

## 8. Storage

| what | slots | when |
|---|---:|---|
| `Version` | 8 | once per version (owner) |
| genesis of a level | 1 | once per level (owner) |
| a `Run` (`RunNode`: player, three packed u128s, fact) | **5** | per accepted member |
| player index (`player_runs[player][n]`, `player_count`) | 2 | per finished run |
| board entry + length | 2 (+1) | only when the run enters a board |

A write costs ≈ 498 k L2 gas, a re-read ≈ 120 k (S5 §8.5), so packing matters more than anything else in this
contract: `version_id(32) | level_id(32) | tics(32) | n_segments(16) | status(8)`,
`kills(32) | items(32) | secrets(32)` and `score(64) | block(64)` fit three u128 slots, which
takes a run record from 12 naive slots to 5 — 3.5 M gas saved per run. Existence is the
`player` field of the node (one read), so there is no separate "registered" flag.

## 9. Gas (devnet 0.10.0, `--state-archive-capacity full`, S5 prices)

`tics_per_segment = 160` (the reference cut), one version per scenario so every leaderboard
starts **empty** — these are cold, worst-case numbers.

| batch | segments | games | replay | calldata felts | L2 gas | writes | % of the 1.21e9 cap | % of a fact | fee (STRK) |
|---|---:|---:|---|---:|---:|---:|---:|---:|---:|
| `n1_1game` | 1 | 1 | no | 18 | 8 590 800 | 15 | 0.71 | 0.225 | 0.262 |
| `n1_1game_replay` | 1 | 1 | **yes** | 43 | 8 635 520 | 15 | 0.71 | 0.227 | 0.263 |
| `n8_1game` | 8 | 1 | no | 88 | 12 907 200 | 15 | 1.07 | 0.339 | 0.393 |
| `n8_8games` | 8 | 8 | no | 116 | 52 258 000 | 92 | 4.32 | 1.372 | 1.593 |
| `n8_8games_replay` | 8 | 8 | **yes** | 316 | 53 337 760 | 92 | 4.41 | 1.400 | 1.626 |
| `n25_1game` | 25 | 1 | no | 258 | 25 977 600 | 15 | 2.15 | **0.682** | 0.792 |
| `n25_5games` | 25 | 5 | no | 274 | 46 387 200 | 59 | 3.83 | 1.218 | 1.414 |
| `n25_5games_replay` | 25 | 5 | **yes** | 899 | 57 475 200 | 59 | 4.75 | 1.509 | 1.752 |
| `n25_25games` | 25 | 25 | no | 354 | 127 149 200 | 219 | 10.51 | **3.337** | 3.876 |
| `n25_25games` (boards saturated) | 25 | 25 | no | 354 | 100 751 200 | 177 | 8.33 | 2.645 | 3.071 |
| `n50_10games` | 50 | 10 | no | 544 | 91 079 200 | 114 | 7.53 | 2.391 | 2.776 |
| `n100_20games` | 100 | 20 | no | 1 084 | 161 823 200 | 184 | 13.37 | 4.248 | 4.932 |
| `n200_40games` | 200 | 40 | no | 2 164 | 309 341 200 | 324 | 25.57 | 8.120 | 9.428 |
| `n400_80games` | 400 | 80 | no | 4 324 | 602 407 200 | 604 | 49.79 | 15.812 | 18.361 |
| `n480_96games` | 480 | 96 | no | 5 188 | 705 925 600 | 716 | 58.34 | 18.529 | 21.516 |

Marginal costs, from the same receipts:

| | L2 gas |
|---|---:|
| envelope + fact gate (recompose 1 leaf, `is_valid`, 1 run) | 8.59 M |
| one **extra segment** in an existing game | **0.72 M** (0.05 M of it is the 10 felts of calldata) |
| one **extra game** of one segment | **4.94 M** (9 storage writes: 5 run + 2 index + board) |
| a **rejected** member (25 leaves, 5 members, all replays) | 20.5 M total, 0 writes |
| replay publication, per 160-tic segment (23 felts) | ≈ 0.44 M |
| `add_version` / `set_genesis` (owner, once) | 5.29 M / 1.84 M |
| declare `DoomRuns` / deploy | 1.179e9 / 0.0532 STRK |

**Max N per call.** Gas is not the limit — 480 leaves is 58 % of the invoke cap. The limit is
calldata: a batch is `2 + 10·L + 4·M + 2` felts, and the protocol's per-transaction calldata
policy is ~4 991 felts (S5 §8.5/§9, `onchain-verifier.md` §0), so **L ≈ 400 leaves / 80 games** is the practical ceiling per
invoke (the 480-leaf row above is over that policy limit; devnet does not enforce it, so it is
informational). Beyond that the batch splits: `register_member(version_id, leaves, member,
replay)` re-sends the leaves and re-runs the fact gate for one game — measured 25.0–25.8 M per
call for a 25-leaf batch, i.e. 125.8 M for the five members against 46.4 M in one call. Splitting
is therefore a fallback for oversized batches, not an optimisation; the wrapper's default M = 8
games needs one call.

## 10. Tests

`(cd cairo/doom_contracts/crates/doom_runs && snforge test)` — **42 tests**:

- recomposition of the 2 + 1 + 3 synthetic batch and of the single-leaf (self-fold) batch
  against the Python model's `output_hash`, fact and run ids; digest packing round trip;
- the fact gate: unregistered fact, tampered leaf (the fact moves), unknown version, empty
  batch;
- the happy path: three games recorded, records, player index, `RunSubmitted` payload;
  `register_member` for one game;
- every member-level rejection: `ABORT`, unfinished, chain break, tic gap, early terminal,
  wrong genesis, non-zero first tic, bad layout, unpinned level, out-of-range members, and the
  mixed batch where one member is skipped and the others are recorded;
- `DEAD` → attempt (no board, no index), replay of the same run refused;
- replay data: verified and published, wrong commitment, wrong length, partial coverage;
- leaderboards: ordering by score and by time, paging, and the top-10 cutoff with 12 runs;
- version table: read back, stranger refused, no mutation, freeze closes both tables, a frozen
  table still accepts runs.

`(cd cairo/doom_contracts/crates/recursion_outputs && snforge test)` — **18 tests**: the
upstream goldens (`four_leaves`), the odd carry and self-fold topologies, the blake2s and felt
encoding vectors, and the **real S4 root proofs** `N = 1, 2, 3, 4` whose recomposed
`output_hash` is the one the on-chain verifier returned.

The Python model is independent by construction (`poseidon_py` + `hashlib.blake2s`, no shared
code), and its own commitment path reproduces the reference vector pinned by
`cairo/crates/segment` (`0x5a1a0083…8cad2` for a nine-tic log), which is what ties the ported
`commit_log` to the production crate.

## 11. Open questions for P4.3 (client orchestration)

1. **Who submits.** The consumer transaction is caller-independent (the player is a field of
   `Member`, not the caller), so the wrapper can submit for everyone — one call for the whole
   batch, 0.28 STRK per game — or each player can submit their own member. The first is
   cheaper and needs a sponsoring policy (R7-A4); the second needs the leaves of the *whole*
   batch in each call anyway, so it costs ~5× more. Recommended: the wrapper submits, the
   player's address is recorded.
2. **`leaves[]` → `Member`.** `GET /v1/batches/{id}` gives `run_id → positions`; the client
   must turn that into contiguous `(leaf_start, leaf_len)` ranges and refuse to submit if a
   run's positions are not contiguous (the contract would reject it as a chain break). The
   wrapper should guarantee contiguity at fold time.
3. **Level declaration.** `Member.level_id` is checked against the pinned genesis, so the
   client must know which `(version, level)` its run belongs to; the wrapper knows the program,
   so it should return `level_id` with the batch.
4. **Replay on or off.** +24 % gas for 25 segments. Suggested default: on for a run that enters
   a leaderboard, off otherwise — which the client cannot know before submitting, so either
   always on for solo/ranked submissions, or a second `Replay`-only publication path (not
   implemented; today the logs must accompany the submission).
5. **Genesis provenance.** The table pins genesis values by hand; P4.3 should ship the script
   that recomputes them from `doom_game` so the pinning is auditable, and the UI should display
   the `(program_hash, genesis, registry)` triple of the season.
6. **Estimation.** A submission is `5 or 6` verifier transactions + 1 consumer transaction; the
   consumer's bounds should be estimated with `starknet_simulateTransactions` like the verifier
   ones (S5 §6), with l1_data_gas margin — a 480-leaf batch needs ~66 k l1_data_gas and a tight
   bound reverts.
7. **Attempts (DEAD) UX.** They are recorded but invisible on the boards; the client should
   decide whether to submit them at all (they cost the same as a run).

## 12. Reproduce

```bash
cd cairo/doom_contracts                              # scarb 2.18.0, snforge 0.61.0
(cd crates/recursion_outputs && snforge test)        # 18
(cd crates/doom_runs && snforge test)                # 42
python3 tools/doomruns_model.py                      # the model's vectors
python3 tools/doomruns_model.py --emit-fixtures && (cd crates/doom_runs && scarb fmt)

starknet-devnet --seed 42 --port 5079 --accounts 3 --state-archive-capacity full \
  --initial-balance 100000000000000000000000 \
  --gas-price 1054411845 --gas-price-fri 92599658875965 \
  --data-gas-price 426840 --data-gas-price-fri 37485578886 \
  --l2-gas-price 347016 --l2-gas-price-fri 30475398907
sncast --accounts-file accounts.json account import --url http://127.0.0.1:5079/rpc \
  --name devnet42 --type oz --address <addr> --private-key <key>
python3 tools/doomruns_drive.py --out results/doomruns_receipts.json \
  --accounts-file accounts.json --url http://127.0.0.1:5079/rpc
```

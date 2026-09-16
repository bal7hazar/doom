<!--
SPDX-FileCopyrightText: 2026 Hellproof contributors
SPDX-License-Identifier: Apache-2.0
-->

# `prover-node` — the open prover of D35

D35 takes the proof of a game out of the player's browser: the client plays, then **commits**
the game on `DoomRuns` with its packed journal (7 tics per felt) and an escrowed bounty, and
**any address** may execute that journal, prove its segments, fold them and register the run
against the commitment — collecting the bounty. No privileged key, no operator: the sponsor
runs a node of this package for availability, a player can run the same binary for their own
game, and the browser proof becomes optional.

This package is that binary. It is a pipeline of pluggable stages, each behind an interface with
a real implementation and a test double, so the whole machine runs in `npm test` with no proof
and no network.

```text
  DoomRuns ──RunCommitted + RunLog chunks──► discovery ──policy──► queue
                                                                     │
  job: reconstruct ─► cut (Executor) ─► prove (Prover) ─► fold (wrapper) ─► register (D28)
       journal +      run_segment per     stwo-run-and-    PUT segments,      5 verifier tx +
       commitment     segment, resources   prove, leaf      root ?include=     register_member
       checks         ─► SegmentPlanner    bootloader,      proof              with replay logs
                                           lock, timeout                        ─► CommitmentProved
```

## Quick start

```bash
cd infra/prover-node && npm install       # node >= 22, starknet.js 10.8.0
npm test                                   # 49 tests: 44 mocked, 5 on the real executor (skipped without scarb)
npm run typecheck

# what a poll would do, without a wrapper or a key: reconstruct, execute and cut only
npm run prover-node -- run --rpc http://127.0.0.1:5081/rpc --doom-runs 0x… --once --stop-after cut

# the real thing on Sepolia (or a devnet): key from the environment, never from a flag
set -a; . ~/.hellproof/sepolia.env; set +a       # PROVER_NODE_ADDRESS, PROVER_NODE_PRIVATE_KEY
npm run prover-node -- run --rpc https://… --doom-runs 0x… --router 0x… \
    --wrapper https://wrapper… --min-bounty 2 --versions 1 --watch

npm run prover-node -- status --work .work
```

`--help` lists every flag. The node writes everything under `--work` (default `.work`): one
directory per commitment with `job.json`, `proofs/<i>.json`, the prover's scratch and the
folded `batch.json`; plus `discovery.json` (cursor and known commitments), `echoes.json` (the
D28 checkpoint echoes, `infra/submit`'s `FileEchoStore`), `metrics.json` and `logbook.txt`. A
relaunch resumes every pending job from its last persisted stage: a proved segment is never
re-proved, an uploaded segment never re-uploaded, a paid verifier transaction never re-sent.

## The stages

| stage | module | real implementation | test double |
|---|---|---|---|
| discovery | `discovery.ts`, `commitments.ts` | `starknet_getEvents` through `rpcSource.ts` (the indexer's pager, reorg window re-scanned) | a fixed event list |
| policy | `policy.ts` | bounty floor, supported versions, tic ceiling, player lists, bounded queue ordered by bounty per tic | — |
| reconstruction | `journal.ts`, `commitment.ts` | `RunLog` chunks concatenated, `packed_len(tics)`, lanes, `commit_log(journal) == inputs_commitment`, `commitment_id` recomputed, expiry | — |
| execution and cut | `executor.ts`, `segmenter.ts` | `ScarbExecutor`: `scarb execute` on `genesis` / `step_tic` / `run_segment` | `FakeExecutor`: a toy game with the real ABI, Poseidon state hash and D13 commitment |
| proof | `prover.ts`, `proving.ts` | `SubprocessProver`: `stwo-run-and-prove` as a leaf-bootloader task, under `mkdir $SCRATCH/.proof-lock`, process group killed on timeout | `FakeProver`, with programmable failures |
| fold | `fold.ts` | `@hellproof/wrapper-client`, resumable `PUT …/segments/{i}` then `/complete`, `GET /v1/batches/{id}?include=proof` | an in-memory `fetch` |
| registration | `register.ts`, `nodeSigner.ts` | `client/src/chain` (`prepareSubmission`, `resumePoint`, `runSequence`, D28 simulate-before-send) with `NodeSigner` | a mocked `RpcClient` and signer |

### The cut is the client's

`segmenter.ts` drives the client's own `SegmentPlanner` (`client/src/prove/planner.ts`) exactly
as `pipeline.ts::planNext` does — propose, execute, size, judge, shrink, halve past
`maxProbes` — so a segment is only ever proved after a real execution the runtime itself said
fits (D26). `test/segmenter.test.ts` replays the browser loop independently on the same cost
model and checks the boundaries probe for probe.

Two things differ from the browser. The journal is known in full, so the last segment is cut
short instead of waiting for more tics. And **every non-final segment covers a multiple of 7
tics**: see the settlement rule below.

### What settles the commitment (and constrains the cut)

`DoomRuns` pays the bounty to the caller of `register_member` / `submit_batch` when the member's
version, level, player, `tics` and genesis equal the commitment's **and** the game-level
`inputs_commitment` can be recomputed:

- one segment: it is the leaf's own `inputs_commitment`;
- several segments: the contract folds the **concatenation of the `ReplayLog`s supplied with the
  submission**. A segment's log is its slice re-packed from its first tic (D13 is per segment),
  so the concatenation is the committed journal only when every non-final segment's length is a
  multiple of 7.

Hence, in this package:

1. every proposal — the planner's and every shrink — is rounded **down** to a multiple of 7 before
   it is executed (`alignCandidate`), which never exceeds the D26 ceiling; a ceiling that leaves no
   room for seven tics refuses the run;
2. `checkSegmentChain` verifies the alignment and that the concatenated segment logs are the
   committed journal felt for felt, on top of `verifyChain` (genesis, `h_out → h_in`, tic
   continuity, counters, terminal status) and the per-segment commitment fold;
3. `registerRun` publishes the replay logs (`replay: true`) and **forces them on** for a
   multi-segment member even when `--no-replay` is given — without them the run is recorded but
   the bounty is not paid;
4. `tics` is the journal's exact length: `packed_len(tics)` felts, the last felt's spare lanes
   empty, and the last segment's `tic_end` equal to it.

There is no separate claim call. The `CommitmentProved` event in `register_member`'s receipt is
the payment; the node logs it, counts a run without it as `unsettled`, and checks
`get_commitment` before paying anything (already proved by someone else, reclaimed, missing, or
different from what was discovered).

### The assumed contract ABI (`commitments.ts`)

Everything ABI-dependent about commitments is in that one file, as delivered by the contract
wave: `RunCommitted { commitment_id*, player*, version_id*, level_id, genesis, inputs_commitment,
tics, bounty: u256, expires_at: u64, n_chunks: u32 }`, `RunLog { commitment_id*, chunk, offset,
packed }` (the journal is **not** stored on chain: it is emitted in `n_chunks` events of at most
256 felts in the same transaction), `CommitmentProved { commitment_id*, run_id*, prover*, player,
bounty }`, `CommitmentReclaimed { commitment_id*, player*, bounty }`;
`commitment_id = poseidon('HP.COMMIT', version_id, level_id, player, commit_log(packed))`; the
`Commitment` struct of `get_commitment`. The two selectors the wave announced are pinned in
`test/commitments.test.ts`.

## Real executor

`ScarbExecutor` (`src/scarbExecutor.ts`, the default `--executor scarb`) runs the three
`doom_run` executables of `cairo/doom/doom_run/README.md` as subprocesses, one `scarb execute`
per call, the way `bench/prove_segment.sh` steps 2 and 4 do. It has been validated against the
real engine, without a proof (`test/realExecutor.test.ts`, below).

**Prerequisites.** Scarb **2.16.0** (the release the executables are built and run with;
`ASDF_SCARB_VERSION=2.16.0` is set for asdf users) and the proving profile built once from the
repository root — `--no-build` never rebuilds:

```bash
scarb --manifest-path cairo/Scarb.toml --profile proving build -p doom_run
# -> cairo/target/proving/{genesis,step_tic,run_segment}.executable.json
```

**Where things are.**

| what | default | override |
|---|---|---|
| the `scarb` binary | `scarb` on the PATH | `HELLPROOF_SCARB=/path/to/scarb` in the environment, or `--scarb <bin>` |
| the workspace manifest | `cairo/Scarb.toml` of this checkout | `--manifest <Scarb.toml>` |
| the executables | `<manifest dir>/target/proving/<name>.executable.json` | build with another `--profile` and pass it to `ScarbExecutor` (`profile`) |
| argument files | `<work>/execute/<name>_<n>.args.json` (the JSON array of `0x…` felts `prove_segment.sh` writes) | `--work` |

The CLI probes `scarb --version` and the three executables before its first poll and fails
with the build command when one is missing. Each call is exactly:

```bash
scarb --manifest-path cairo/Scarb.toml --profile proving execute -p doom_run \
  --executable-name run_segment --no-build --output none \
  --arguments-file <work>/execute/run_segment_<n>.args.json \
  --print-program-output --print-resource-usage
```

**What Scarb prints, and what the executor decodes.** Program output is one felt per line,
**decimal and signed** (a felt above p/2 comes out negative, e.g. a commitment as
`-1490066978…`): every token is reduced into the field before it becomes a `0x…` felt.
`--print-resource-usage` writes the step count **with thousands separators** (`steps:
2,383,556`); a first version of the parser read that as 2, so the D26 ceiling never bound —
the parser is now pinned on a verbatim transcript. `--output none` keeps the trace and memory
off the disk; Scarb still creates an empty `cairo/target/execute/doom_run/execution<N>/` per
call, which the executor removes. The envelopes are checked as the browser Worker checks them:
`genesis` returns `[state_len, state…, genesis_hash]` with a schema-2 state at tic zero
(6 362 felts on E1M1, not the fake's 47; an unknown level's `([], 0)` is refused), `step_tic`
returns `[status, state_len, state…, snapshot_len, snapshot…]` with the snapshot length
consistent, `run_segment` exactly the ten D14 felts.

**Steps-only.** `scarb execute` reports steps and builtin counters, not the AIR component
sizing; the segment record says `rowsChecked: false` and the cut is bound by the D26 step
ceiling alone (2.3 M steps for `--threads 1`, 1.5 M threaded, or `--max-steps`).

**Measured here** (4 cores, `RAYON_NUM_THREADS=1`, E1M1 walk from genesis, one call each,
wall time of the whole `scarb execute` subprocess):

| `run_segment` | steps | ≈ steps / tic | wall |
|---|---|---|---|
| 35 tics | 1 338 951 | 38 300 (≈ 290 k fixed + 30 k / idle tic) | ≈ 1.0 s |
| 70 tics | 2 383 556 | 34 100 | ≈ 1.3 s |
| 140 tics | 5 164 402 | 36 900 (movement, lift: ≈ 40 k / tic) | ≈ 2.2 s |
| `step_tic`, 32 words | 1 131 197 | — | ≈ 0.9 s |

The fixed cost of a segment (parsing the 6 362-felt state, two Poseidon hashes, the output) is
≈ 290 k steps; a tic costs ≈ 30–40 k while the level is quiet and **≈ 90–110 k once the
monsters are awake**. On the real exit route, under the browser's 2.3 M ceiling, the planner
therefore shrinks its segments from 56 tics (2 106 183 steps) through 49, 35 and 28 down to
21 tics (≈ 1.8–2.2 M steps) for the second half of the game: 27 segments for 677 tics, cut in
89 s — 62 `scarb execute` calls (27 accepted probes, 13 rejected, 22 `step_tic` advances) of
≈ 1.0–1.4 s each, the subprocess start dominating. The node's 64 GB calibration (D35, 8–13 M
steps) is what makes the segments several times longer; `--max-steps` sets it.

**Running the integration test.** `test/realExecutor.test.ts` is part of `npm test`: it skips
itself, with the reason on stderr, when `scarb` cannot be run or the executables are not built,
and otherwise executes (one subprocess at a time, a few minutes) the two real E1M1 journals of
`cairo/doom/doom_game/regression/` rebuilt from the corpus definitions and pinned by the corpus's
own `input_sha256`:

```bash
scarb --manifest-path cairo/Scarb.toml --profile proving build -p doom_run
cd infra/prover-node && HELLPROOF_SCARB=$(command -v scarb) RAYON_NUM_THREADS=1 npx vitest run test/realExecutor.test.ts
```

- `walk_lift` (350 tics, RUNNING): one `run_segment` over the whole log reproduces the golden's
  ten D14 felts exactly (its `h_out` is `WALK_HASH` of `doom_game/src/tests/e1m1.cairo`); the same
  run as two 7-aligned segments joined by `step_tic` chains (`h_out` = next `h_in`), each
  `inputs_commitment` folds from its own slice, and the two logs concatenate to the journal whose
  `commit_log` is the golden's.
- `exit_route` (677 tics, a real spawn-to-EXIT game — what a player commits): `cutJournal` cuts
  it under the 2.3 M ceiling, every non-final segment a multiple of 7 tics, the chain is
  continuous from the golden genesis to the golden `h_out` with `EXIT`, 0 kills, 4 items, and the
  concatenated replay logs are the committed journal. Then the whole node — fake events, `FakeProver`,
  in-memory wrapper, mocked signer — takes the same commitment to `registered` on this executor,
  with the same boundaries.

## Configuration

| what | where |
|---|---|
| RPC, `DoomRuns`, router, wrapper | `--rpc`, `--doom-runs`, `--router`, `--wrapper` (`--wrapper-key`) |
| policy | `--min-bounty <STRK>`, `--versions`, `--max-tics`, `--allow-player`/`--deny-player`, `--max-queue` |
| the runtime | `--executor scarb` (default; `--manifest`, `--scarb` or `HELLPROOF_SCARB`; see "Real executor") or `fake` |
| the prover | `--prover stwo` (default) with `--stwo-bin`, `--bootloader`, `--params`, `--executable`, `--lock-dir`, `--proof-timeout`, `--proof-format`, `--threads`; defaults follow `prove_segment.sh` (`$SCRATCH`, `$PROVING`) |
| the cut | `--max-steps` (D26 ceiling), `--log-size` (registry rows, log2), `--program-hash`, `--genesis v:l=0x…` |
| dry runs | `--stop-after cut` (no wrapper, no key), `--stop-after proved`, `--stop-after folded` (no key) |
| the signer | `PROVER_NODE_ADDRESS`, `PROVER_NODE_PRIVATE_KEY` in the environment — the documented place is `~/.hellproof/sepolia.env`, sourced by the operator (`set -a; . ~/.hellproof/sepolia.env; set +a`); this package does not read that file, never prints the key, and refuses `SN_MAIN` |

## Metrics and logbook

`metrics.json` counts polls, commitment events seen, selected / skipped, registered (and
unsettled), refused, failed, lost races, segments cut / proved, proof failures and the STRK
settled, with count / mean / max wall-clock per stage (`reconstructed`, `cut`, `proved`,
`folded`, `registered`). `logbook.txt` is one timestamped line per event, prefixed by the
commitment id. `prover-node status` renders both (`--json` for the raw data).

## Tests (`npm test`, vitest, no network, no proof — and no `scarb` unless it is there)

- `commitment.test.ts` — the Poseidon fold against the contract's own vectors (`inputs_seed`,
  the nine-tic log) and against every `inputs_commitment` the Cairo program emitted for the
  proved `B2-1_doom` fixture, re-packed from the words.
- `commitments.test.ts` — the two announced selectors; a fabricated header and its `RunLog`
  chunks decoded, assembled in any order and verified; missing, shifted, short and duplicated
  chunks; settlements and the `Commitment` view; tampered journal, wrong lengths, wrong id,
  wrong genesis, expiry; discovery with paging, settlement, reclaim and a reorg; the policy.
- `segmenter.test.ts` — the cut on the fixture's real 297-tic game, probe for probe against an
  independent replay of the browser loop; the threaded ceiling, the steps-only path and a
  calibrated ceiling; DEAD, unfinished, ABORT, foreign genesis; every kind of chain break
  detected after the fact; the 7-tic alignment, the concatenation equal to the journal, and a
  ceiling too low for seven tics.
- `prover.test.ts` — the lock (exclusive, timeout, owner-only release, stale reclaim on
  request), the process-group kill, `SubprocessProver` on a stand-in binary (bincode and
  cairo-serde, hang, failure, busy lock), and the resume: the second segment fails once, the
  relaunch never re-proves the first.
- `register.test.ts` — the fold on an in-memory wrapper serving the real fixture batch (upload,
  resume, swapped leaves refused), the D28 sequence on a mocked node and signer with the
  `register_member` calldata checked field by field (the member is the player, the replay is
  published, forced on), the settlement read from the receipt, resume from a checkpoint after a
  lost connection, the already-registered short cut, the pre-flight refusals, and the signer's
  secrecy and mainnet refusal.
- `realExecutor.test.ts` — the real executor (above): genesis, the walk's golden D14 in one call
  and as two 7-aligned segments, the cost at 35 / 70 / 140 tics, the exit route cut and the
  node end to end on `ScarbExecutor`; skipped with a reason when `scarb` or the build is absent.
- `node.test.ts` — the node end to end on fakes: events to settled bounty in one poll, resume
  after an interruption, `--stop-after` handovers across processes, refusals, a hopeless job
  given up after `maxAttempts`, a race lost to another prover, and `watch`.

## What remains to be plugged in

- **Native `resources()`.** `scarb execute` reports steps and builtins, not the AIR component
  sizing the browser's `resources()` uses; `ScarbExecutor` is therefore steps-only (the segment
  record says `rowsChecked: false`) and the cut is bound by the D26 step ceiling alone. A native
  oracle (the WASM `resources()` under Node, or a Rust probe) would make `Executor.segment`
  return a full `ResourceSummary`, which `segmenter.ts` already consumes unchanged.
- **The proving binaries.** `SubprocessProver` writes exactly the leaf-bootloader task of
  `prove_segment.sh` and expects `stwo-run-and-prove` (proving monorepo @ `cd7bc5f`), the leaf
  bootloader and `leaf.json`; none of them exist in this environment, so the class is exercised
  on a stand-in. The wrapper folds `bincode_b64` proofs only (`leaf_mode = "from_proof"`): confirm
  the binary's `--proof-format bincode` output is the bincode `CairoProof` the wrapper verifies,
  or run the wrapper in `rerun` mode from the `args` the node also uploads.
- **Calibration (D35).** The planner defaults are the browser's (2.3 M steps mono, 2^20 rows);
  the node's 64 GB target is 8–13 M steps per segment, to be measured and then set with
  `--max-steps` / `--log-size` — and, with a `resources()` oracle, checked rather than assumed.
- **ABI confirmations.** The id derivation is computed with `poseidon_hash_span` over the five
  felts; the `Commitment` struct is read as 13 felts in declaration order; both are one-line
  edits in `commitments.ts` if the compiled ABI differs. `CommitmentProved` is looked up in the
  consumer's receipt by selector and commitment id.
- **`submit_batch` for several players.** The node registers its own run with `register_member`;
  submitting a whole wrapper batch (D20) needs the other runs' players, which the wrapper's batch
  response does not carry.
- **Sepolia.** Nothing here has been run against a live network: the RPC event source, the
  estimator (`makeEstimator`, the `infra/submit` loop) and `NodeSigner` are the same calls the
  indexer and `submit-batch` make on a devnet, but they are untested outside their mocks.

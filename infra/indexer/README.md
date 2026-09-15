<!--
SPDX-FileCopyrightText: 2026 Hellproof contributors
SPDX-License-Identifier: Apache-2.0
-->

# `doomruns-indexer` — the P4.4 read side of `DoomRuns`

D21 puts the top-10 per `(version, kind)` on chain and everything else — full rankings, player
histories, replay logs — behind "events + indexer". This is that indexer: it follows `DoomRuns`'s
seven event kinds — plus the four of the open prover (D35, P4.7: `RunCommitted`, `RunLog`,
`CommitmentProved`, `CommitmentReclaimed`) — into SQLite and serves a small read API the
leaderboard page (`client/leaderboard.html`, `client/src/leaderboard/`) talks to.

## Quick start

```sh
export ASDF_NODEJS_VERSION=22.22.2   # Node >= 22 (node:sqlite, experimental, ships built in)
cd infra/indexer && npm install

npm start -- --rpc http://127.0.0.1:5081/rpc --address 0x<DoomRuns> --start-block 0 \
  --db .work/indexer.sqlite --port 8788
```

`--once` polls a single time and exits (useful for a script or a one-off backfill); without it the
process polls forever (`--interval-ms`, default 5000) and serves the API alongside the follow
loop. `npm test` runs the unit suite (mocked RPC) plus a devnet integration test that skips itself
without `INDEXER_TEST_RPC`/`INDEXER_TEST_ADDRESS` (see `test/integration.test.ts`).

## API

All responses are JSON, snake_case, matching the wrapper's own convention
(`docs/design/doomruns.md` — `GET /v1/batches/{id}` returns `run_id`, `leaf_index`, …) so the
leaderboard page's two data sources (this API and the RPC fallback) share one shape.

| route | what |
|---|---|
| `GET /leaderboard?version=&kind=&offset=&limit=` | `kind=0` (score, descending) or `kind=1` (tics, ascending — lower is better); `{version_id, kind, offset, limit, total, rows: [{rank, run_id, player, ...the Run fields, block_number, tx_hash}]}` |
| `GET /players/{address}` | `{player, run_count, attempt_count, best_score, best_tics, commitment_count, pending_commitment_count, runs: [...], pending_commitments: [...]}` — `runs` mixes finished runs and `DEAD` attempts, newest block first; `pending_commitments` are the player's games still waiting for a prover (D35), newest first, each a commitment row (below) |
| `GET /runs/{run_id}` | the `Run` (or attempt) row plus `replay: [{leaf_index, tic_start, tic_end, packed}]`, empty when no `Replay` event was published for it; `404` if the id is unknown |
| `GET /players/{address}/commitments?status=pending&offset=&limit=` | `{player, total, pending, offset, limit, commitments: [...]}` — every commitment of the player (`status=pending` keeps the unsettled ones), newest first |
| `GET /commitments/{commitment_id}` | one commitment row: `{commitment_id, player, version_id, level_id, genesis, inputs_commitment, tics, bounty, expires_at, n_chunks, log_chunks, status, run_id, prover, block_number, tx_hash, settled_block, settled_tx}`; `status` is `PENDING`, `PROVED` or `RECLAIMED` (whether a pending one is past `expires_at` is the reader's call against the chain head — the indexer only knows `indexed_block`); `bounty` is the `u256` as a decimal string; `log_chunks` counts the `RunLog` events seen against `n_chunks` |
| `GET /commitments/pending?offset=&limit=` | `{total, pending, offset, limit, commitments: [...]}` — every unsettled commitment, oldest first (what a prover node walks) |
| `GET /stats` | `{indexed_block, total_runs, total_attempts, total_players, total_commitments, pending_commitments, versions: [{version_id, run_count, attempt_count}]}` |

`leaderboard` reads only `runs` (finished, `EXIT`) — attempts never enter a board, matching the
contract. This is deliberately the *full* ranking beyond the on-chain top 10, not a mirror of it:
the on-chain board is the truth for the podium, this API is the truth for "show me rank 500".

## Schema (SQLite, `node:sqlite`)

One table per event kind, each carrying the `block_number` (and, where useful, `tx_hash`) it was
learned from:

- `runs` — one row per `RunSubmitted` (finished run), primary key `run_id`.
- `attempts` — one row per `AttemptRecorded` (`DEAD`, no leaderboard entry, no kills/items/secrets
  in the event itself — D18/D21).
- `replays` — one row per `Replay` event, `(run_id, leaf_index)` primary key, `packed` as a JSON
  array of hex felts (the packed input log, D13/R10-A3).
- `member_rejections` — one row per `MemberRejected`, append-only (there is no natural key: the
  same `(member_index, player)` can legitimately reject twice across different batches).
- `versions`, `genesis` — mirror `VersionAdded`/`GenesisSet`, mostly for `/stats` and for a future
  "which season is this" display.
- `frozen_events` — mirrors `Frozen`, append-only (there is exactly one in practice, since
  `freeze()` is one-way, but the table does not assume that).
- `commitments` — one row per `RunCommitted` (D35), primary key `commitment_id`. A `RECLAIMED` id
  committed again replaces its row (new bounty, new expiry) and drops the older settlement.
- `commitment_settlements` — one row per `CommitmentProved` / `CommitmentReclaimed`, kept
  **apart** from the commitment so that purging a reorg window reverts a settled commitment to
  `PENDING` instead of deleting it (the `status` column of the API is derived by a `LEFT JOIN`).
- `commitment_logs` — one row per `RunLog` chunk: `(commitment_id, chunk)`, its `offset` and
  `packed_len`. The felts themselves are **not** stored (~900 per game; rebuilding a log from
  the events is the prover node's job, not the leaderboard's) — only counted.
- `cursor` — one row (`id = 1`), `last_block`: where the next poll resumes from.

Player stats (`best_score`, `run_count`, …) are **not** materialized — they are `MIN`/`MAX`/`COUNT`
queries over `runs`/`attempts` at read time. That trades a little read latency (fine at this
scale — a few thousand rows) for not having to invalidate a materialized aggregate every time
`purgeFromBlock` rewrites a range of blocks.

## Reorg handling

Every poll (`indexer.ts::pollOnce`) treats the last `reorgDepth` blocks (default 10) as not yet
final:

```
fromBlock = max(startBlock, cursor.lastBlock - reorgDepth + 1)
purgeFromBlock(fromBlock)          -- delete every row learned from block >= fromBlock
getEvents([fromBlock, head])       -- paged via continuation_token
apply each decoded event
cursor.lastBlock = head
```

A chain that never reorgs re-derives the same rows in that window every poll (idempotent, cheap at
`reorgDepth` ~10-20 blocks — devnet's instant finality makes this mostly theatre there, but the
same code path is what a public network needs). A chain that reorged within the window ends up
with exactly the new canonical events, because nothing from the old fork survives the purge — no
block-hash bookkeeping needed, at the cost of only detecting a reorg up to `reorgDepth` blocks
deep. That is the standard trade-off for this class of indexer; a deeper reorg would need
comparing stored block hashes against the chain's, which is `EventSource`'s natural extension
point if it is ever needed (`test/indexer.test.ts` exercises this precisely: a run replaced within
the rescanned window disappears and the new one appears; a run below the window survives).

Resumability is the same mechanism read backwards: on restart, `cursor.lastBlock` (persisted in
the `cursor` table) picks up where the process left off, re-scanning only the last `reorgDepth`
blocks instead of the whole chain.

## Tests

`npm test` (vitest):

- `test/decode.test.ts` — every event kind decoded from raw `keys`/`data`, the `MemberRejected`
  short-string `reason`, the four D35 events at their exact selectors (`RunLog` counted, never
  stored; the `u256` bounty exact), and (when `cairo/doom_contracts` has been built) a
  cross-check that every selector this package computes matches a name in the compiled ABI.
- `test/commitments.test.ts` — the commitments through the real decode + apply path: a player's
  pending games and their log-chunk count, settlement by a third-party prover and reclaim, a
  reorg that un-proves a commitment (back to `PENDING`, not gone), a `RECLAIMED` id committed
  again, and the four routes.
- `test/indexer.test.ts` — `pollOnce` against a fixed, in-memory `EventSource` (no network): paging
  via `continuation_token`, the cursor advancing past a start block, idempotent re-polling, **the
  reorg**: a run replaced within the rescanned window disappears and the new one takes its place,
  while a run below the window is untouched; `follow`'s poll/sleep/abort loop.
- `test/api.test.ts` — every route against an in-memory DB seeded through the real decode+apply
  path (not hand-built rows), including ordering, pagination, 404s and `/stats`.
- `test/integration.test.ts` — the same `pollOnce` against a **real** devnet with `DoomRuns`
  deployed and at least one batch submitted; skips itself (not a failure) without
  `INDEXER_TEST_RPC`/`INDEXER_TEST_ADDRESS`, so a clone with no devnet running still has a green
  `npm test` (same convention as `infra/submit/test`).

## If the contract adopts Dojo models: replacing this with Torii

This package exists because `DoomRuns` is a hand-written Cairo contract, not a set of Dojo
models — there is nothing for [Torii](https://book.dojoengine.org/toolchain/torii) to index. If a
future season moves the run/leaderboard bookkeeping onto Dojo models (a `Run` model, a `BoardRow`
model, …), Torii would index them automatically from the world's model-update events with no
custom decoder, and could replace most of this package:

- **Events → models.** `RunSubmitted`/`AttemptRecorded`/`Replay`/etc. would become Dojo model
  writes (`world.write_model`); Torii's GraphQL and gRPC APIs would then answer `leaderboard`,
  `players/{address}` and `runs/{id}`-shaped queries without `decode.ts`/`db.ts` existing at all —
  Torii's own SQLite database (or Postgres) replaces `IndexerDb`.
- **What would not carry over as-is.** The `Replay` event's packed input log is a `Span<felt252>`
  blob with no natural "queryable field" shape; it would most likely stay a plain byte/felt array
  model field, fetched whole via Torii's `entities` query rather than filtered server-side (this
  package's `GET /runs/{id}` does the same today). The board's insertion-order bookkeeping
  (`board`, `board_len`) is intentionally on-chain storage for the top 10 (D21) and would not move
  to a model either way — only the "rank 11 and below" side is this package's (or Torii's) job.
  Ranking by score/tics ordering is Torii's `order_by` on a model query, not different in kind from
  this API's `ORDER BY`.
- **What would need a small adapter regardless.** `client/src/leaderboard/api.ts` talks to this
  package's snake_case JSON today; pointing it at Torii instead means writing one adapter module
  translating Torii's GraphQL/gRPC response shape into the same `BoardRow`/`RunDetail`/`PlayerStats`
  types the page already renders — the render/replay-download code in `client/src/leaderboard/`
  would not change, only the fetch layer.

This is a documentation note, not a plan to implement: `DoomRuns` is not a Dojo contract today, and
introducing Dojo models purely to run Torii would be a rewrite of P4.2, not a P4.4 task.

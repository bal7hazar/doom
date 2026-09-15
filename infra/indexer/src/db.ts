// SPDX-License-Identifier: Apache-2.0
/**
 * SQLite storage (`node:sqlite`, no native dependency — Node >= 22.5). One table per event kind
 * plus a `cursor` row for resumability. `purgeFromBlock` is the whole reorg story: every table
 * carries the `block_number` it was learned from, so re-scanning `[fromBlock, head]` after a
 * possible reorg is just "delete anything from those blocks, then replay the events the RPC
 * returns for that range now" (`indexer.ts`).
 */
import type { DatabaseSync as DatabaseSyncType } from "node:sqlite";

import type {
  AttemptRecordedEvent,
  CommitmentProvedEvent,
  CommitmentReclaimedEvent,
  DoomRunsEvent,
  FrozenEvent,
  GenesisSetEvent,
  MemberRejectedEvent,
  ReplayEvent,
  RunCommittedEvent,
  RunLogEvent,
  RunSubmittedEvent,
  VersionAddedEvent,
} from "./types.js";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS cursor (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  last_block INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS runs (
  run_id TEXT PRIMARY KEY,
  player TEXT NOT NULL,
  version_id INTEGER NOT NULL,
  level_id INTEGER NOT NULL,
  tics INTEGER NOT NULL,
  kills INTEGER NOT NULL,
  items INTEGER NOT NULL,
  secrets INTEGER NOT NULL,
  score INTEGER NOT NULL,
  n_segments INTEGER NOT NULL,
  fact TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_runs_board_score ON runs(version_id, score DESC);
CREATE INDEX IF NOT EXISTS idx_runs_board_time ON runs(version_id, tics ASC);
CREATE INDEX IF NOT EXISTS idx_runs_player ON runs(player);
CREATE INDEX IF NOT EXISTS idx_runs_block ON runs(block_number);

CREATE TABLE IF NOT EXISTS attempts (
  run_id TEXT PRIMARY KEY,
  player TEXT NOT NULL,
  version_id INTEGER NOT NULL,
  level_id INTEGER NOT NULL,
  tics INTEGER NOT NULL,
  score INTEGER NOT NULL,
  fact TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_attempts_player ON attempts(player);
CREATE INDEX IF NOT EXISTS idx_attempts_block ON attempts(block_number);

CREATE TABLE IF NOT EXISTS replays (
  run_id TEXT NOT NULL,
  leaf_index INTEGER NOT NULL,
  tic_start INTEGER NOT NULL,
  tic_end INTEGER NOT NULL,
  packed TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  PRIMARY KEY (run_id, leaf_index)
);
CREATE INDEX IF NOT EXISTS idx_replays_block ON replays(block_number);

CREATE TABLE IF NOT EXISTS member_rejections (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL,
  member_index INTEGER NOT NULL,
  player TEXT NOT NULL,
  reason TEXT NOT NULL,
  reason_text TEXT NOT NULL,
  leaf_start INTEGER NOT NULL,
  leaf_len INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rejections_block ON member_rejections(block_number);

CREATE TABLE IF NOT EXISTS versions (
  version_id INTEGER PRIMARY KEY,
  program_hash TEXT NOT NULL,
  registry_name TEXT NOT NULL,
  verifier_router TEXT NOT NULL,
  block_number INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS genesis (
  version_id INTEGER NOT NULL,
  level_id INTEGER NOT NULL,
  genesis TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  PRIMARY KEY (version_id, level_id)
);

CREATE TABLE IF NOT EXISTS frozen_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  by TEXT NOT NULL,
  block_number INTEGER NOT NULL
);

-- D35: one row per RunCommitted. A RECLAIMED id may be committed again (new escrow, new
-- expiry): the row is then replaced, and its settlement row purged with it (see insertCommitment).
CREATE TABLE IF NOT EXISTS commitments (
  commitment_id TEXT PRIMARY KEY,
  player TEXT NOT NULL,
  version_id INTEGER NOT NULL,
  level_id INTEGER NOT NULL,
  genesis TEXT NOT NULL,
  inputs_commitment TEXT NOT NULL,
  tics INTEGER NOT NULL,
  bounty TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  n_chunks INTEGER NOT NULL,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_commitments_player ON commitments(player);
CREATE INDEX IF NOT EXISTS idx_commitments_block ON commitments(block_number);

-- The settlement of a commitment lives apart from its creation so that purging the blocks of
-- a reorg window reverts a PROVED / RECLAIMED row to PENDING instead of deleting it.
CREATE TABLE IF NOT EXISTS commitment_settlements (
  commitment_id TEXT PRIMARY KEY,
  status TEXT NOT NULL CHECK (status IN ('PROVED', 'RECLAIMED')),
  run_id TEXT,
  prover TEXT,
  bounty TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_settlements_block ON commitment_settlements(block_number);

-- RunLog chunks are counted, never stored (the felts are the prover node's business).
CREATE TABLE IF NOT EXISTS commitment_logs (
  commitment_id TEXT NOT NULL,
  chunk INTEGER NOT NULL,
  offset INTEGER NOT NULL,
  packed_len INTEGER NOT NULL,
  block_number INTEGER NOT NULL,
  PRIMARY KEY (commitment_id, chunk)
);
CREATE INDEX IF NOT EXISTS idx_commitment_logs_block ON commitment_logs(block_number);
`;

// `node:sqlite` is experimental and not (yet) in Node's `builtinModules` list, which trips up
// bundlers (Vite/vitest) that special-case `node:`-prefixed imports by checking that list — a
// static `import "node:sqlite"` gets its prefix stripped and is then resolved as the *npm*
// package `sqlite`, which does not exist here. `process.getBuiltinModule` is a plain function
// call a bundler has no reason to touch, so it sidesteps the whole problem.
const { DatabaseSync } = process.getBuiltinModule("node:sqlite") as { DatabaseSync: typeof DatabaseSyncType };

export class IndexerDb {
  readonly raw: DatabaseSyncType;

  constructor(path: string) {
    this.raw = new DatabaseSync(path);
    this.raw.exec("PRAGMA journal_mode = WAL;");
    this.raw.exec(SCHEMA);
  }

  close(): void {
    this.raw.close();
  }

  // --- cursor --------------------------------------------------------------

  getCursor(): { lastBlock: number } | undefined {
    const row = this.raw.prepare("SELECT last_block FROM cursor WHERE id = 1").get() as
      | { last_block: number }
      | undefined;
    return row ? { lastBlock: row.last_block } : undefined;
  }

  setCursor(lastBlock: number): void {
    this.raw
      .prepare(
        `INSERT INTO cursor (id, last_block, updated_at) VALUES (1, ?, ?)
         ON CONFLICT(id) DO UPDATE SET last_block = excluded.last_block, updated_at = excluded.updated_at`,
      )
      .run(lastBlock, Date.now());
  }

  // --- reorg: forget everything learned from block >= fromBlock ------------

  purgeFromBlock(fromBlock: number): void {
    for (const table of [
      "runs", "attempts", "replays", "member_rejections", "versions", "genesis", "frozen_events",
      "commitments", "commitment_settlements", "commitment_logs",
    ]) {
      this.raw.prepare(`DELETE FROM ${table} WHERE block_number >= ?`).run(fromBlock);
    }
  }

  // --- writers ---------------------------------------------------------------

  insertRun(e: RunSubmittedEvent): void {
    this.raw
      .prepare(
        `INSERT INTO runs (run_id, player, version_id, level_id, tics, kills, items, secrets, score, n_segments, fact, block_number, tx_hash)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(run_id) DO UPDATE SET
           player=excluded.player, version_id=excluded.version_id, level_id=excluded.level_id,
           tics=excluded.tics, kills=excluded.kills, items=excluded.items, secrets=excluded.secrets,
           score=excluded.score, n_segments=excluded.n_segments, fact=excluded.fact,
           block_number=excluded.block_number, tx_hash=excluded.tx_hash`,
      )
      .run(
        e.runId,
        e.player,
        e.versionId,
        e.levelId,
        e.tics,
        e.kills,
        e.items,
        e.secrets,
        e.score,
        e.nSegments,
        e.fact,
        e.blockNumber,
        e.txHash,
      );
  }

  insertAttempt(e: AttemptRecordedEvent): void {
    this.raw
      .prepare(
        `INSERT INTO attempts (run_id, player, version_id, level_id, tics, score, fact, block_number, tx_hash)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(run_id) DO UPDATE SET
           player=excluded.player, version_id=excluded.version_id, level_id=excluded.level_id,
           tics=excluded.tics, score=excluded.score, fact=excluded.fact,
           block_number=excluded.block_number, tx_hash=excluded.tx_hash`,
      )
      .run(e.runId, e.player, e.versionId, e.levelId, e.tics, e.score, e.fact, e.blockNumber, e.txHash);
  }

  insertReplay(e: ReplayEvent): void {
    this.raw
      .prepare(
        `INSERT INTO replays (run_id, leaf_index, tic_start, tic_end, packed, block_number)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(run_id, leaf_index) DO UPDATE SET
           tic_start=excluded.tic_start, tic_end=excluded.tic_end, packed=excluded.packed,
           block_number=excluded.block_number`,
      )
      .run(e.runId, e.leafIndex, e.ticStart, e.ticEnd, JSON.stringify(e.packed), e.blockNumber);
  }

  insertRejection(e: MemberRejectedEvent): void {
    this.raw
      .prepare(
        `INSERT INTO member_rejections (block_number, tx_hash, member_index, player, reason, reason_text, leaf_start, leaf_len)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(e.blockNumber, e.txHash, e.memberIndex, e.player, e.reason, e.reasonText, e.leafStart, e.leafLen);
  }

  upsertVersion(e: VersionAddedEvent): void {
    this.raw
      .prepare(
        `INSERT INTO versions (version_id, program_hash, registry_name, verifier_router, block_number)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(version_id) DO UPDATE SET
           program_hash=excluded.program_hash, registry_name=excluded.registry_name,
           verifier_router=excluded.verifier_router, block_number=excluded.block_number`,
      )
      .run(e.versionId, e.programHash, e.registryNameText, e.verifierRouter, e.blockNumber);
  }

  upsertGenesis(e: GenesisSetEvent): void {
    this.raw
      .prepare(
        `INSERT INTO genesis (version_id, level_id, genesis, block_number) VALUES (?, ?, ?, ?)
         ON CONFLICT(version_id, level_id) DO UPDATE SET genesis=excluded.genesis, block_number=excluded.block_number`,
      )
      .run(e.versionId, e.levelId, e.genesis, e.blockNumber);
  }

  insertFrozen(e: FrozenEvent): void {
    this.raw.prepare(`INSERT INTO frozen_events (by, block_number) VALUES (?, ?)`).run(e.by, e.blockNumber);
  }

  // --- D35: commitments ------------------------------------------------------

  insertCommitment(e: RunCommittedEvent): void {
    // A re-commit of a RECLAIMED id starts a new life: the old settlement and log chunks go.
    this.raw.prepare(`DELETE FROM commitment_settlements WHERE commitment_id = ? AND block_number < ?`).run(e.commitmentId, e.blockNumber);
    this.raw.prepare(`DELETE FROM commitment_logs WHERE commitment_id = ? AND block_number < ?`).run(e.commitmentId, e.blockNumber);
    this.raw
      .prepare(
        `INSERT INTO commitments (commitment_id, player, version_id, level_id, genesis, inputs_commitment, tics, bounty, expires_at, n_chunks, block_number, tx_hash)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(commitment_id) DO UPDATE SET
           player=excluded.player, version_id=excluded.version_id, level_id=excluded.level_id,
           genesis=excluded.genesis, inputs_commitment=excluded.inputs_commitment, tics=excluded.tics,
           bounty=excluded.bounty, expires_at=excluded.expires_at, n_chunks=excluded.n_chunks,
           block_number=excluded.block_number, tx_hash=excluded.tx_hash`,
      )
      .run(e.commitmentId, e.player, e.versionId, e.levelId, e.genesis, e.inputsCommitment, e.tics, e.bounty, e.expiresAt, e.nChunks, e.blockNumber, e.txHash);
  }

  insertCommitmentLog(e: RunLogEvent): void {
    this.raw
      .prepare(
        `INSERT INTO commitment_logs (commitment_id, chunk, offset, packed_len, block_number) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(commitment_id, chunk) DO UPDATE SET offset=excluded.offset, packed_len=excluded.packed_len, block_number=excluded.block_number`,
      )
      .run(e.commitmentId, e.chunk, e.offset, e.packedLen, e.blockNumber);
  }

  insertCommitmentProved(e: CommitmentProvedEvent): void {
    this.raw
      .prepare(
        `INSERT INTO commitment_settlements (commitment_id, status, run_id, prover, bounty, block_number, tx_hash)
         VALUES (?, 'PROVED', ?, ?, ?, ?, ?)
         ON CONFLICT(commitment_id) DO UPDATE SET status='PROVED', run_id=excluded.run_id, prover=excluded.prover,
           bounty=excluded.bounty, block_number=excluded.block_number, tx_hash=excluded.tx_hash`,
      )
      .run(e.commitmentId, e.runId, e.prover, e.bounty, e.blockNumber, e.txHash);
  }

  insertCommitmentReclaimed(e: CommitmentReclaimedEvent): void {
    this.raw
      .prepare(
        `INSERT INTO commitment_settlements (commitment_id, status, run_id, prover, bounty, block_number, tx_hash)
         VALUES (?, 'RECLAIMED', NULL, NULL, ?, ?, ?)
         ON CONFLICT(commitment_id) DO UPDATE SET status='RECLAIMED', run_id=NULL, prover=NULL,
           bounty=excluded.bounty, block_number=excluded.block_number, tx_hash=excluded.tx_hash`,
      )
      .run(e.commitmentId, e.bounty, e.blockNumber, e.txHash);
  }

  /** Dispatches one decoded event to its table. */
  apply(e: DoomRunsEvent): void {
    switch (e.kind) {
      case "RunSubmitted":
        return this.insertRun(e);
      case "AttemptRecorded":
        return this.insertAttempt(e);
      case "Replay":
        return this.insertReplay(e);
      case "MemberRejected":
        return this.insertRejection(e);
      case "VersionAdded":
        return this.upsertVersion(e);
      case "GenesisSet":
        return this.upsertGenesis(e);
      case "Frozen":
        return this.insertFrozen(e);
      case "RunCommitted":
        return this.insertCommitment(e);
      case "RunLog":
        return this.insertCommitmentLog(e);
      case "CommitmentProved":
        return this.insertCommitmentProved(e);
      case "CommitmentReclaimed":
        return this.insertCommitmentReclaimed(e);
    }
  }

  // --- readers used by the API (api.ts) -------------------------------------

  leaderboard(versionId: number, kind: 0 | 1, offset: number, limit: number): unknown[] {
    const order = kind === 0 ? "score DESC" : "tics ASC";
    return this.raw
      .prepare(
        `SELECT run_id, player, version_id, level_id, tics, kills, items, secrets, score, n_segments, fact, block_number, tx_hash
         FROM runs WHERE version_id = ? ORDER BY ${order}, run_id ASC LIMIT ? OFFSET ?`,
      )
      .all(versionId, limit, offset);
  }

  leaderboardLen(versionId: number): number {
    const row = this.raw.prepare(`SELECT COUNT(*) AS n FROM runs WHERE version_id = ?`).get(versionId) as {
      n: number;
    };
    return row.n;
  }

  run(runId: string): Record<string, unknown> | undefined {
    return this.raw
      .prepare(
        `SELECT run_id, player, version_id, level_id, tics, kills, items, secrets, score, n_segments, fact, block_number, tx_hash, 'EXIT' AS status
         FROM runs WHERE run_id = ?`,
      )
      .get(runId) as Record<string, unknown> | undefined;
  }

  attempt(runId: string): Record<string, unknown> | undefined {
    return this.raw
      .prepare(
        `SELECT run_id, player, version_id, level_id, tics, score, fact, block_number, tx_hash, 'DEAD' AS status
         FROM attempts WHERE run_id = ?`,
      )
      .get(runId) as Record<string, unknown> | undefined;
  }

  replaysOf(runId: string): { leaf_index: number; tic_start: number; tic_end: number; packed: string }[] {
    return this.raw
      .prepare(`SELECT leaf_index, tic_start, tic_end, packed FROM replays WHERE run_id = ? ORDER BY leaf_index ASC`)
      .all(runId) as { leaf_index: number; tic_start: number; tic_end: number; packed: string }[];
  }

  playerRuns(player: string, offset: number, limit: number): unknown[] {
    return this.raw
      .prepare(
        `SELECT run_id, version_id, level_id, tics, kills, items, secrets, score, n_segments, block_number, tx_hash, 'EXIT' AS status
         FROM runs WHERE player = ?
         UNION ALL
         SELECT run_id, version_id, level_id, tics, NULL, NULL, NULL, score, NULL, block_number, tx_hash, 'DEAD' AS status
         FROM attempts WHERE player = ?
         ORDER BY block_number DESC LIMIT ? OFFSET ?`,
      )
      .all(player, player, limit, offset);
  }

  playerStats(player: string): { run_count: number; attempt_count: number; best_score: number | null; best_tics: number | null } {
    const runCount = this.raw.prepare(`SELECT COUNT(*) AS n FROM runs WHERE player = ?`).get(player) as { n: number };
    const attemptCount = this.raw.prepare(`SELECT COUNT(*) AS n FROM attempts WHERE player = ?`).get(player) as {
      n: number;
    };
    const best = this.raw
      .prepare(`SELECT MAX(score) AS best_score, MIN(tics) AS best_tics FROM runs WHERE player = ?`)
      .get(player) as { best_score: number | null; best_tics: number | null };
    return {
      run_count: runCount.n,
      attempt_count: attemptCount.n,
      best_score: best.best_score,
      best_tics: best.best_tics,
    };
  }

  // --- D35: commitment readers ------------------------------------------------

  /**
   * A commitment row with its derived status: `PENDING` (no settlement yet), `PROVED` or
   * `RECLAIMED`; `expires_at` is reported and the *caller* decides whether a pending one is past
   * it (the indexer knows the last block it scanned, `stats().indexed_block`, not the chain's
   * head at read time). `log_chunks` counts the `RunLog` events seen against `n_chunks`.
   */
  private static readonly COMMITMENT_SELECT = `
    SELECT c.commitment_id, c.player, c.version_id, c.level_id, c.genesis, c.inputs_commitment, c.tics,
           c.bounty, c.expires_at, c.n_chunks, c.block_number, c.tx_hash,
           COALESCE(s.status, 'PENDING') AS status, s.run_id, s.prover,
           s.block_number AS settled_block, s.tx_hash AS settled_tx,
           (SELECT COUNT(*) FROM commitment_logs l WHERE l.commitment_id = c.commitment_id AND l.block_number >= c.block_number) AS log_chunks
    FROM commitments c
    LEFT JOIN commitment_settlements s ON s.commitment_id = c.commitment_id AND s.block_number >= c.block_number`;

  commitment(commitmentId: string): Record<string, unknown> | undefined {
    return this.raw
      .prepare(`${IndexerDb.COMMITMENT_SELECT} WHERE c.commitment_id = ?`)
      .get(commitmentId) as Record<string, unknown> | undefined;
  }

  /** A player's commitments, newest first; `pendingOnly` keeps the unsettled ones. */
  playerCommitments(player: string, offset: number, limit: number, pendingOnly = false): unknown[] {
    const filter = pendingOnly ? "AND s.commitment_id IS NULL" : "";
    return this.raw
      .prepare(`${IndexerDb.COMMITMENT_SELECT} WHERE c.player = ? ${filter} ORDER BY c.block_number DESC, c.commitment_id ASC LIMIT ? OFFSET ?`)
      .all(player, limit, offset);
  }

  /** Every unsettled commitment, oldest first — what a prover node would walk. */
  pendingCommitments(offset: number, limit: number): unknown[] {
    return this.raw
      .prepare(`${IndexerDb.COMMITMENT_SELECT} WHERE s.commitment_id IS NULL ORDER BY c.block_number ASC, c.commitment_id ASC LIMIT ? OFFSET ?`)
      .all(limit, offset);
  }

  commitmentCounts(player?: string): { total: number; pending: number } {
    const where = player === undefined ? "" : "WHERE c.player = ?";
    const args = player === undefined ? [] : [player];
    const total = this.raw.prepare(`SELECT COUNT(*) AS n FROM commitments c ${where}`).get(...args) as { n: number };
    const pending = this.raw
      .prepare(
        `SELECT COUNT(*) AS n FROM commitments c
         LEFT JOIN commitment_settlements s ON s.commitment_id = c.commitment_id AND s.block_number >= c.block_number
         ${where ? where + " AND" : "WHERE"} s.commitment_id IS NULL`,
      )
      .get(...args) as { n: number };
    return { total: total.n, pending: pending.n };
  }

  stats(): {
    indexed_block: number | null;
    total_runs: number;
    total_attempts: number;
    total_players: number;
    total_commitments: number;
    pending_commitments: number;
    versions: { version_id: number; run_count: number; attempt_count: number }[];
  } {
    const cursor = this.getCursor();
    const totalRuns = this.raw.prepare(`SELECT COUNT(*) AS n FROM runs`).get() as { n: number };
    const totalAttempts = this.raw.prepare(`SELECT COUNT(*) AS n FROM attempts`).get() as { n: number };
    const totalPlayers = this.raw
      .prepare(`SELECT COUNT(DISTINCT player) AS n FROM (SELECT player FROM runs UNION SELECT player FROM attempts)`)
      .get() as { n: number };
    const versions = this.raw
      .prepare(
        `SELECT v.version_id AS version_id,
                (SELECT COUNT(*) FROM runs r WHERE r.version_id = v.version_id) AS run_count,
                (SELECT COUNT(*) FROM attempts a WHERE a.version_id = v.version_id) AS attempt_count
         FROM versions v ORDER BY v.version_id ASC`,
      )
      .all() as { version_id: number; run_count: number; attempt_count: number }[];
    const commitments = this.commitmentCounts();
    return {
      indexed_block: cursor?.lastBlock ?? null,
      total_runs: totalRuns.n,
      total_attempts: totalAttempts.n,
      total_players: totalPlayers.n,
      total_commitments: commitments.total,
      pending_commitments: commitments.pending,
      versions,
    };
  }
}

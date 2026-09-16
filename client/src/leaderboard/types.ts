// SPDX-License-Identifier: Apache-2.0
/**
 * Shapes the leaderboard page renders, independent of where they came from — the indexer's read
 * API (`infra/indexer`, P4.4) when configured, or `DoomRuns`'s own views over RPC otherwise
 * (`docs/design/doomruns.md` §2, `?rpc=` in the page URL). Both `IndexerSource` and `RpcSource`
 * (`source.ts`) implement {@link LeaderboardSource}; `render.ts` and `app.ts` never know which one
 * is behind it.
 */

/** `KIND_SCORE = 0` (higher first), `KIND_TIME = 1` (lower tics first) — `doom_runs.cairo`. */
export type BoardKind = 0 | 1;

export interface BoardRow {
  rank: number;
  runId: string;
  player: string;
  /** `score` for kind 0, `tics` for kind 1 — whatever the board is ordered by. */
  value: number;
}

export interface BoardPage {
  versionId: number;
  kind: BoardKind;
  offset: number;
  limit: number;
  total: number;
  rows: BoardRow[];
}

export interface ReplayLeaf {
  leafIndex: number;
  ticStart: number;
  ticEnd: number;
  /** The packed input log felts (7 tics/felt, `ticcmd::Packer`), as `0x…` hex. */
  packed: string[];
}

export interface RunDetail {
  runId: string;
  player: string;
  versionId: number;
  levelId: number;
  tics: number;
  /** `null` for a `DEAD` attempt — `AttemptRecorded` does not carry these (D18). */
  kills: number | null;
  items: number | null;
  secrets: number | null;
  score: number;
  status: "EXIT" | "DEAD";
  nSegments: number | null;
  fact: string;
  /** Only the indexer knows these; the RPC fallback leaves them undefined. */
  blockNumber?: number;
  txHash?: string;
  /** Only the indexer publishes replay logs; empty (never partial) over the RPC fallback. */
  replay: ReplayLeaf[];
}

export interface PlayerRunSummary {
  runId: string;
  versionId: number;
  levelId: number;
  tics: number;
  score: number;
  status: "EXIT" | "DEAD";
  blockNumber?: number;
}

/** A game committed to the open prover (D35) and not settled yet — shown under the recorded runs. */
export interface PlayerCommitment {
  commitmentId: string;
  versionId: number;
  levelId: number;
  tics: number;
  /** In the fee token's smallest unit, as a decimal string (a `u256`). */
  bounty: string;
  /** Block from which the player may `reclaim`; whether it is past is `expired` below. */
  expiresAt: number;
  /** `PENDING` still within its expiry, or `EXPIRED` (pending past `expiresAt`, reclaimable). */
  status: "PENDING" | "EXPIRED";
  /** `RunLog` chunks seen / announced; only the indexer knows. */
  logChunks?: number;
  nChunks?: number;
  blockNumber?: number;
  txHash?: string;
}

export interface PlayerStats {
  player: string;
  runCount: number;
  attemptCount?: number;
  bestScore: number | null;
  bestTics: number | null;
  runs: PlayerRunSummary[];
  /** D35 / P4.7: the player's games still waiting for a prover, newest first. */
  pendingCommitments?: PlayerCommitment[];
}

export interface ChainStats {
  indexedBlock: number | null;
  totalRuns: number;
  totalAttempts: number;
  totalPlayers: number;
  versions: { versionId: number; runCount: number; attemptCount: number }[];
}

/** What the page needs from wherever the data comes from. */
export interface LeaderboardSource {
  readonly kind: "indexer" | "rpc";
  leaderboard(versionId: number, boardKind: BoardKind, offset: number, limit: number): Promise<BoardPage>;
  run(runId: string): Promise<RunDetail | undefined>;
  player(address: string, offset: number, limit: number): Promise<PlayerStats>;
  stats(): Promise<ChainStats | undefined>;
}

/** Network identity, for the "view on Voyager" link (`links.ts`). */
export type NetworkKind = "mainnet" | "sepolia" | "devnet";

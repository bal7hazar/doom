// SPDX-License-Identifier: Apache-2.0
/**
 * Two {@link LeaderboardSource} implementations: `IndexerSource` reads `infra/indexer`'s read API
 * (P4.4), `RpcSource` reads `DoomRuns`'s own views directly over JSON-RPC so the page keeps
 * working with nothing but an RPC URL (no indexer deployed). `app.ts` picks one from the page's
 * query string; `render.ts` never knows which.
 */
import { RpcClient } from "../chain/rpc.js";
import { decodeBoardRows, decodeFeltArray, decodeRun, decodeU32, leaderboardCalldata, toHex } from "./rpcCodec.js";
import type {
  BoardKind,
  BoardPage,
  ChainStats,
  LeaderboardSource,
  PlayerRunSummary,
  PlayerStats,
  RunDetail,
} from "./types.js";

// --- indexer -----------------------------------------------------------------

export class IndexerSource implements LeaderboardSource {
  readonly kind = "indexer" as const;

  constructor(
    private readonly baseUrl: string,
    // A bare `fetch` reference loses its `this` binding to `window`/`self`, which the spec
    // requires ("Illegal invocation" otherwise) — bind it once here rather than at every call site.
    private readonly doFetch: typeof fetch = fetch.bind(globalThis),
  ) {}

  private async getJson<T>(path: string): Promise<T> {
    const res = await this.doFetch(`${this.baseUrl.replace(/\/$/, "")}${path}`);
    if (!res.ok) throw new Error(`indexer ${path}: HTTP ${res.status}`);
    return (await res.json()) as T;
  }

  async leaderboard(versionId: number, kind: BoardKind, offset: number, limit: number): Promise<BoardPage> {
    const body = await this.getJson<{
      version_id: number;
      kind: number;
      offset: number;
      limit: number;
      total: number;
      rows: { rank: number; run_id: string; player: string; score?: number; tics?: number }[];
    }>(`/leaderboard?version=${versionId}&kind=${kind}&offset=${offset}&limit=${limit}`);
    return {
      versionId: body.version_id,
      kind: (body.kind === 1 ? 1 : 0) as BoardKind,
      offset: body.offset,
      limit: body.limit,
      total: body.total,
      rows: body.rows.map((r) => ({
        rank: r.rank,
        runId: r.run_id,
        player: r.player,
        value: kind === 0 ? (r.score ?? 0) : (r.tics ?? 0),
      })),
    };
  }

  async run(runId: string): Promise<RunDetail | undefined> {
    try {
      const r = await this.getJson<Record<string, unknown>>(`/runs/${runId}`);
      return {
        runId: String(r["run_id"]),
        player: String(r["player"]),
        versionId: Number(r["version_id"]),
        levelId: Number(r["level_id"]),
        tics: Number(r["tics"]),
        kills: r["kills"] === undefined || r["kills"] === null ? null : Number(r["kills"]),
        items: r["items"] === undefined || r["items"] === null ? null : Number(r["items"]),
        secrets: r["secrets"] === undefined || r["secrets"] === null ? null : Number(r["secrets"]),
        score: Number(r["score"]),
        status: r["status"] === "DEAD" ? "DEAD" : "EXIT",
        nSegments: r["n_segments"] === undefined || r["n_segments"] === null ? null : Number(r["n_segments"]),
        fact: String(r["fact"]),
        blockNumber: Number(r["block_number"]),
        txHash: String(r["tx_hash"]),
        replay: (r["replay"] as { leaf_index: number; tic_start: number; tic_end: number; packed: string[] }[]).map(
          (l) => ({ leafIndex: l.leaf_index, ticStart: l.tic_start, ticEnd: l.tic_end, packed: l.packed }),
        ),
      };
    } catch {
      return undefined;
    }
  }

  async player(address: string, offset: number, limit: number): Promise<PlayerStats> {
    const body = await this.getJson<{
      player: string;
      run_count: number;
      attempt_count: number;
      best_score: number | null;
      best_tics: number | null;
      runs: {
        run_id: string;
        version_id: number;
        level_id: number;
        tics: number;
        score: number;
        status: string;
        block_number: number;
      }[];
    }>(`/players/${address}?offset=${offset}&limit=${limit}`);
    return {
      player: body.player,
      runCount: body.run_count,
      attemptCount: body.attempt_count,
      bestScore: body.best_score,
      bestTics: body.best_tics,
      runs: body.runs.map(
        (r): PlayerRunSummary => ({
          runId: r.run_id,
          versionId: r.version_id,
          levelId: r.level_id,
          tics: r.tics,
          score: r.score,
          status: r.status === "DEAD" ? "DEAD" : "EXIT",
          blockNumber: r.block_number,
        }),
      ),
    };
  }

  async stats(): Promise<ChainStats | undefined> {
    try {
      const body = await this.getJson<{
        indexed_block: number | null;
        total_runs: number;
        total_attempts: number;
        total_players: number;
        versions: { version_id: number; run_count: number; attempt_count: number }[];
      }>(`/stats`);
      return {
        indexedBlock: body.indexed_block,
        totalRuns: body.total_runs,
        totalAttempts: body.total_attempts,
        totalPlayers: body.total_players,
        versions: body.versions.map((v) => ({
          versionId: v.version_id,
          runCount: v.run_count,
          attemptCount: v.attempt_count,
        })),
      };
    } catch {
      return undefined;
    }
  }
}

// --- RPC fallback: DoomRuns' own views -----------------------------------------

const ZERO = "0x0";

export class RpcSource implements LeaderboardSource {
  readonly kind = "rpc" as const;
  private readonly rpc: RpcClient;

  constructor(
    rpcUrl: string,
    private readonly doomRuns: string,
  ) {
    this.rpc = new RpcClient(rpcUrl);
  }

  async leaderboard(versionId: number, kind: BoardKind, offset: number, limit: number): Promise<BoardPage> {
    const [rowsOut, lenOut] = await Promise.all([
      this.rpc.call({
        contractAddress: this.doomRuns,
        entrypoint: "leaderboard",
        calldata: leaderboardCalldata(versionId, kind, offset, limit),
      }),
      this.rpc.call({
        contractAddress: this.doomRuns,
        entrypoint: "leaderboard_len",
        calldata: [toHex(versionId), toHex(kind)],
      }),
    ]);
    const rows = decodeBoardRows(rowsOut);
    return {
      versionId,
      kind,
      offset,
      limit,
      total: decodeU32(lenOut),
      rows: rows.map((r, i) => ({ rank: offset + i + 1, runId: r.runId, player: r.player, value: r.value })),
    };
  }

  async run(runId: string): Promise<RunDetail | undefined> {
    const asRun = decodeRun(
      await this.rpc.call({ contractAddress: this.doomRuns, entrypoint: "get_run", calldata: [runId] }),
    );
    if (asRun.player !== ZERO && BigInt(asRun.player) !== 0n) {
      return {
        runId,
        player: asRun.player,
        versionId: asRun.versionId,
        levelId: asRun.levelId,
        tics: asRun.tics,
        kills: asRun.kills,
        items: asRun.items,
        secrets: asRun.secrets,
        score: asRun.score,
        status: "EXIT",
        nSegments: asRun.nSegments,
        fact: asRun.fact,
        replay: [], // the RPC fallback has no way to read `Replay` events; the indexer does
      };
    }
    const asAttempt = decodeRun(
      await this.rpc.call({ contractAddress: this.doomRuns, entrypoint: "get_attempt", calldata: [runId] }),
    );
    if (asAttempt.player === ZERO || BigInt(asAttempt.player) === 0n) return undefined;
    return {
      runId,
      player: asAttempt.player,
      versionId: asAttempt.versionId,
      levelId: asAttempt.levelId,
      tics: asAttempt.tics,
      kills: null,
      items: null,
      secrets: null,
      score: asAttempt.score,
      status: "DEAD",
      nSegments: null,
      fact: asAttempt.fact,
      replay: [],
    };
  }

  /** `player_runs` only ever lists finished (`EXIT`) runs — the contract writes the player index
   * exclusively for those (`record()` in `doom_runs.cairo`) — so this fetches every id the chain
   * knows about for `address` and computes bests over all of them; `offset`/`limit` only slice
   * the page handed back for display. Fine at the scale a devnet or an early season reaches; a
   * player with thousands of runs is exactly the case the indexer exists for. */
  async player(address: string, offset: number, limit: number): Promise<PlayerStats> {
    const countOut = await this.rpc.call({
      contractAddress: this.doomRuns,
      entrypoint: "player_run_count",
      calldata: [address],
    });
    const count = decodeU32(countOut);
    const idsOut = await this.rpc.call({
      contractAddress: this.doomRuns,
      entrypoint: "player_runs",
      calldata: [address, toHex(0), toHex(count)],
    });
    const ids = decodeFeltArray(idsOut);
    const all = await Promise.all(ids.map((id) => this.run(id)));
    const runs = all.filter((r): r is RunDetail => r !== undefined);
    const bestScore = runs.length ? Math.max(...runs.map((r) => r.score)) : null;
    const bestTics = runs.length ? Math.min(...runs.map((r) => r.tics)) : null;
    const page = runs.slice(offset, offset + limit);
    return {
      player: address,
      runCount: count,
      bestScore,
      bestTics,
      runs: page.map(
        (r): PlayerRunSummary => ({
          runId: r.runId,
          versionId: r.versionId,
          levelId: r.levelId,
          tics: r.tics,
          score: r.score,
          status: r.status,
        }),
      ),
    };
  }

  /** No on-chain view enumerates every version or totals runs across players; the RPC fallback
   * has nothing meaningful to answer here (`app.ts` hides the stats panel when this is `undefined`). */
  async stats(): Promise<ChainStats | undefined> {
    return undefined;
  }
}

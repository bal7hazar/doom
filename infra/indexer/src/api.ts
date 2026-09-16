// SPDX-License-Identifier: Apache-2.0
/**
 * The read API (P4.4): `GET /leaderboard`, `GET /players/{address}`, `GET /runs/{run_id}`,
 * `GET /stats` — and, for the open prover (D35, P4.7), `GET /players/{address}/commitments`,
 * `GET /commitments/{id}`, `GET /commitments/pending`. Plain `node:http` — the response shapes are small and the query surface is four
 * routes, so a framework buys nothing here that the rest of this repo's dependency-free style
 * would not rather do without (`client/src/chain/rpc.ts`'s docstring makes the same call).
 *
 * JSON keys are snake_case, matching the wrapper's own API (`prover/wrapper`, `docs/design/
 * doomruns.md` — `GET /v1/batches/{id}` returns `run_id`, `leaf_index`, …) so the leaderboard
 * page's two data sources (this API, and the RPC fallback) can share one response shape.
 */
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

import type { IndexerDb } from "./db.js";

function send(res: ServerResponse, status: number, body: unknown): void {
  const json = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(json),
    "access-control-allow-origin": "*",
  });
  res.end(json);
}

function intParam(url: URL, name: string, fallback: number): number {
  const raw = url.searchParams.get(name);
  if (raw === null) return fallback;
  const n = Number(raw);
  return Number.isFinite(n) ? Math.trunc(n) : fallback;
}

function runRow(row: Record<string, unknown>, replays: unknown[]): Record<string, unknown> {
  return { ...row, replay: replays };
}

export function createApiServer(db: IndexerDb) {
  return createServer((req: IncomingMessage, res: ServerResponse) => {
    let url: URL;
    try {
      url = new URL(req.url ?? "/", "http://localhost");
    } catch {
      send(res, 400, { error: "bad request" });
      return;
    }
    if (req.method === "OPTIONS") {
      res.writeHead(204, {
        "access-control-allow-origin": "*",
        "access-control-allow-methods": "GET, OPTIONS",
      });
      res.end();
      return;
    }
    if (req.method !== "GET") {
      send(res, 405, { error: "method not allowed" });
      return;
    }

    try {
      const parts = url.pathname.split("/").filter(Boolean);

      if (parts.length === 1 && parts[0] === "leaderboard") {
        const versionId = intParam(url, "version", 0);
        const kindRaw = intParam(url, "kind", 0);
        const kind = kindRaw === 1 ? 1 : 0;
        const offset = Math.max(0, intParam(url, "offset", 0));
        const limit = Math.min(200, Math.max(1, intParam(url, "limit", 50)));
        const rows = db.leaderboard(versionId, kind, offset, limit) as Record<string, unknown>[];
        send(res, 200, {
          version_id: versionId,
          kind,
          offset,
          limit,
          total: db.leaderboardLen(versionId),
          rows: rows.map((r, i) => ({ rank: offset + i + 1, ...r })),
        });
        return;
      }

      if (parts.length === 1 && parts[0] === "stats") {
        send(res, 200, db.stats());
        return;
      }

      if (parts.length === 2 && parts[0] === "players") {
        const player = parts[1]!;
        const offset = Math.max(0, intParam(url, "offset", 0));
        const limit = Math.min(200, Math.max(1, intParam(url, "limit", 50)));
        const stats = db.playerStats(player);
        const runs = db.playerRuns(player, offset, limit);
        // The player's games still waiting for a prover (D35) ride along with the runs — the
        // leaderboard page shows them under the recorded ones.
        const counts = db.commitmentCounts(player);
        const pending = db.playerCommitments(player, 0, limit, true);
        send(res, 200, {
          player,
          ...stats,
          commitment_count: counts.total,
          pending_commitment_count: counts.pending,
          runs,
          pending_commitments: pending,
        });
        return;
      }

      if (parts.length === 3 && parts[0] === "players" && parts[2] === "commitments") {
        const player = parts[1]!;
        const offset = Math.max(0, intParam(url, "offset", 0));
        const limit = Math.min(200, Math.max(1, intParam(url, "limit", 50)));
        const pendingOnly = url.searchParams.get("status") === "pending";
        send(res, 200, {
          player,
          ...db.commitmentCounts(player),
          offset,
          limit,
          commitments: db.playerCommitments(player, offset, limit, pendingOnly),
        });
        return;
      }

      if (parts.length === 2 && parts[0] === "commitments" && parts[1] === "pending") {
        const offset = Math.max(0, intParam(url, "offset", 0));
        const limit = Math.min(200, Math.max(1, intParam(url, "limit", 50)));
        send(res, 200, { offset, limit, ...db.commitmentCounts(), commitments: db.pendingCommitments(offset, limit) });
        return;
      }

      if (parts.length === 2 && parts[0] === "commitments") {
        const row = db.commitment(parts[1]!);
        if (!row) {
          send(res, 404, { error: `no such commitment: ${parts[1]}` });
          return;
        }
        send(res, 200, row);
        return;
      }

      if (parts.length === 2 && parts[0] === "runs") {
        const runId = parts[1]!;
        const run = db.run(runId) ?? db.attempt(runId);
        if (!run) {
          send(res, 404, { error: `no such run: ${runId}` });
          return;
        }
        const replays = db.replaysOf(runId).map((r) => ({
          leaf_index: r.leaf_index,
          tic_start: r.tic_start,
          tic_end: r.tic_end,
          packed: JSON.parse(r.packed) as string[],
        }));
        send(res, 200, runRow(run, replays));
        return;
      }

      send(res, 404, { error: "not found" });
    } catch (e) {
      send(res, 500, { error: e instanceof Error ? e.message : String(e) });
    }
  });
}

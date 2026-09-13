import type { AddressInfo } from "node:net";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { createApiServer } from "../src/api.js";
import { IndexerDb } from "../src/db.js";
import { pollOnce } from "../src/indexer.js";
import { FakeEventSource, runSubmitted } from "./fixtures.js";

describe("read API", () => {
  let db: IndexerDb;
  let server: ReturnType<typeof createApiServer>;
  let base: string;

  beforeEach(async () => {
    db = new IndexerDb(":memory:");
    const source = new FakeEventSource(
      [
        runSubmitted({ runId: "0x1", player: "0xa11ce", block: 1, score: 300, tics: 500 }),
        runSubmitted({ runId: "0x2", player: "0xa11ce", block: 2, score: 900, tics: 200 }),
        runSubmitted({ runId: "0x3", player: "0xb0b", block: 3, score: 600, tics: 100 }),
      ],
      10,
    );
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0 });

    server = createApiServer(db);
    await new Promise<void>((resolve) => server.listen(0, resolve));
    const { port } = server.address() as AddressInfo;
    base = `http://127.0.0.1:${port}`;
  });

  afterEach(async () => {
    await new Promise((resolve) => server.close(resolve));
    db.close();
  });

  it("GET /leaderboard?kind=0 orders by score descending", async () => {
    const res = await fetch(`${base}/leaderboard?version=1&kind=0`);
    const body = (await res.json()) as { total: number; rows: { run_id: string; rank: number }[] };
    expect(res.status).toBe(200);
    expect(body.total).toBe(3);
    expect(body.rows.map((r) => r.run_id)).toEqual(["0x2", "0x3", "0x1"]);
    expect(body.rows[0]!.rank).toBe(1);
  });

  it("GET /leaderboard?kind=1 orders by tics ascending (lower is better)", async () => {
    const res = await fetch(`${base}/leaderboard?version=1&kind=1`);
    const body = (await res.json()) as { rows: { run_id: string }[] };
    expect(body.rows.map((r) => r.run_id)).toEqual(["0x3", "0x2", "0x1"]);
  });

  it("GET /leaderboard paginates with offset/limit", async () => {
    const res = await fetch(`${base}/leaderboard?version=1&kind=0&offset=1&limit=1`);
    const body = (await res.json()) as { rows: { run_id: string; rank: number }[] };
    expect(body.rows).toHaveLength(1);
    expect(body.rows[0]).toMatchObject({ run_id: "0x3", rank: 2 });
  });

  it("GET /runs/{id} includes the replay log", async () => {
    const res = await fetch(`${base}/runs/0x1`);
    const body = (await res.json()) as { run_id: string; status: string; replay: unknown[] };
    expect(res.status).toBe(200);
    expect(body.run_id).toBe("0x1");
    expect(body.status).toBe("EXIT");
    expect(body.replay).toEqual([]);
  });

  it("GET /runs/{unknown} is a 404", async () => {
    const res = await fetch(`${base}/runs/0xnope`);
    expect(res.status).toBe(404);
  });

  it("GET /players/{address} aggregates run count and bests", async () => {
    const res = await fetch(`${base}/players/0xa11ce`);
    const body = (await res.json()) as { run_count: number; best_score: number; best_tics: number };
    expect(body.run_count).toBe(2);
    expect(body.best_score).toBe(900);
    expect(body.best_tics).toBe(200);
  });

  it("GET /stats reports totals", async () => {
    const res = await fetch(`${base}/stats`);
    const body = (await res.json()) as { total_runs: number; total_players: number; indexed_block: number };
    expect(body.total_runs).toBe(3);
    expect(body.total_players).toBe(2);
    expect(body.indexed_block).toBe(10);
  });

  it("unknown routes are 404", async () => {
    const res = await fetch(`${base}/nope`);
    expect(res.status).toBe(404);
  });
});

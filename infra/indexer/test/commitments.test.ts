// SPDX-License-Identifier: Apache-2.0
/**
 * The open-prover commitments (D35, P4.7) through the real decode + apply path: a player's
 * pending games, settlement by a third-party prover, reclaim after expiry, the `RunLog` chunk
 * count, a reorg that un-proves a commitment, a RECLAIMED id committed again, and the routes.
 */
import type { AddressInfo } from "node:net";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { createApiServer } from "../src/api.js";
import { IndexerDb } from "../src/db.js";
import { pollOnce } from "../src/indexer.js";
import { commitmentProved, commitmentReclaimed, FakeEventSource, runCommitted, runLog, runSubmitted } from "./fixtures.js";

const ALICE = "0xa11ce";
const BOB = "0xb0b";

describe("commitments in the database", () => {
  let db: IndexerDb;
  beforeEach(() => {
    db = new IndexerDb(":memory:");
  });
  afterEach(() => db.close());

  it("lists a player's pending commitments and counts their log chunks", async () => {
    const source = new FakeEventSource(
      [
        runCommitted({ id: "0xc1", player: ALICE, block: 1, tics: 900, bounty: 5n * 10n ** 17n, nChunks: 2 }),
        runLog({ id: "0xc1", block: 1, chunk: 0, offset: 0 }),
        runLog({ id: "0xc1", block: 1, chunk: 1, offset: 256 }),
        runCommitted({ id: "0xc2", player: ALICE, block: 2, tics: 9 }),
        runLog({ id: "0xc2", block: 2 }),
        runCommitted({ id: "0xc3", player: BOB, block: 3 }),
      ],
      10,
    );
    const result = await pollOnce(db, source, { address: "0xd00d", startBlock: 0 });
    expect(result.eventsApplied).toBe(6);
    const pending = db.playerCommitments(ALICE, 0, 50, true) as Record<string, unknown>[];
    expect(pending.map((c) => c["commitment_id"])).toEqual(["0xc2", "0xc1"]); // newest first
    expect(pending[1]).toMatchObject({
      player: ALICE,
      version_id: 1,
      level_id: 1,
      tics: 900,
      bounty: "500000000000000000",
      expires_at: 51,
      n_chunks: 2,
      log_chunks: 2,
      status: "PENDING",
      run_id: null,
      prover: null,
      block_number: 1,
    });
    expect(db.commitmentCounts(ALICE)).toEqual({ total: 2, pending: 2 });
    expect(db.commitmentCounts()).toEqual({ total: 3, pending: 3 });
    expect((db.pendingCommitments(0, 10) as Record<string, unknown>[]).map((c) => c["commitment_id"])).toEqual(["0xc1", "0xc2", "0xc3"]);
    expect(db.stats()).toMatchObject({ total_commitments: 3, pending_commitments: 3 });
  });

  it("settles a commitment when a third party proves it, and refunds on reclaim", async () => {
    const source = new FakeEventSource(
      [
        runCommitted({ id: "0xc1", player: ALICE, block: 1, bounty: 7n }),
        runCommitted({ id: "0xc2", player: ALICE, block: 1, bounty: 3n, expiresAt: 5 }),
        runSubmitted({ runId: "0x51", player: ALICE, block: 4 }),
        commitmentProved({ id: "0xc1", runId: "0x51", prover: BOB, player: ALICE, bounty: 7n, block: 4 }),
        commitmentReclaimed({ id: "0xc2", player: ALICE, bounty: 3n, block: 6 }),
      ],
      10,
    );
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0 });
    expect(db.commitment("0xc1")).toMatchObject({ status: "PROVED", run_id: "0x51", prover: BOB, settled_block: 4, settled_tx: "0xed4" });
    expect(db.commitment("0xc2")).toMatchObject({ status: "RECLAIMED", run_id: null, prover: null, settled_block: 6 });
    expect(db.playerCommitments(ALICE, 0, 50, true)).toEqual([]);
    expect((db.playerCommitments(ALICE, 0, 50) as Record<string, unknown>[]).map((c) => c["status"])).toEqual(["PROVED", "RECLAIMED"]);
    expect(db.commitmentCounts(ALICE)).toEqual({ total: 2, pending: 0 });
    expect(db.commitment("0xnope")).toBeUndefined();
  });

  it("a reorg that drops the settlement puts the commitment back to PENDING, not gone", async () => {
    const proved = commitmentProved({ id: "0xc1", runId: "0x51", prover: BOB, block: 8 });
    const source = new FakeEventSource([runCommitted({ id: "0xc1", player: ALICE, block: 1 }), proved], 10);
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0, reorgDepth: 5 });
    expect(db.commitment("0xc1")).toMatchObject({ status: "PROVED" });
    // The fork without the settlement wins; the window [6, 12] is re-scanned.
    source.events = [runCommitted({ id: "0xc1", player: ALICE, block: 1 })];
    source.head = 12;
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0, reorgDepth: 5 });
    expect(db.commitment("0xc1")).toMatchObject({ status: "PENDING", run_id: null, block_number: 1 });
    expect(db.commitmentCounts(ALICE)).toEqual({ total: 1, pending: 1 });
  });

  it("a RECLAIMED id committed again starts over: new expiry, pending, old settlement forgotten", async () => {
    const source = new FakeEventSource(
      [
        runCommitted({ id: "0xc1", player: ALICE, block: 1, bounty: 1n, expiresAt: 3, nChunks: 1 }),
        runLog({ id: "0xc1", block: 1 }),
        commitmentReclaimed({ id: "0xc1", player: ALICE, bounty: 1n, block: 4 }),
        runCommitted({ id: "0xc1", player: ALICE, block: 7, bounty: 2n, expiresAt: 57, nChunks: 1 }),
        runLog({ id: "0xc1", block: 7 }),
      ],
      10,
    );
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0 });
    expect(db.commitment("0xc1")).toMatchObject({ status: "PENDING", bounty: "2", expires_at: 57, block_number: 7, log_chunks: 1 });
    expect(db.commitmentCounts(ALICE)).toEqual({ total: 1, pending: 1 });
  });
});

describe("commitment routes", () => {
  let db: IndexerDb;
  let server: ReturnType<typeof createApiServer>;
  let base: string;

  beforeEach(async () => {
    db = new IndexerDb(":memory:");
    const source = new FakeEventSource(
      [
        runSubmitted({ runId: "0x1", player: ALICE, block: 1, score: 300, tics: 500 }),
        runCommitted({ id: "0xc1", player: ALICE, block: 2, tics: 900, bounty: 5n }),
        runLog({ id: "0xc1", block: 2 }),
        runCommitted({ id: "0xc2", player: ALICE, block: 3, tics: 400 }),
        commitmentProved({ id: "0xc2", runId: "0x1", prover: BOB, player: ALICE, block: 5 }),
        runCommitted({ id: "0xc3", player: BOB, block: 6 }),
      ],
      10,
    );
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0 });
    server = createApiServer(db);
    await new Promise<void>((resolve) => server.listen(0, resolve));
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  afterEach(async () => {
    await new Promise((resolve) => server.close(resolve));
    db.close();
  });

  it("GET /players/{address} carries the pending commitments under the runs", async () => {
    const res = await fetch(`${base}/players/${ALICE}`);
    const body = (await res.json()) as {
      run_count: number;
      commitment_count: number;
      pending_commitment_count: number;
      runs: unknown[];
      pending_commitments: { commitment_id: string; status: string; tics: number; bounty: string; expires_at: number; log_chunks: number }[];
    };
    expect(res.status).toBe(200);
    expect(body.run_count).toBe(1);
    expect(body.commitment_count).toBe(2);
    expect(body.pending_commitment_count).toBe(1);
    expect(body.pending_commitments).toEqual([
      expect.objectContaining({ commitment_id: "0xc1", status: "PENDING", tics: 900, bounty: "5", expires_at: 52, log_chunks: 1 }),
    ]);
  });

  it("GET /players/{address}/commitments lists them all, or only the pending ones", async () => {
    const all = (await (await fetch(`${base}/players/${ALICE}/commitments`)).json()) as { total: number; pending: number; commitments: { commitment_id: string; status: string }[] };
    expect(all.total).toBe(2);
    expect(all.pending).toBe(1);
    expect(all.commitments.map((c) => [c.commitment_id, c.status])).toEqual([["0xc2", "PROVED"], ["0xc1", "PENDING"]]);
    const pending = (await (await fetch(`${base}/players/${ALICE}/commitments?status=pending`)).json()) as { commitments: { commitment_id: string }[] };
    expect(pending.commitments.map((c) => c.commitment_id)).toEqual(["0xc1"]);
  });

  it("GET /commitments/{id} and /commitments/pending", async () => {
    const one = await fetch(`${base}/commitments/0xc2`);
    expect(one.status).toBe(200);
    expect(await one.json()).toMatchObject({ commitment_id: "0xc2", status: "PROVED", run_id: "0x1", prover: BOB, settled_block: 5 });
    expect((await fetch(`${base}/commitments/0xnope`)).status).toBe(404);
    const pending = (await (await fetch(`${base}/commitments/pending?limit=10`)).json()) as { total: number; pending: number; commitments: { commitment_id: string }[] };
    expect(pending).toMatchObject({ total: 3, pending: 2 });
    expect(pending.commitments.map((c) => c.commitment_id)).toEqual(["0xc1", "0xc3"]);
  });

  it("GET /stats counts commitments", async () => {
    const body = (await (await fetch(`${base}/stats`)).json()) as { total_commitments: number; pending_commitments: number };
    expect(body).toMatchObject({ total_commitments: 3, pending_commitments: 2 });
  });
});

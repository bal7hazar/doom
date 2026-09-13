import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { IndexerDb } from "../src/db.js";
import { follow, pollOnce } from "../src/indexer.js";
import { FakeEventSource, runSubmitted } from "./fixtures.js";

describe("pollOnce", () => {
  let db: IndexerDb;

  beforeEach(() => {
    db = new IndexerDb(":memory:");
  });
  afterEach(() => db.close());

  it("indexes a run and advances the cursor to the chain head", async () => {
    const source = new FakeEventSource([runSubmitted({ runId: "0x1", block: 5 })], 10);
    const result = await pollOnce(db, source, { address: "0xd00d", startBlock: 0 });
    expect(result).toEqual({ fromBlock: 0, head: 10, eventsApplied: 1 });
    expect(db.getCursor()).toEqual({ lastBlock: 10 });
    expect(db.run("0x1")).toMatchObject({ run_id: "0x1", score: 525, block_number: 5 });
  });

  it("pages through several chunks via the continuation token", async () => {
    const events = Array.from({ length: 5 }, (_, i) => runSubmitted({ runId: "0x" + (i + 10).toString(16), block: i + 1 }));
    const source = new FakeEventSource(events, 10, /* pageSize */ 2);
    const result = await pollOnce(db, source, { address: "0xd00d", startBlock: 0 });
    expect(result.eventsApplied).toBe(5);
    expect(source.calls.length).toBe(3); // 2 + 2 + 1
    expect(db.leaderboardLen(1)).toBe(5);
  });

  it("does nothing when the start block is already past the chain head", async () => {
    const source = new FakeEventSource([], 5);
    const result = await pollOnce(db, source, { address: "0xd00d", startBlock: 6 });
    expect(result).toEqual({ fromBlock: 6, head: 5, eventsApplied: 0 });
    expect(db.getCursor()).toBeUndefined(); // nothing scanned yet, so no cursor is written
  });

  it("advances the window on the next poll instead of re-scanning from genesis", async () => {
    const source = new FakeEventSource([runSubmitted({ runId: "0x1", block: 2 })], 20, 100);
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0, reorgDepth: 5 });
    source.head = 30;
    source.events.push(runSubmitted({ runId: "0x2", block: 25 }));
    const second = await pollOnce(db, source, { address: "0xd00d", startBlock: 0, reorgDepth: 5 });
    // second poll's window starts at lastBlock(20) - reorgDepth(5) + 1 = 16, not 0.
    expect(second.fromBlock).toBe(16);
    expect(db.run("0x1")).toBeDefined(); // outside the rescanned window, untouched
    expect(db.run("0x2")).toBeDefined();
  });

  it("is reorg-safe: a run replaced within the rescanned window disappears, the old one is purged", async () => {
    const source = new FakeEventSource([runSubmitted({ runId: "0x1", block: 8, score: 100 })], 10, 100);
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0, reorgDepth: 10 });
    expect(db.run("0x1")).toMatchObject({ score: 100 });

    // Simulate a reorg: block 8 is re-orged out, replaced by a different run at the same height.
    source.events = [runSubmitted({ runId: "0x2", block: 8, score: 999 })];
    source.head = 11;
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0, reorgDepth: 10 });

    expect(db.run("0x1")).toBeUndefined(); // the orphaned run is gone
    expect(db.run("0x2")).toMatchObject({ score: 999 });
  });

  it("a re-poll with the same events is idempotent (no duplicate rows, same leaderboard length)", async () => {
    const source = new FakeEventSource([runSubmitted({ runId: "0x1", block: 3 })], 10);
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0, reorgDepth: 10 });
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0, reorgDepth: 10 });
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0, reorgDepth: 10 });
    expect(db.leaderboardLen(1)).toBe(1);
  });

  it("leaves rows below the rescanned window alone even across many polls", async () => {
    const source = new FakeEventSource(
      [runSubmitted({ runId: "0x999", block: 1 }), runSubmitted({ runId: "0x2", block: 12 })],
      15,
      100,
    );
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0, reorgDepth: 5 });
    // fromBlock = max(0, 15-5+1)=11, so block 1's row must have come from an earlier poll in a
    // real run; here it is present because it was in-range on this very first poll (fromBlock=0
    // since there was no cursor yet). Poll again to exercise the narrowed window this time.
    source.head = 16;
    await pollOnce(db, source, { address: "0xd00d", startBlock: 0, reorgDepth: 5 });
    expect(db.run("0x999")).toBeDefined();
    expect(db.run("0x2")).toBeDefined();
  });
});

describe("follow", () => {
  it("polls repeatedly until the signal aborts, and reports errors without dying", async () => {
    const db = new IndexerDb(":memory:");
    const source = new FakeEventSource([runSubmitted({ runId: "0x1", block: 1 })], 5);
    const controller = new AbortController();
    const polls: number[] = [];
    const errors: unknown[] = [];

    const done = follow(db, source, {
      address: "0xd00d",
      startBlock: 0,
      intervalMs: 5,
      signal: controller.signal,
      onPoll: (r) => {
        polls.push(r.head);
        if (polls.length >= 3) controller.abort();
      },
      onError: (e) => errors.push(e),
    });
    await done;
    expect(polls.length).toBeGreaterThanOrEqual(3);
    expect(errors).toEqual([]);
    db.close();
  });
});

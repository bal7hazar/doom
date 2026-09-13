/**
 * Integration test against a real devnet with `DoomRuns` deployed and at least one batch
 * submitted (the P4.2b / P4.3 drive). Skips itself — rather than failing — when
 * `INDEXER_TEST_RPC`/`INDEXER_TEST_ADDRESS` are not set, so `npm test` stays green in a clone
 * with no devnet running (same convention as `infra/submit/test`).
 *
 *   starknet-devnet --seed 42 --port 5081 ...                     # see infra/submit/README.md
 *   # deploy DoomRuns, add_version/set_genesis, submit_batch (docs/design/doomruns.md §13)
 *   INDEXER_TEST_RPC=http://127.0.0.1:5081/rpc INDEXER_TEST_ADDRESS=0x... npm test
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";

import { IndexerDb } from "../src/db.js";
import { pollOnce } from "../src/indexer.js";
import { StarknetRpcEventSource } from "../src/rpcSource.js";

const rpcUrl = process.env["INDEXER_TEST_RPC"];
const address = process.env["INDEXER_TEST_ADDRESS"];
const startBlock = Number(process.env["INDEXER_TEST_START_BLOCK"] ?? "0");

describe.skipIf(!rpcUrl || !address)("devnet integration", () => {
  const dir = mkdtempSync(join(tmpdir(), "doomruns-indexer-"));
  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  it("indexes the real DoomRuns deployment and answers the read API from it", async () => {
    const db = new IndexerDb(join(dir, "indexer.sqlite"));
    const source = new StarknetRpcEventSource(rpcUrl!);
    const result = await pollOnce(db, source, { address: address!, startBlock });
    expect(result.head).toBeGreaterThanOrEqual(0);

    const stats = db.stats();
    expect(stats.total_runs + stats.total_attempts).toBeGreaterThan(0);

    // Re-polling must be idempotent: same totals, cursor does not move backwards.
    const before = db.stats();
    await pollOnce(db, source, { address: address!, startBlock });
    const after = db.stats();
    expect(after.total_runs).toBe(before.total_runs);
    expect(after.total_attempts).toBe(before.total_attempts);
    db.close();
  });
});

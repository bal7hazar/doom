// SPDX-License-Identifier: Apache-2.0
/** Real-root planning, gas fallback policy, and resumes across the D28 default change. */
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { prepareSubmission, type PrepareArgs } from "../../../client/src/chain/submission.js";
import { resumePoint, runSequence, storedFriSplit, TAG } from "../../../client/src/chain/sequence.js";
import type { ResourceBounds, RpcClient } from "../../../client/src/chain/rpc.js";
import { submissionPlans } from "../src/planning.js";
import { loadBatch } from "../src/fixture.js";
import { FileEchoStore } from "../src/stores.js";

const loaded = loadBatch(join(import.meta.dirname,
  "../../../cairo/doom_contracts/crates/recursion_outputs/fixtures/B2-1_doom"));
const CALLER = "0x123";
const args: PrepareArgs = {
  batch: loaded.batch,
  router: "0x456",
  doomRuns: "0x789",
  versionId: loaded.versionId,
  proofId: 1n,
  players: Object.fromEntries(loaded.batch.placements.map((p) => [p.runId, CALLER])),
  levelIds: loaded.levelIds,
  replay: true,
};
const workdirs: string[] = [];
afterEach(() => workdirs.splice(0).forEach((dir) => rmSync(dir, { recursive: true })));
const storePath = () => {
  const dir = mkdtempSync(join(tmpdir(), "d28-resume-"));
  workdirs.push(dir);
  return join(dir, "echoes.json");
};
const bound: ResourceBounds = {
  l1_gas: { max_amount: "0x186a0", max_price_per_unit: "0x1" },
  l1_data_gas: { max_amount: "0x200", max_price_per_unit: "0x1" },
  l2_gas: { max_amount: "0x20000000", max_price_per_unit: "0x1" },
};

function rpcAt(tag: number, count = 0): RpcClient {
  return {
    call: vi.fn(async () => ["0x" + tag.toString(16), "0xdead"]),
    request: vi.fn(async () => ({ events: Array.from({ length: count }, (_, i) => ({
      transaction_hash: "0x" + (i + 1).toString(16), data: ["0x2", "0xdead"],
    })) })),
    trace: vi.fn(async () => ({ execute_invocation: { calls: [{ result: ["0x1", "0xab"] }] } })),
  } as unknown as RpcClient;
}

async function startThenDisconnect(path: string, plan?: number[]): Promise<void> {
  const prepared = prepareSubmission({ ...args, ...(plan ? { plan: { friSplit: plan } } : {}) });
  const store = new FileEchoStore(path);
  await expect(runSequence(rpcAt(TAG.FREE), prepared.sequence, {
    store,
    bounds: Array.from({ length: prepared.phases.length + 1 }, () => bound),
    signer: {
      kind: "test", address: CALLER,
      execute: async () => {
        // The plan is durable before a transaction can be accepted with a lost receipt.
        expect(storedFriSplit(new FileEchoStore(path), 1n, args.router, CALLER)).toEqual(plan ?? [2]);
        throw new Error("connection lost after send");
      },
    },
  })).rejects.toThrow(/connection lost/);
}

describe("submission planning", () => {
  it("prepares five verifier transactions and one consumer by default", () => {
    const prepared = prepareSubmission(args);
    expect(prepared.phases).toHaveLength(5);
    expect(prepared.sequence.consumer.call.entrypoint).toBe("submit_batch");
    expect(prepared.phases.slice(3).map((p) => p.meta.layers)).toEqual([[0, 1], [2, 3, 4, 5]]);
  });

  it("keeps consumer/replay calldata unchanged in every gas-cap fallback", () => {
    const first = prepareSubmission(args);
    const plans = [...submissionPlans(args, first, 0)];
    expect(plans.map((p) => p.phases.length)).toEqual([5, 7, 8]);
    for (const p of plans) expect(p.sequence.consumer).toEqual(first.sequence.consumer);
  });

  it("keeps --single across every gas-cap fallback", () => {
    const single = { ...args, singleMember: prepareSubmission(args).members[0]! };
    const first = prepareSubmission(single);
    for (const p of submissionPlans(single, first, 0)) {
      expect(p.members).toEqual([single.singleMember]);
      expect(p.sequence.consumer.call.entrypoint).toBe("register_member");
      expect(p.sequence.consumer).toEqual(first.sequence.consumer);
    }
  });

  it("never replans an explicit cut or a sequence that has started", () => {
    const explicit = { ...args, plan: { friSplit: [1, 3] } };
    expect([...submissionPlans(explicit, prepareSubmission(explicit), 0)]).toHaveLength(1);
    expect([...submissionPlans(args, prepareSubmission(args), 1)]).toHaveLength(1);
  });
});

describe("FRI plan persistence and legacy resume", () => {
  it("restores a saved six-transaction plan after the default changes to five", async () => {
    const path = storePath();
    await startThenDisconnect(path, [1, 3]);
    const store = new FileEchoStore(path);
    const friSplit = storedFriSplit(store, 1n, args.router, CALLER)!;
    const restored = prepareSubmission({ ...args, plan: { friSplit } });
    expect(restored.phases).toHaveLength(6);
    expect(restored.phases[4]!.meta.layers).toEqual([1, 2]);
    expect(await resumePoint(rpcAt(TAG.FRI, 4), restored.sequence, CALLER, store))
      .toMatchObject({ nextPhase: 4, echo: ["0xab"] });
  });

  it("restores the saved cut in a browser sequence before estimating it", async () => {
    const path = storePath();
    await startThenDisconnect(path, [1, 3]);
    const automatic = prepareSubmission(args);
    expect(automatic.phases).toHaveLength(5);
    await resumePoint(rpcAt(TAG.FRI, 4), automatic.sequence, CALLER, new FileEchoStore(path));
    const original = prepareSubmission({ ...args, plan: { friSplit: [1, 3] } });
    expect(automatic.phases).toEqual(original.phases);
    expect(automatic.sequence.phases).toBe(automatic.phases);
    expect(automatic.payloadSlots).toBe(original.payloadSlots);
  });

  it("persists and resumes the new default in file and browser-compatible echo stores", async () => {
    const path = storePath();
    await startThenDisconnect(path);
    const seq = prepareSubmission(args).sequence;
    expect(await resumePoint(rpcAt(TAG.FRI, 4), seq, CALLER, new FileEchoStore(path)))
      .toMatchObject({ nextPhase: 4 });
  });

  it("refuses an old six-tx FRI resume without a known cut before any send", async () => {
    const path = storePath();
    // The pre-D28 format has only checkpoint echoes, no plan metadata.
    const legacy = JSON.stringify({ "1:3": ["0xabc"] });
    writeFileSync(path, legacy);
    const store = new FileEchoStore(path);
    const rpc = rpcAt(TAG.FRI, 4); // Same tag/count as the new five-tx plan, different next layers.
    const execute = vi.fn();
    await expect(runSequence(rpc, prepareSubmission(args).sequence, {
      store, signer: { kind: "test", address: CALLER, execute }, bounds: new Array(6).fill(bound),
    })).rejects.toThrow(/original FRI split is unknown.*--fri-split 1,3/);
    expect(execute).not.toHaveBeenCalled();
    expect(rpc.trace).not.toHaveBeenCalled();
    expect(readFileSync(path, "utf8")).toBe(legacy);

    // The operator can supply the actual historic cut; old echoes are preserved and usable.
    const explicit = prepareSubmission({ ...args, plan: { friSplit: [1, 3] } });
    expect(await resumePoint(rpc, explicit.sequence, CALLER, store))
      .toMatchObject({ nextPhase: 4, echo: ["0xabc"], echoSource: "store" });
  });

  it("records an explicitly recovered legacy cut before sending the unpaid suffix", async () => {
    const path = storePath();
    writeFileSync(path, JSON.stringify({ "1:3": ["0xabc"] }));
    const prepared = prepareSubmission({ ...args, plan: { friSplit: [1, 3] } });
    await expect(runSequence(rpcAt(TAG.FRI, 4), prepared.sequence, {
      store: new FileEchoStore(path), bounds: new Array(7).fill(bound),
      signer: { kind: "test", address: CALLER, execute: async () => {
        expect(storedFriSplit(new FileEchoStore(path), 1n, args.router, CALLER)).toEqual([1, 3]);
        throw new Error("connection lost after resumed send");
      } },
    })).rejects.toThrow(/connection lost/);
    expect(new FileEchoStore(path).get(1n, 3)).toEqual(["0xabc"]);
  });

  it("rejects a conflicting cut even when explicitly requested", async () => {
    const path = storePath();
    await startThenDisconnect(path, [1, 3]);
    const conflicting = prepareSubmission({ ...args, plan: { friSplit: [2] } });
    await expect(resumePoint(rpcAt(TAG.FRI, 4), conflicting.sequence, CALLER, new FileEchoStore(path)))
      .rejects.toThrow(/stored FRI plan differs.*--fri-split 1,3/);
  });

  it("does not reuse a plan belonging to a different router or account", async () => {
    const path = storePath();
    await startThenDisconnect(path, [1, 3]);
    const store = new FileEchoStore(path);
    expect(storedFriSplit(store, 1n, "0x457", CALLER)).toBeNull();
    expect(storedFriSplit(store, 1n, args.router, "0x124")).toBeNull();
    expect(storedFriSplit(store, 2n, args.router, CALLER)).toBeNull();
    expect(storedFriSplit(store, 1n, "0x0456", "0x0123")).toEqual([1, 3]);
  });
});

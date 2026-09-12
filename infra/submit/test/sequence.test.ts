// SPDX-License-Identifier: Apache-2.0
/**
 * Resume logic against a mocked RPC.
 *
 * What is being pinned: the router's checkpoint tag alone cannot say which phase is next
 * (`begin` and `merkle` both leave `MERKLE`, every FRI chunk but the last leaves `FRI`), so the
 * count of `Step` events is what places the sequence, and the tag is the consistency check that
 * catches a resume with a differently-cut plan — which would otherwise send a full 4 600-felt
 * calldata for the router to refuse on the state echo.
 */

import { describe, expect, it, vi } from "vitest";

import { getSelectorFromName } from "../../../client/src/chain/selector.js";
import {
  MemoryEchoStore,
  buildSequence,
  echoFromTrace,
  readCheckpoint,
  resumePoint,
  runSequence,
  sequenceSteps,
  TAG,
} from "../../../client/src/chain/sequence.js";
import type { PhasePlan } from "../../../client/src/chain/calldata.js";
import type { RpcClient } from "../../../client/src/chain/rpc.js";
import type { Signer } from "../../../client/src/chain/signer.js";

const ROUTER = "0x4fd8";
const RUNS = "0x2e10";
const CALLER = "0x34ba";

const phase = (label: string, entrypoint: PhasePlan["entrypoint"], echo: PhasePlan["echo"]): PhasePlan => ({
  label,
  entrypoint,
  echo,
  calldataFelts: 10,
  payloadSlots: 1,
  proofId: 1n,
  payload: [1n],
  ...(entrypoint === "begin" ? { head: [2n], headN: 7 } : {}),
  ...(entrypoint === "fri" ? { nValues: 1 } : { lens: [1] }),
  ...(entrypoint === "begin" || entrypoint === "merkle" ? { trees: [0, 1] } : {}),
  meta: {},
});

const PHASES = [
  phase("begin", "begin", null),
  phase("merkle", "merkle", "merkle_state"),
  phase("answers", "answers", "merkle_state"),
  phase("fri1", "fri", "fri_state"),
  phase("fri2", "fri", "fri_state"),
];

const seq = buildSequence({
  proofId: 1n,
  router: ROUTER,
  doomRuns: RUNS,
  phases: PHASES,
  submitCalldata: ["0x1"],
});

/** A mocked node: a checkpoint, a list of `Step` events and one retdata per transaction. */
function mockRpc(options: {
  tag: number;
  steps?: { transactionHash: string; tag: number }[];
  retdata?: Record<string, string[]>;
  receipts?: Record<string, unknown>;
}): RpcClient {
  const steps = options.steps ?? [];
  return {
    call: vi.fn(async (c: { entrypoint: string }) => {
      if (c.entrypoint === "checkpoint") return ["0x" + options.tag.toString(16), "0xdead"];
      throw new Error(`unexpected view call ${c.entrypoint}`);
    }),
    request: vi.fn(async (method: string, params: any) => {
      expect(method).toBe("starknet_getEvents");
      expect(params[0].keys[0]).toEqual([getSelectorFromName("Step")]);
      expect(params[0].keys[1]).toEqual([CALLER]);
      return {
        events: steps.map((s) => ({
          transaction_hash: s.transactionHash,
          data: ["0x" + s.tag.toString(16), "0xdead"],
        })),
      };
    }),
    trace: vi.fn(async (tx: string) => {
      const result = options.retdata?.[tx];
      return result
        ? { execute_invocation: { calls: [{ result: ["0x" + result.length.toString(16), ...result] }] } }
        : {};
    }),
    waitForReceipt: vi.fn(async () => ({
      execution_status: "SUCCEEDED",
      execution_resources: { l2_gas: 1_000, l1_data_gas: 10 },
      actual_fee: { amount: "0x64" },
      events: [],
      ...options.receipts,
    })),
  } as unknown as RpcClient;
}

describe("the sequence", () => {
  it("is the phases then the consumer", () => {
    const steps = sequenceSteps(seq, [null, ["0x1"], ["0x1"], ["0x1"], ["0x1"]]);
    expect(steps.map((s) => s.label)).toEqual([
      "begin",
      "merkle",
      "answers",
      "fri1",
      "fri2",
      "submit_batch",
    ]);
    expect(steps.at(-1)!.phase).toBe("consumer");
    expect(steps.at(-1)!.call.contractAddress).toBe(RUNS);
    expect(steps[0]!.call.contractAddress).toBe(ROUTER);
  });

  it("reads the checkpoint as (tag, state hash)", async () => {
    const rpc = mockRpc({ tag: TAG.MERKLE });
    expect(await readCheckpoint(rpc, ROUTER, CALLER, 1n)).toEqual({
      tag: TAG.MERKLE,
      stateHash: "0xdead",
    });
  });

  it("reads a checkpoint echo out of a transaction trace", async () => {
    const rpc = mockRpc({ tag: TAG.MERKLE, retdata: { "0xaa": ["0x1", "0x2"] } });
    expect(await echoFromTrace(rpc, "0xaa")).toEqual(["0x1", "0x2"]);
    expect(await echoFromTrace(rpc, "0xbb")).toBeNull();
  });
});

describe("resume", () => {
  it("starts at begin when the slot is free", async () => {
    const r = await resumePoint(mockRpc({ tag: TAG.FREE }), seq, CALLER);
    expect(r).toMatchObject({ nextPhase: 0, echo: null, factRegistered: false });
  });

  it("reports a finished fact and skips every phase", async () => {
    const r = await resumePoint(mockRpc({ tag: TAG.DONE }), seq, CALLER);
    expect(r.factRegistered).toBe(true);
    expect(r.nextPhase).toBe(PHASES.length);
  });

  it("places the sequence by the number of Step events, not by the tag", async () => {
    // Tag MERKLE is ambiguous: it is left by `begin` AND by `merkle`.
    const afterBegin = await resumePoint(
      mockRpc({
        tag: TAG.MERKLE,
        steps: [{ transactionHash: "0xa", tag: TAG.MERKLE }],
        retdata: { "0xa": ["0x7"] },
      }),
      seq,
      CALLER,
    );
    expect(afterBegin.nextPhase).toBe(1);

    const afterMerkle = await resumePoint(
      mockRpc({
        tag: TAG.MERKLE,
        steps: [
          { transactionHash: "0xa", tag: TAG.MERKLE },
          { transactionHash: "0xb", tag: TAG.MERKLE },
        ],
        retdata: { "0xb": ["0x8"] },
      }),
      seq,
      CALLER,
    );
    expect(afterMerkle.nextPhase).toBe(2);
    expect(afterMerkle.echo).toEqual(["0x8"]);
  });

  it("prefers a stored echo over a trace round trip", async () => {
    const store = new MemoryEchoStore();
    store.set(1n, 2, ["0x99"]);
    const rpc = mockRpc({
      tag: TAG.FRI,
      steps: [
        { transactionHash: "0xa", tag: TAG.MERKLE },
        { transactionHash: "0xb", tag: TAG.MERKLE },
        { transactionHash: "0xc", tag: TAG.FRI },
      ],
      retdata: { "0xc": ["0xbad"] },
    });
    const r = await resumePoint(rpc, seq, CALLER, store);
    expect(r).toMatchObject({ nextPhase: 3, echoSource: "store" });
    expect(r.echo).toEqual(["0x99"]);
    expect(rpc.trace).not.toHaveBeenCalled();
  });

  it("refuses a resume whose tag disagrees with the plan", async () => {
    // Two Step events means `answers` is next, which needs a MerkleState — but the router is
    // already in the FRI phase, so this plan is not the one that started the sequence.
    await expect(
      resumePoint(
        mockRpc({
          tag: TAG.FRI,
          steps: [
            { transactionHash: "0xa", tag: TAG.MERKLE },
            { transactionHash: "0xb", tag: TAG.FRI },
          ],
          retdata: { "0xb": ["0x1"] },
        }),
        seq,
        CALLER,
      ),
    ).rejects.toThrow(/plans disagree/);
  });

  it("refuses a resume past the end of the plan", async () => {
    const steps = Array.from({ length: 6 }, (_, i) => ({
      transactionHash: `0x${i}`,
      tag: TAG.FRI,
    }));
    await expect(resumePoint(mockRpc({ tag: TAG.FRI, steps }), seq, CALLER)).rejects.toThrow(
      /different FRI split/,
    );
  });

  it("gives up when the echo is neither stored nor traceable", async () => {
    await expect(
      resumePoint(
        mockRpc({ tag: TAG.MERKLE, steps: [{ transactionHash: "0xa", tag: TAG.MERKLE }] }),
        seq,
        CALLER,
      ),
    ).rejects.toThrow(/restart under a fresh proof id/);
  });
});

describe("running the sequence", () => {
  const signerFor = (sent: string[]): Signer => ({
    address: CALLER,
    kind: "test",
    execute: async (calls) => {
      sent.push(calls[0]!.entrypoint);
      return { transactionHash: "0xa" };
    },
  });

  it("skips what the chain already has and sends the rest", async () => {
    const sent: string[] = [];
    const rpc = mockRpc({
      tag: TAG.MERKLE,
      steps: [{ transactionHash: "0xa", tag: TAG.MERKLE }],
      retdata: { "0xa": ["0x7"] },
    });
    const bounds = new Array(6).fill({
      l1_gas: { max_amount: "0x1", max_price_per_unit: "0x1" },
      l1_data_gas: { max_amount: "0x1", max_price_per_unit: "0x1" },
      l2_gas: { max_amount: "0x1", max_price_per_unit: "0x1" },
    });
    const store = new MemoryEchoStore();
    const result = await runSequence(rpc, seq, { signer: signerFor(sent), bounds, store });

    expect(result.resumedAt).toBe(1);
    expect(sent).toEqual(["merkle", "answers", "fri", "fri", "submit_batch"]);
    expect(result.steps.filter((s) => s.state === "skipped").map((s) => s.label)).toEqual(["begin"]);
    // Every accepted phase's echo is persisted, so the next resume needs no trace.
    expect(store.get(1n, 1)).toEqual(["0x7"]);
  });

  it("stops before the consumer when asked", async () => {
    const sent: string[] = [];
    const rpc = mockRpc({ tag: TAG.FREE, retdata: { "0xa": ["0x7"] } });
    const bounds = new Array(6).fill({
      l1_gas: { max_amount: "0x1", max_price_per_unit: "0x1" },
      l1_data_gas: { max_amount: "0x1", max_price_per_unit: "0x1" },
      l2_gas: { max_amount: "0x1", max_price_per_unit: "0x1" },
    });
    await runSequence(rpc, seq, { signer: signerFor(sent), bounds, verifierOnly: true });
    expect(sent).not.toContain("submit_batch");
  });

  it("refuses to send a step it has no bounds for", async () => {
    await expect(
      runSequence(mockRpc({ tag: TAG.FREE }), seq, { signer: signerFor([]), bounds: [] }),
    ).rejects.toThrow(/no resource bounds/);
  });
});

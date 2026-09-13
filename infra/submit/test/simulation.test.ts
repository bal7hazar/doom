// SPDX-License-Identifier: Apache-2.0
/** D28 still estimates ordered, unsigned transactions from the eventual signing account. */
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { simulateSequence, INVOKE_L2_GAS_CAP } from "../../../client/src/chain/estimate.js";
import { executeCalldata, type GasPrices, type RpcClient } from "../../../client/src/chain/rpc.js";
import { phaseCalldata } from "../../../client/src/chain/calldata.js";
import { prepareSubmission } from "../../../client/src/chain/submission.js";
import { loadBatch } from "../src/fixture.js";

const prices: GasPrices = {
  l1GasPriceFri: 92_599_658_875_965n,
  l1DataGasPriceFri: 37_485_578_886n,
  l2GasPriceFri: 30_475_398_907n,
  blockNumber: 7, timestamp: 1_789_000_000, starknetVersion: "0.14.4",
};
const sender = "0x1001";
const loaded = loadBatch(join(import.meta.dirname,
  "../../../cairo/doom_contracts/crates/recursion_outputs/fixtures/B2-1_doom"));
const prepared = prepareSubmission({
  batch: loaded.batch, router: "0x2002", doomRuns: "0x3003",
  versionId: loaded.versionId, proofId: 1n,
  players: Object.fromEntries(loaded.batch.placements.map((p) => [p.runId, sender])),
  levelIds: loaded.levelIds,
});
const seq = prepared.sequence;
const echoAfter = (i: number): string[] => Array.from(
  { length: i < 2 ? 228 : 576 }, (_, j) => "0x" + (i * 1000 + j + 1).toString(16),
);

function mockSimulation(from: number, rejectFirst = false) {
  const simulate = vi.fn(async (txs: Record<string, any>[], flags: string[]) => {
    if (rejectFirst && flags.length === 1) throw new Error("fee balance insufficient");
    for (const [i, tx] of txs.entries()) {
      const index = from + i;
      expect(tx.sender_address).toBe(sender);
      expect(tx.nonce).toBe("0x" + (7 + i).toString(16));
      expect(tx.signature).toEqual([]);
      expect(tx.tip).toBe("0x0");
      expect(BigInt(tx.resource_bounds.l2_gas.max_amount)).toBe(INVOKE_L2_GAS_CAP);
      expect(BigInt(tx.resource_bounds.l2_gas.max_price_per_unit)).toBe(prices.l2GasPriceFri * 2n);
      const call = index < seq.phases.length ? {
        contractAddress: seq.router,
        entrypoint: seq.phases[index]!.entrypoint,
        calldata: phaseCalldata(seq.phases[index]!, index === 0 ? null : echoAfter(index - 1)),
      } : seq.consumer.call;
      expect(tx.calldata).toEqual(executeCalldata([call]));
    }
    // Synthetic RPC response for sequencing/bounds tests; no new gas measurement is implied.
    return txs.map((_, i) => ({
      transaction_trace: { execute_invocation: { calls: [{
        result: ["0x" + echoAfter(from + i).length.toString(16), ...echoAfter(from + i)],
      }] } },
      fee_estimation: {
        l1_gas_consumed: "0x0", l2_gas_consumed: "0x64",
        l1_data_gas_consumed: "0xa", overall_fee: "0x100",
      },
    }));
  });
  return {
    gasPrices: vi.fn(async () => prices), nonce: vi.fn(async () => 7n), simulate,
  };
}

describe("five-transaction fee simulation", () => {
  it("discovers echoes then simulates all five verifier transactions and the consumer together", async () => {
    const rpc = mockSimulation(0);
    const estimate = await simulateSequence(rpc as unknown as RpcClient, seq, { sender });
    expect(rpc.simulate.mock.calls.map(([txs]) => txs.length)).toEqual([1, 2, 3, 4, 6]);
    expect(rpc.simulate.mock.calls.every(([, flags]) => flags.join() === "SKIP_VALIDATE")).toBe(true);
    expect(estimate.steps.map((s) => s.label)).toEqual([
      "begin", "merkle", "answers", "fri1", "fri2", "submit_batch",
    ]);
    expect(estimate.echoes[4]).toEqual(echoAfter(3));
    expect(estimate.bounds.every((b) => b.l2GasBound === 115n && b.l1DataGasBound === 13n)).toBe(true);
  });

  it("simulates only the unpaid suffix with the resumed echo and unchanged bounds", async () => {
    const rpc = mockSimulation(4);
    const estimate = await simulateSequence(rpc as unknown as RpcClient, seq, {
      sender, fromPhase: 4, echoes: [null, null, null, null, echoAfter(3)],
    });
    expect(rpc.simulate.mock.calls.map(([txs]) => txs.length)).toEqual([2]);
    expect(estimate.steps.map((s) => s.label)).toEqual(["fri2", "submit_batch"]);
    expect(estimate.steps[0]!.index).toBe(4);
  });

  it("keeps fee-charge fallback unsigned and retains the ordered prefix walk", async () => {
    const rpc = mockSimulation(0, true);
    const estimate = await simulateSequence(rpc as unknown as RpcClient, seq, { sender, verifierOnly: true });
    expect(estimate.simulationFlags).toEqual(["SKIP_VALIDATE", "SKIP_FEE_CHARGE"]);
    expect(rpc.simulate.mock.calls.map(([txs]) => txs.length)).toEqual([1, 1, 2, 3, 4, 5]);
    expect(estimate.steps).toHaveLength(5);
  });
});

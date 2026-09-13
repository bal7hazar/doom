// SPDX-License-Identifier: Apache-2.0
/**
 * The integration test: the real orchestrator against a real router on a real (local) devnet.
 *
 * Skipped — not failed — when `SUBMIT_TEST_RPC` is unset or nothing answers there, so a clone
 * with no devnet still has a green `npm test`. To run it:
 *
 *   starknet-devnet --seed 42 --port 5081 …            (see README.md)
 *   scripts/devnet_setup.sh .work/accounts.json http://127.0.0.1:5081/rpc .work/deployment.json
 *   SUBMIT_TEST_RPC=http://127.0.0.1:5081/rpc \
 *   SUBMIT_TEST_ROUTER=<router> SUBMIT_TEST_RUNS=<doom_runs> \
 *   SUBMIT_TEST_ACCOUNT=<addr>:<key> npx vitest run test/devnet.test.ts
 *
 * What it pins is the property the whole lane exists for: the estimate of the ordered sequence
 * is within C5's 20 % of what the receipts bill, and the fact the router registers from the
 * TypeScript calldata is the one P4.2b recorded for the same batch.
 */

import { join } from "node:path";
import { beforeAll, describe, expect, it } from "vitest";

import { RpcClient } from "../../../client/src/chain/rpc.js";
import { priceEstimate, simulateSequence, withPrices } from "../../../client/src/chain/estimate.js";
import { resumePoint, runSequence } from "../../../client/src/chain/sequence.js";
import { prepareSubmission } from "../../../client/src/chain/submission.js";
import { StaticPriceSource, S5_SNAPSHOT } from "../../../client/src/chain/prices.js";
import { DevnetSigner } from "../src/devnetSigner.js";
import { loadBatch } from "../src/fixture.js";

const RPC = process.env["SUBMIT_TEST_RPC"];
const ROUTER = process.env["SUBMIT_TEST_ROUTER"];
const RUNS = process.env["SUBMIT_TEST_RUNS"];
const ACCOUNT = process.env["SUBMIT_TEST_ACCOUNT"];
/** The fact `results/e2e_10felt_receipts.json` recorded for `B2-1_doom` in P4.2b. */
const EXPECTED_FACT = "0x53ae959ad8221763147edc9660adf753b1fa6423cd353914e304a00a98c3c40";
const FIXTURE = join(
  import.meta.dirname,
  "../../../cairo/doom_contracts/crates/recursion_outputs/fixtures/B2-1_doom",
);

let reachable = false;
beforeAll(async () => {
  if (!RPC || !ROUTER || !RUNS || !ACCOUNT) return;
  try {
    await new RpcClient(RPC, { timeoutMs: 3_000 }).specVersion();
    reachable = true;
  } catch {
    reachable = false;
  }
});

describe.runIf(RPC && ROUTER && RUNS && ACCOUNT)("devnet", () => {
  it("verifies a real root proof and records its games, within C5", async () => {
    if (!reachable) {
      console.warn(`skipping: nothing answers on ${RPC}`);
      return;
    }
    const [address, key] = ACCOUNT!.split(":");
    const rpc = new RpcClient(RPC!);
    const loaded = loadBatch(FIXTURE);
    // A proof id nobody used yet: the router's slots are per (caller, proof_id) and write-once.
    const proofId = BigInt(Date.now()) % 1_000_000n;

    const prepared = prepareSubmission({
      batch: loaded.batch,
      router: ROUTER!,
      doomRuns: RUNS!,
      versionId: loaded.versionId,
      proofId,
      players: Object.fromEntries(loaded.batch.placements.map((p) => [p.runId, address!])),
      levelIds: loaded.levelIds,
      replay: true,
    });
    expect(prepared.phases).toHaveLength(6);

    const resume = await resumePoint(rpc, prepared.sequence, address!);
    expect(resume.nextPhase).toBe(0);

    const est = await simulateSequence(rpc, prepared.sequence, { sender: address! });
    const bounds = withPrices(est.bounds, est.prices);
    for (const b of bounds) expect(b.overCap).toBe(false);

    const priced = priceEstimate(est, await new StaticPriceSource(S5_SNAPSHOT).quote());
    expect(priced.totalStrk).toBeGreaterThan(0);
    expect(priced.totalUsd).toBeGreaterThan(0);

    const result = await runSequence(rpc, prepared.sequence, {
      signer: new DevnetSigner(RPC!, address!, key!),
      bounds: bounds.map((b) => b.bounds),
    });
    expect(result.fact).toBe(EXPECTED_FACT);

    const accepted = result.steps.filter((s) => s.state === "accepted");
    expect(accepted).toHaveLength(7);
    for (const step of accepted) {
      const e = est.steps.find((s) => s.label === step.label)!;
      const gap = Math.abs(Number(e.estimate.l2GasConsumed - step.l2Gas!)) / Number(step.l2Gas!);
      expect(gap).toBeLessThan(0.2); // C5
    }
    const actual = accepted.reduce((a, s) => a + s.l2Gas!, 0n);
    expect(Math.abs(Number(est.totalL2Gas - actual)) / Number(actual)).toBeLessThan(0.002);

    // Re-running the same proof id must cost nothing: everything is already on chain.
    const again = await resumePoint(rpc, prepared.sequence, address!);
    expect(again.factRegistered).toBe(true);
    expect(again.nextPhase).toBe(prepared.phases.length);
  }, 600_000);
});

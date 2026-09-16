// SPDX-License-Identifier: Apache-2.0
/** The fold through a fake wrapper, the D28 registration with a mocked node and signer, and
 * the node signer's handling of its key. Not one byte leaves this process. */
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { ResourceBounds } from "../../../client/src/chain/rpc.js";
import { storedFriSplit, TAG } from "../../../client/src/chain/sequence.js";
import { normalizeFelt } from "../../../client/src/prove/felt.js";
import { decodeSegmentOutput } from "../../../client/src/prove/program.js";
import { FileEchoStore } from "../../submit/src/stores.js";
import { wrapperRunId } from "../src/commitments.js";
import { checkOwnLeaves, foldRun } from "../src/fold.js";
import { assertNotMainnet, ENV_ADDRESS, ENV_PRIVATE_KEY, NodeSigner } from "../src/nodeSigner.js";
import type { ProofArtifact } from "../src/prover.js";
import { registerRun } from "../src/register.js";
import type { PlannedSegment } from "../src/segmenter.js";
import { newJob, type JobRecord } from "../src/store.js";
import { fakeCommitment, FIXTURE_DIR, fixtureGenesis, fixtureJournal, fixtureLeaf, fixturePlan } from "./fixtures.js";
import { bound, fakeWrapper, mockRpc } from "./wrapper.js";

const PROGRAM_HASH = "0x" + BigInt(JSON.parse(readFileSync(join(FIXTURE_DIR, "preimage_0.json"), "utf8"))[0]).toString(16);
const dirs: string[] = [];
afterEach(() => dirs.splice(0).forEach((d) => rmSync(d, { recursive: true, force: true })));
const scratch = (): string => {
  const d = mkdtempSync(join(tmpdir(), "prover-node-reg-"));
  dirs.push(d);
  return d;
};

/** A job whose segments are the proved fixture's own game 0 (two leaves, EXIT). */
function fixtureJob(): { job: JobRecord; artifacts: ProofArtifact[] } {
  const words = fixtureJournal(0);
  const job = newJob(fakeCommitment(words));
  job.segments = [0, 1].map((i): PlannedSegment => {
    const leaf = fixtureLeaf(0, i);
    const outputFelts = fixturePlan().leaves.find((l) => l.game === 0 && l.segment === i)!.output.map((v) => normalizeFelt("0x" + BigInt(v).toString(16)));
    return {
      index: i, ticStart: leaf.ticStart, ticEnd: leaf.ticEnd, args: ["0x2f", "0x" + i.toString(16)], outputFelts,
      output: decodeSegmentOutput(outputFelts), packed: leaf.packed, nSteps: 1, probes: 1,
      resources: { maxComponent: "fixture", utilisation: 0, stepUtilisation: 0, fitsLeafRegistry: true, rowsChecked: false },
      executeMs: 0,
    };
  });
  job.stage = "proved";
  const artifacts = job.segments.map((s): ProofArtifact => ({
    index: s.index, format: "bincode_b64", data: Buffer.from(`proof-${s.index}`).toString("base64"),
    outputPreimage: [PROGRAM_HASH, ...s.outputFelts], programHash: PROGRAM_HASH, proveMs: 1,
  }));
  return { job, artifacts };
}

describe("the fold through the wrapper", () => {
  it("uploads every segment, completes, waits, fetches the root and checks its own leaves", async () => {
    const { job, artifacts } = fixtureJob();
    const runId = wrapperRunId(job.commitment.commitmentId);
    const w = fakeWrapper(runId);
    const log: string[] = [];
    const result = await foldRun({ client: w.client, job, artifacts, pollMs: 1, log: (m) => log.push(m) });
    expect(result.batchId).toBe("B2-1_doom");
    expect(w.calls.filter((c) => c.startsWith("PUT")).length).toBe(2);
    expect(w.calls).toContain(`POST /v1/runs/${runId}/complete`);
    expect(w.calls[w.calls.length - 1]).toBe("GET /v1/batches/B2-1_doom?include=proof");
    expect(result.batch.rootProofFelts!.length).toBeGreaterThan(10_000);
    expect(result.batch.logs!.map((l) => l.length)).toEqual([23, 20, 0]);
    expect(result.batch.logs![0]).toEqual(job.segments![0]!.packed.map(BigInt));
    expect(normalizeFelt("0x" + result.batch.programHash.toString(16))).toBe(PROGRAM_HASH);
    expect((w.held.get(1) as { args: string[]; output_preimage: string[]; proof: { format: string } }).proof.format).toBe("bincode_b64");
    expect(job.wrapper).toMatchObject({ runId, batchId: "B2-1_doom", status: "done" });
    expect(log.some((m) => /uploaded/.test(m))).toBe(true);
  });

  it("resumes an interrupted upload from what the server holds", async () => {
    const { job, artifacts } = fixtureJob();
    const w = fakeWrapper(wrapperRunId(job.commitment.commitmentId), { held: [0] });
    await foldRun({ client: w.client, job, artifacts, pollMs: 1 });
    expect(w.calls.filter((c) => c.startsWith("PUT"))).toEqual([`PUT /v1/runs/${wrapperRunId(job.commitment.commitmentId)}/segments/1`]);
  });

  it("refuses to pay for a batch whose leaves at its positions are not what it executed", async () => {
    const { job, artifacts } = fixtureJob();
    const w = fakeWrapper(wrapperRunId(job.commitment.commitmentId), { swapLeaves: true });
    await expect(foldRun({ client: w.client, job, artifacts, pollMs: 1 })).rejects.toThrow(/differs from the executed ten felts/);
    const { job: ok } = fixtureJob();
    const good = fakeWrapper(wrapperRunId(ok.commitment.commitmentId));
    const result = await foldRun({ client: good.client, job: ok, artifacts, pollMs: 1 });
    ok.segments![1]!.outputFelts[2] = "0x1";
    expect(() => checkOwnLeaves(result.batch, result.response, result.runId, ok.segments!)).toThrow(/differs from the executed ten felts/);
  });
});

async function foldedFixture() {
  const { job, artifacts } = fixtureJob();
  const runId = wrapperRunId(job.commitment.commitmentId);
  const w = fakeWrapper(runId);
  const { batch } = await foldRun({ client: w.client, job, artifacts, pollMs: 1 });
  return { job, runId, batch };
}

describe("registration (D28) with a mocked signer", () => {
  it("plays five verifier transactions then register_member with the replay, and sees the bounty settle", async () => {
    const { job, runId, batch } = await foldedFixture();
    const sent: { entrypoint: string; calldata: string[]; bounds: ResourceBounds }[] = [];
    const signer = {
      kind: "test", address: "0x123",
      execute: vi.fn(async (calls: { entrypoint: string; calldata: string[] }[], o: { bounds: ResourceBounds }) => {
        sent.push({ ...calls[0]!, bounds: o.bounds });
        return { transactionHash: "0x" + (sent.length * 16).toString(16) };
      }),
    };
    const rpc = mockRpc({ tag: TAG.FREE, settles: { commitmentId: job.commitment.commitmentId, prover: "0x123" } });
    const echoStore = new FileEchoStore(join(scratch(), "echoes.json"));
    const estimate = vi.fn(async (_a: unknown, prepared: { phases: unknown[] }) => ({ prepared: prepared as never, bounds: new Array(prepared.phases.length + 1).fill(bound), totalStrk: 1.5 }));
    const result = await registerRun({
      rpc, signer, batch, job, runId, router: "0x456", doomRuns: "0x789", echoStore, estimate,
      replay: false, // ignored: two segments need their logs on chain for the bounty
    });

    expect(sent.map((s) => s.entrypoint)).toEqual(["begin", "merkle", "answers", "fri", "fri", "register_member"]);
    expect(result).toMatchObject({ fact: "0xfac7", onChainRunId: "0x7777", alreadyRegistered: false, resumedAt: 0 });
    expect(result.transactions.map((t) => t.label)).toEqual(["begin", "merkle", "answers", "fri1", "fri2", "submit_batch"]);
    expect(result.member).toMatchObject({ player: job.commitment.player, levelId: 1, leafStart: 0, leafLen: 2, runId });

    // register_member(version_id, leaves[3], member, replay[2]) — the member is the player, not the node.
    const consumer = sent[5]!.calldata;
    expect(consumer[0]).toBe("0x1");
    expect(consumer[1]).toBe("0x3");
    const memberAt = 2 + 30;
    expect(consumer.slice(memberAt, memberAt + 4)).toEqual([job.commitment.player, "0x1", "0x0", "0x2"]);
    expect(consumer[memberAt + 4]).toBe("0x2");
    expect(consumer[memberAt + 5]).toBe("0x0"); // replay leaf 0
    expect(consumer[memberAt + 6]).toBe("0x17"); // 23 felts
    expect(consumer.slice(memberAt + 7, memberAt + 7 + 23)).toEqual(fixtureLeaf(0, 0).packed);
    expect(result.settlement).toMatchObject({ prover: "0x123", runId: "0x7777", bounty: job.commitment.bounty });
    expect(job.chain).toMatchObject({ proofId: job.commitment.commitmentId, fact: "0xfac7", settled: true });
    expect(job.chain!.transactions).toHaveLength(6);
    expect(storedFriSplit(echoStore, BigInt(job.commitment.commitmentId), "0x456", "0x123")).toEqual([2]);
    expect(estimate).toHaveBeenCalledTimes(1);
    expect(estimate.mock.calls[0]![0]).toMatchObject({ singleMember: result.member, replay: true, proofId: BigInt(job.commitment.commitmentId) });
  });

  it("resumes from the router's checkpoint and skips a run already recorded (R10-A1)", async () => {
    const { job, runId, batch } = await foldedFixture();
    const sent: string[] = [];
    const signer = { kind: "test", address: "0x123", execute: vi.fn(async (calls: { entrypoint: string }[]) => { sent.push(calls[0]!.entrypoint); return { transactionHash: "0x9" }; }) };
    const echoStore = new FileEchoStore(join(scratch(), "echoes.json"));
    const common = { signer, batch, job, runId, router: "0x456", doomRuns: "0x789", echoStore };

    // A first attempt loses the connection right after its first send: the plan is on disk.
    const lost = { kind: "test", address: "0x123", execute: vi.fn(async () => { throw new Error("connection lost after send"); }) };
    await expect(registerRun({
      ...common, signer: lost, rpc: mockRpc({ tag: TAG.FREE }),
      estimate: async (_a, prepared) => ({ prepared, bounds: new Array(prepared.phases.length + 1).fill(bound) }),
    })).rejects.toThrow(/connection lost/);
    expect(storedFriSplit(echoStore, BigInt(job.commitment.commitmentId), "0x456", "0x123")).toEqual([2]);

    // Four phases paid for already, the echo comes from the trace.
    const partial = await registerRun({
      ...common, rpc: mockRpc({ tag: TAG.FRI, steps: 4 }),
      estimate: async (_a, prepared, resume) => ({ prepared, bounds: new Array(prepared.phases.length + 1 - resume.nextPhase).fill(bound) }),
    });
    expect(partial.resumedAt).toBe(4);
    expect(sent).toEqual(["fri", "register_member"]);
    expect(partial.settlement).toBeNull(); // this mocked node paid nothing
    expect(job.chain!.settled).toBe(false);

    // The fact is done and the run recorded: nothing is sent, the settlement is read on chain.
    sent.length = 0;
    const done = await registerRun({
      ...common, rpc: mockRpc({ tag: TAG.DONE, registered: true, commitment: { status: 2, prover: "0x123" } }),
      estimate: async (_a, prepared) => ({ prepared, bounds: [bound] }),
    });
    expect(done.alreadyRegistered).toBe(true);
    expect(sent).toEqual([]);
    expect(done.transactions).toEqual([]);
    expect(done.settlement).toEqual({ runId: "0x7777", prover: "0x123" });

    // Somebody else proved it, or the player reclaimed it: nothing is paid for.
    for (const commitment of [{ status: 2, prover: "0x999" }, { status: 3 }, { status: 0 }, { status: 1, tics: 5 }]) {
      await expect(registerRun({ ...common, rpc: mockRpc({ tag: TAG.FREE, commitment }), estimate: async () => { throw new Error("must not estimate"); } }))
        .rejects.toThrow(/already proved by 0x999|reclaimed|does not exist|differs from the one discovered/);
    }

    // A batch the contract would reject is refused before anything is estimated.
    const broken = structuredClone(batch);
    broken.leaves[1]!.h_in = 5n;
    await expect(registerRun({ ...common, rpc: mockRpc({ tag: TAG.FREE }), batch: broken, estimate: async () => { throw new Error("must not estimate"); } }))
      .rejects.toThrow(/chain break/);
  });
});

describe("the node signer", () => {
  it("reads its key from the environment and never shows it", async () => {
    expect(() => NodeSigner.fromEnv("http://127.0.0.1:5050", {})).toThrow(new RegExp(`${ENV_ADDRESS} and ${ENV_PRIVATE_KEY}`));
    expect(() => NodeSigner.fromEnv("http://127.0.0.1:5050", { [ENV_ADDRESS]: "0x1", [ENV_PRIVATE_KEY]: "hunter2" })).toThrow(/not a hex felt/);
    const key = "0xdeadbeefcafe";
    const account = { execute: vi.fn(async (_calls: unknown, _details?: unknown) => ({ transaction_hash: "0xaa" })) };
    const signer = NodeSigner.fromEnv("http://127.0.0.1:5050", { [ENV_ADDRESS]: "0x1", [ENV_PRIVATE_KEY]: key }, account);
    for (const text of [JSON.stringify(signer), String(signer), `${signer}`]) expect(text).not.toContain("deadbeef");
    expect(JSON.stringify(signer)).toBe('{"kind":"node","address":"0x1"}');
    const r = await signer.execute([{ contractAddress: "0x2", entrypoint: "claim_bounty", calldata: ["0x3"] }], { bounds: bound });
    expect(r.transactionHash).toBe("0xaa");
    expect(account.execute.mock.calls[0]![1]).toMatchObject({ version: 3, tip: 0n, resourceBounds: { l2_gas: { max_amount: 0x20000000n } } });
    expect(await signer.classHash()).toBeUndefined();
  });

  it("refuses mainnet and accepts devnet or Sepolia", async () => {
    await expect(assertNotMainnet({ chainId: async () => "0x534e5f4d41494e" })).rejects.toThrow(/mainnet/);
    expect(await assertNotMainnet({ chainId: async () => "0x534e5f5345504f4c4941" })).toBe("0x534e5f5345504f4c4941");
    expect(fixtureGenesis()).toMatch(/^0x/);
  });
});

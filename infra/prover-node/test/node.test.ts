// SPDX-License-Identifier: Apache-2.0
/** The whole node on fakes: discovery, policy, reconstruction, cut, proofs, fold, registration,
 * with interruptions, refusals, a lost race and the metrics that report them. */
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { TAG } from "../../../client/src/chain/sequence.js";
import { FileEchoStore } from "../../submit/src/stores.js";
import { wrapperRunId, type RunCommitment } from "../src/commitments.js";
import { FileDiscoveryStore } from "../src/discovery.js";
import { FakeExecutor } from "../src/executor.js";
import { Logbook } from "../src/log.js";
import { MetricsFile } from "../src/metrics.js";
import { describeJob, ProverNode, type NodeConfig } from "../src/node.js";
import { DEFAULT_POLICY } from "../src/policy.js";
import { FakeProver, type FakeProverOptions } from "../src/prover.js";
import { FileJobStore } from "../src/store.js";
import { commitmentEvents, fakeCommitment, FakeEventSource, fixtureJournal, provedEvent } from "./fixtures.js";
import { fakeWrapper, fixedEstimate, mockRpc } from "./wrapper.js";

const words = fixtureJournal(0);
const dirs: string[] = [];
afterEach(() => dirs.splice(0).forEach((d) => rmSync(d, { recursive: true, force: true })));

async function harness(options: {
  commitments?: (genesis: string) => RunCommitment[];
  prover?: FakeProverOptions;
  config?: Partial<NodeConfig>;
  tag?: number;
} = {}) {
  const work = mkdtempSync(join(tmpdir(), "prover-node-e2e-"));
  dirs.push(work);
  const executor = new FakeExecutor({ terminal: { tic: 297, status: 2 } });
  const genesis = (await executor.genesis(1)).hash;
  const commitments = options.commitments?.(genesis) ?? [fakeCommitment(words, { genesis, blockNumber: 3 })];
  const source = new FakeEventSource(commitments.flatMap((c) => commitmentEvents(c)), 20);
  const prover = new FakeProver(options.prover);
  const wrapper = fakeWrapper(wrapperRunId(commitments[0]!.commitmentId), { batch: "uploads" });
  const sent: string[] = [];
  const signer = {
    kind: "test", address: "0x123",
    execute: vi.fn(async (calls: { entrypoint: string }[]) => { sent.push(calls[0]!.entrypoint); return { transactionHash: "0x" + (sent.length * 16).toString(16) }; }),
  };
  const lines: string[] = [];
  const node = new ProverNode(
    { doomRuns: "0xd00d", router: "0x456", startBlock: 0, policy: { ...DEFAULT_POLICY, minBounty: 10n ** 18n }, ...options.config },
    { source, executor, prover, wrapper: wrapper.client, rpc: mockRpc({ tag: options.tag ?? TAG.FREE, settles: { commitmentId: commitments[0]!.commitmentId, prover: "0x123" }, commitment: { status: 1, genesis: commitments[0]!.genesis, tics: commitments[0]!.tics, player: commitments[0]!.player } }), signer, echoStore: new FileEchoStore(join(work, "echoes.json")), estimate: fixedEstimate },
    { jobs: new FileJobStore(work), discovery: new FileDiscoveryStore(join(work, "discovery.json")), metrics: new MetricsFile(join(work, "metrics.json")), log: new Logbook(join(work, "logbook.txt"), (l) => lines.push(l)) },
  );
  return { work, node, executor, prover, wrapper, signer, sent, lines, commitments, genesis, source };
}

describe("the prover node end to end", () => {
  it("takes a commitment from its events to the settled bounty in one poll", async () => {
    // Same journal, another player: on the contract the id is derived from (version, level,
    // player, commitment), so the same player committing the same journal twice is one id.
    const h = await harness({ commitments: (g) => [fakeCommitment(words, { genesis: g, blockNumber: 3 }), fakeCommitment(words, { genesis: g, player: "0x2", bounty: 1n, blockNumber: 4 })] });
    const out = await h.node.pollOnce();
    expect(out.selection.selected.map((c) => c.commitmentId)).toEqual([h.commitments[0]!.commitmentId]);
    expect(out.selection.skipped).toEqual([{ commitmentId: h.commitments[1]!.commitmentId, reason: expect.stringMatching(/below/) }]);
    expect(out.processed).toHaveLength(1);
    const job = out.processed[0]!;
    expect(job.stage).toBe("registered");
    expect(job.error).toBeUndefined();
    const n = job.segments!.length;
    expect(n).toBeGreaterThan(3);
    expect(h.prover.calls).toEqual(Array.from({ length: n }, (_, i) => i));
    expect(h.wrapper.calls.filter((c) => c.startsWith("PUT"))).toHaveLength(n);
    expect(h.sent).toEqual(["begin", "merkle", "answers", "fri", "fri", "register_member"]);
    expect(job.chain).toMatchObject({ proofId: job.commitment.commitmentId, fact: "0xfac7", settled: true });
    for (const s of job.segments!.slice(0, -1)) expect((s.ticEnd - s.ticStart) % 7).toBe(0);
    expect(job.wrapper).toMatchObject({ batchId: "B2-1_doom", status: "done" });
    expect(Object.keys(job.timings)).toEqual(["reconstructed", "cut", "proved", "folded", "registered"]);

    const metrics = JSON.parse(readFileSync(join(h.work, "metrics.json"), "utf8"));
    expect(metrics).toMatchObject({ polls: 1, commitmentsSeen: 8, selected: 1, skipped: 1, registered: 1, unsettled: 0, segmentsCut: n, segmentsProved: n, proofFailures: 0, refused: 0, failed: 0, bountyClaimedFri: job.commitment.bounty.toString() });
    expect(Object.keys(metrics.stages)).toEqual(["reconstructed", "cut", "proved", "folded", "registered"]);
    expect(metrics.stages.proved.count).toBe(1);
    expect(readFileSync(join(h.work, "logbook.txt"), "utf8")).toMatch(/registered: run 0x7777, fact 0xfac7, bounty settled/);
    expect(h.lines.some((l) => /selected: 297 tics/.test(l))).toBe(true);
    expect(describeJob(job)).toMatch(/registered .* 297 tics .* fact 0xfac7/);

    // The next poll finds nothing to do: the job is terminal, the cheap one still too cheap.
    const again = await h.node.pollOnce();
    expect(again.processed).toEqual([]);
    expect(again.selection.skipped.map((s) => s.reason)).toEqual(["already handled", expect.stringMatching(/below/)]);
    expect(h.prover.calls).toHaveLength(n);
    expect(JSON.parse(readFileSync(join(h.work, "discovery.json"), "utf8")).lastBlock).toBe(20);
  });

  it("resumes an interrupted job on the next poll without re-proving what is on disk", async () => {
    const h = await harness({ prover: { failOnce: [1] } });
    const first = await h.node.pollOnce();
    const job = first.processed[0]!;
    expect(job).toMatchObject({ stage: "proving", attempts: 1, proved: [0], error: expect.stringMatching(/segment 1: fake prover failed once/) });
    expect(h.sent).toEqual([]);
    expect(JSON.parse(readFileSync(join(h.work, "metrics.json"), "utf8"))).toMatchObject({ proofFailures: 1, segmentsProved: 1, registered: 0 });

    const second = await h.node.pollOnce();
    expect(second.selection.selected).toEqual([]);
    expect(second.processed[0]).toMatchObject({ stage: "registered", attempts: 1 });
    const n = second.processed[0]!.segments!.length;
    expect(h.prover.calls).toEqual([0, 1, ...Array.from({ length: n - 1 }, (_, i) => i + 1)]);
    expect(h.sent).toEqual(["begin", "merkle", "answers", "fri", "fri", "register_member"]);
    expect(JSON.parse(readFileSync(join(h.work, "metrics.json"), "utf8"))).toMatchObject({ segmentsProved: n, registered: 1 });
  });

  it("stops after the requested stage and picks up from there on a later run", async () => {
    const h = await harness({ config: { stopAfter: "cut" } });
    const job = (await h.node.pollOnce()).processed[0]!;
    expect(job.stage).toBe("cut");
    expect(h.prover.calls).toEqual([]);
    expect(existsSync(join(h.work, "jobs", job.commitment.commitmentId, "job.json"))).toBe(true);
    // A second node over the same work directory continues: it resumes the pending job first.
    const resumed = new ProverNode({ ...h.node.config, stopAfter: "folded" }, h.node.deps, h.node.stores);
    const folded = (await resumed.pollOnce()).processed[0]!;
    expect(folded.stage).toBe("folded");
    expect(h.sent).toEqual([]);
    expect(existsSync(join(h.work, "jobs", job.commitment.commitmentId, "batch.json"))).toBe(true);
    const full = new ProverNode({ ...h.node.config, stopAfter: undefined }, h.node.deps, h.node.stores);
    expect((await full.pollOnce()).processed[0]!.stage).toBe("registered");
    expect(h.wrapper.calls.filter((c) => c.startsWith("PUT")).length).toBe(job.segments!.length); // no second upload
    expect(h.sent).toHaveLength(6);
  });

  it("refuses invalid commitments for good and gives up on a hopeless one after maxAttempts", async () => {
    const h = await harness({
      commitments: (g) => {
        const tampered = fakeCommitment(words, { genesis: g, blockNumber: 3 });
        tampered.journal[0] = "0x1";
        const foreign = fakeCommitment(words, { genesis: "0x99", player: "0x2", blockNumber: 4 });
        const unfinished = fakeCommitment(words.slice(0, 100), { genesis: g, blockNumber: 5 });
        const expired = fakeCommitment(words, { genesis: g, player: "0x3", blockNumber: 6, expiresAt: 15 });
        return [tampered, foreign, unfinished, expired];
      },
    });
    const out = await h.node.pollOnce();
    // Processed in policy order: the shortest journal has the best bounty per tic.
    expect(out.processed.map((j) => [j.stage, j.error])).toEqual([
      ["refused", expect.stringMatching(/still RUNNING/)],
      ["refused", expect.stringMatching(/differs from inputs_commitment/)],
      ["refused", expect.stringMatching(/genesis/)],
    ]);
    expect(out.discovery.open.map((c) => c.expiresAt)).toEqual([1000, 1000, 1000]); // the expired one is not even open
    expect(h.prover.calls).toEqual([]);
    expect(JSON.parse(readFileSync(join(h.work, "metrics.json"), "utf8"))).toMatchObject({ refused: 3, selected: 3 });

    const hopeless = await harness({ prover: { failAlways: [0] }, config: { maxAttempts: 2 } });
    expect((await hopeless.node.pollOnce()).processed[0]).toMatchObject({ stage: "proving", attempts: 1 });
    expect((await hopeless.node.pollOnce()).processed[0]).toMatchObject({ stage: "failed", attempts: 2 });
    expect((await hopeless.node.pollOnce()).processed).toEqual([]);
    expect(JSON.parse(readFileSync(join(hopeless.work, "metrics.json"), "utf8"))).toMatchObject({ failed: 1, proofFailures: 2 });
  });

  it("drops a pending job whose commitment another prover settled meanwhile", async () => {
    const h = await harness({ config: { stopAfter: "proved" } });
    const job = (await h.node.pollOnce()).processed[0]!;
    expect(job.stage).toBe("proved");
    h.source.events.push(provedEvent({ commitmentId: job.commitment.commitmentId, prover: "0x07e4", runId: "0x5", block: 21 }));
    h.source.head = 21;
    const full = new ProverNode({ ...h.node.config, stopAfter: undefined }, h.node.deps, h.node.stores);
    const out = await full.pollOnce();
    expect(out.processed).toEqual([]);
    expect(out.discovery.open).toEqual([]);
    expect(h.node.stores.jobs.get(job.commitment.commitmentId)).toMatchObject({ stage: "failed", error: expect.stringMatching(/proved by 0x7e4 \(run 0x5\)/) });
    expect(JSON.parse(readFileSync(join(h.work, "metrics.json"), "utf8")).lostRace).toBe(1);
    expect(h.sent).toEqual([]);
  });

  it("watches: polls until aborted and survives a failing poll", async () => {
    const h = await harness();
    const broken = new ProverNode(h.node.config, { ...h.node.deps, source: { blockNumber: async () => { throw new Error("rpc down"); }, getEvents: async () => ({ events: [] }) } }, h.node.stores);
    const abort = new AbortController();
    setTimeout(() => abort.abort(), 60);
    await broken.watch(10, abort.signal);
    expect(h.lines.filter((l) => /poll failed: rpc down/.test(l)).length).toBeGreaterThan(1);
  });
});

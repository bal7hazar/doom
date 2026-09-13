import "fake-indexeddb/auto";
import { IDBFactory } from "fake-indexeddb";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  HELLPROOF_MAGIC,
  exportFileName,
  exportRun,
  importRun,
  parseHellproofFile,
} from "../src/store/hellproofFile.js";
import { PROOF_BYTES_ESTIMATE, isQuotaExceeded, projectQuota } from "../src/store/quota.js";
import { RunStore } from "../src/store/runStore.js";
import { packLog } from "../src/prove/ticcmd.js";
import type { SegmentRecord } from "../src/prove/types.js";

let store: RunStore;
let dbName: string;
let counter = 0;

beforeEach(async () => {
  // A fresh backing store per test: fake-indexeddb keeps state in the module.
  globalThis.indexedDB = new IDBFactory();
  dbName = `hellproof-test-${counter++}`;
  store = await RunStore.open(dbName);
});

afterEach(() => {
  store.close();
});

function segment(runId: string, index: number, over: Partial<SegmentRecord> = {}): SegmentRecord {
  const ticStart = index * 10;
  return {
    runId,
    index,
    ticStart,
    ticEnd: ticStart + 10,
    args: ["0x1", `0x${ticStart.toString(16)}`, "0xa"],
    outputPreimage: [
      "0xdead",
      "0x1",
      `0x${(index + 1).toString(16)}`,
      `0x${(index + 2).toString(16)}`,
      `0x${ticStart.toString(16)}`,
      `0x${(ticStart + 10).toString(16)}`,
      "0x0",
      "0xc0",
      "0x0",
      "0x0",
      "0x0",
    ],
    publicOutputs: ["0xaaaa", "0xbbbb"],
    output: {
      version: 1,
      hIn: `0x${(index + 1).toString(16)}`,
      hOut: `0x${(index + 2).toString(16)}`,
      ticStart,
      ticEnd: ticStart + 10,
      status: 0,
      inputsCommitment: "0xc0",
      kills: 0,
      items: 0,
      secrets: 0,
    },
    stage: "proved",
    proofBytes: 0,
    verified: true,
    attempts: 1,
    threads: 4,
    retriedSingleThread: false,
    timings: { proveMs: 11_700, verifyMs: 72 },
    memoryBytes: 3.15 * 2 ** 30,
    resources: {
      nSteps: 1_048_456,
      maxComponent: "memory_id_to_small",
      maxComponentRows: 524_288,
      logMaxComponentSize: 19,
      utilisation: 0.5,
      fitsLeafRegistry: true,
    },
    submission: "local",
    updatedAt: Date.now(),
    ...over,
  };
}

const proofOf = (index: number, size = 4096): Uint8Array =>
  Uint8Array.from({ length: size }, (_, i) => (i + index * 7) & 0xff);

describe("RunStore", () => {
  it("creates, reads back and lists runs", async () => {
    const run = await store.createRun({ program: "segment_stub10", programHashFunction: "poseidon", genesis: "0x1" });
    expect(await store.getRun(run.id)).toEqual(run);
    expect(await store.listRuns()).toHaveLength(1);
    expect((await store.getInputs(run.id)).ticCount).toBe(0);
  });

  it("round-trips the packed journal", async () => {
    const run = await store.createRun({ program: "p", programHashFunction: "blake", genesis: "0x1" });
    const words = Array.from({ length: 17 }, (_, i) => (i + 1) >>> 0);
    await store.putInputs({
      runId: run.id,
      ticCount: words.length,
      packed: packLog(words.slice(0, 14)),
      tail: words.slice(14),
    });
    const inputs = await store.getInputs(run.id);
    expect(inputs.ticCount).toBe(17);
    expect(inputs.packed).toHaveLength(2);
    expect(inputs.tail).toEqual([15, 16, 17]);
    // The run's own tic counter follows the journal.
    expect((await store.getRun(run.id))?.ticCount).toBe(17);
  });

  it("writes a segment and its proof in one transaction, and reads both back", async () => {
    const run = await store.createRun({ program: "p", programHashFunction: "blake", genesis: "0x1" });
    const proof = proofOf(0);
    await store.putSegment(segment(run.id, 0, { proofBytes: proof.byteLength }), proof);
    const stored = await store.getSegment(run.id, 0);
    expect(stored?.verified).toBe(true);
    expect(stored?.proofBytes).toBe(proof.byteLength);
    expect(await store.getProof(run.id, 0)).toEqual(proof);
    expect((await store.getRun(run.id))?.segments).toBe(1);
  });

  it("lists a run's segments in index order and only that run's", async () => {
    const a = await store.createRun({ program: "p", programHashFunction: "blake", genesis: "0x1" });
    const b = await store.createRun({ program: "p", programHashFunction: "blake", genesis: "0x1" });
    for (const index of [2, 0, 1]) await store.putSegment(segment(a.id, index));
    await store.putSegment(segment(b.id, 0));
    expect((await store.listSegments(a.id)).map((s) => s.index)).toEqual([0, 1, 2]);
    expect(await store.listSegments(b.id)).toHaveLength(1);
  });

  it("survives a reopen — the R1-A7 reload", async () => {
    const run = await store.createRun({ program: "p", programHashFunction: "blake", genesis: "0x1" });
    await store.putSegment(segment(run.id, 0, { proofBytes: 4096 }), proofOf(0));
    await store.putSegment(segment(run.id, 1, { stage: "proving", verified: false }));
    store.close();

    const reopened = await RunStore.open(dbName);
    const segments = await reopened.listSegments(run.id);
    expect(segments.map((s) => s.stage)).toEqual(["proved", "proving"]);
    expect((await reopened.getProof(run.id, 0))?.byteLength).toBe(4096);
    expect(await reopened.getProof(run.id, 1)).toBeUndefined();
    reopened.close();
    store = await RunStore.open(dbName);
  });

  it("merges submission state instead of replacing it", async () => {
    const run = await store.createRun({ program: "p", programHashFunction: "blake", genesis: "0x1" });
    await store.updateSubmission(run.id, { runId: "wrapper-1" });
    await store.updateSubmission(run.id, { batchId: "batch-9" });
    const after = await store.getRun(run.id);
    expect(after?.submission.runId).toBe("wrapper-1");
    expect(after?.submission.batchId).toBe("batch-9");
  });

  it("deleteRun wipes the run, its journal, its segments and its proofs (C6)", async () => {
    const run = await store.createRun({ program: "p", programHashFunction: "blake", genesis: "0x1" });
    await store.putInputs({ runId: run.id, ticCount: 7, packed: packLog([1, 2, 3, 4, 5, 6, 7]), tail: [] });
    await store.putSegment(segment(run.id, 0, { proofBytes: 4096 }), proofOf(0));
    await store.putSegment(segment(run.id, 1, { proofBytes: 4096 }), proofOf(1));

    await store.deleteRun(run.id);

    expect(await store.getRun(run.id)).toBeUndefined();
    expect(await store.listSegments(run.id)).toHaveLength(0);
    expect(await store.getProof(run.id, 0)).toBeUndefined();
    expect(await store.getProof(run.id, 1)).toBeUndefined();
    expect((await store.getInputs(run.id)).ticCount).toBe(0);
  });

  it("keeps a meta key/value store", async () => {
    await store.setMeta("wrapperUrl", "http://127.0.0.1:8787");
    expect(await store.getMeta<string>("wrapperUrl")).toBe("http://127.0.0.1:8787");
    expect(await store.getMeta("nope")).toBeUndefined();
  });
});

describe(".hellproof export / import", () => {
  async function seed(): Promise<{ runId: string; proofs: Uint8Array[] }> {
    const run = await store.createRun({
      program: "segment_stub10",
      programHashFunction: "poseidon",
      genesis: "0x1",
      keepOffline: true,
    });
    await store.putInputs({
      runId: run.id,
      ticCount: 20,
      packed: packLog(Array.from({ length: 14 }, (_, i) => i + 1)),
      tail: [15, 16, 17, 18, 19, 20],
    });
    const proofs = [proofOf(0, 5000), proofOf(1, 6000)];
    for (const [index, proof] of proofs.entries()) {
      await store.putSegment(segment(run.id, index, { proofBytes: proof.byteLength }), proof);
    }
    return { runId: run.id, proofs };
  }

  it("writes a container the parser reads back byte for byte", async () => {
    const { runId, proofs } = await seed();
    const bytes = await exportRun(store, runId);
    expect(new TextDecoder().decode(bytes.subarray(0, 9))).toBe(HELLPROOF_MAGIC);

    const parsed = parseHellproofFile(bytes);
    expect(parsed.manifest.run.id).toBe(runId);
    expect(parsed.manifest.segments).toHaveLength(2);
    expect(parsed.manifest.inputs.ticCount).toBe(20);
    expect(parsed.proofs.get(0)).toEqual(proofs[0]);
    expect(parsed.proofs.get(1)).toEqual(proofs[1]);
    // The payloads dominate; the manifest is small next to them.
    expect(bytes.byteLength).toBeGreaterThan(11_000);
  });

  it("imports into a clean database and restores everything", async () => {
    const { runId, proofs } = await seed();
    const bytes = await exportRun(store, runId);
    await store.deleteRun(runId);

    const result = await importRun(store, bytes);
    expect(result.renamed).toBe(false);
    expect(result.runId).toBe(runId);
    expect(result.segments).toBe(2);
    expect(result.proofs).toBe(2);

    const restored = await store.getRun(runId);
    expect(restored?.keepOffline).toBe(true);
    expect(restored?.program).toBe("segment_stub10");
    expect((await store.getInputs(runId)).tail).toEqual([15, 16, 17, 18, 19, 20]);
    const segments = await store.listSegments(runId);
    expect(segments.map((s) => s.ticEnd)).toEqual([10, 20]);
    expect(await store.getProof(runId, 1)).toEqual(proofs[1]);
  });

  it("renames on a collision rather than overwriting a local run", async () => {
    const { runId } = await seed();
    const bytes = await exportRun(store, runId);
    const result = await importRun(store, bytes);
    expect(result.renamed).toBe(true);
    expect(result.runId).not.toBe(runId);
    expect(await store.listRuns()).toHaveLength(2);
    // …or refuses outright when asked to.
    await expect(importRun(store, bytes, { renameOnConflict: false })).rejects.toThrow(/already exists/);
  });

  it("detects a corrupted proof through its checksum", async () => {
    const { runId } = await seed();
    const bytes = await exportRun(store, runId);
    await store.deleteRun(runId);
    // Flip a byte inside the payload region.
    const at = bytes.byteLength - 100;
    bytes[at] = (bytes[at] ?? 0) ^ 0xff;
    await expect(importRun(store, bytes)).rejects.toThrow(/corrupt/);
  });

  it("refuses anything that is not a container", async () => {
    expect(() => parseHellproofFile(new Uint8Array(8))).toThrow(/too short/);
    expect(() => parseHellproofFile(new Uint8Array(64))).toThrow(/bad magic/);
    const { runId } = await seed();
    const bytes = await exportRun(store, runId);
    expect(() => parseHellproofFile(bytes.subarray(0, 40))).toThrow(/truncated|overruns/);
  });

  it("names the file after the program, the date and the run", async () => {
    const { runId } = await seed();
    const run = await store.getRun(runId);
    expect(exportFileName(run!)).toMatch(/^segment_stub10-\d{4}-\d{2}-\d{2}T[\d-]+-[0-9a-f]{8}\.hellproof$/);
  });
});

describe("quota projection", () => {
  it("says nothing useful when the browser reports no quota", () => {
    const p = projectQuota({ usageBytes: null, quotaBytes: null, ratio: null, persisted: false }, 10);
    expect(p.warning).toBe(false);
    expect(p.headroomBytes).toBeNull();
  });

  it("does not warn while there is room", () => {
    const p = projectQuota(
      { usageBytes: 1e9, quotaBytes: 100e9, ratio: 0.01, persisted: true },
      50,
    );
    expect(p.warning).toBe(false);
    expect(p.projectedBytes).toBe(50 * PROOF_BYTES_ESTIMATE);
  });

  it("warns before the quota is actually hit, while an export is still possible", () => {
    const p = projectQuota({ usageBytes: 400e6, quotaBytes: 600e6, ratio: 0.66, persisted: false }, 30);
    expect(p.warning).toBe(true);
    expect(p.message).toMatch(/Export the run/);
  });

  it("warns on thin absolute headroom even when the ratio looks fine", () => {
    // 2 % of the quota used, but only ~206 MB would be left: under the 200 MiB
    // absolute floor, which is about one more run's worth of proofs.
    const p = projectQuota({ usageBytes: 0, quotaBytes: 210e6, ratio: 0, persisted: true }, 1);
    expect(p.warning).toBe(true);
    expect(p.headroomBytes).toBeLessThan(200 * 1024 * 1024);
  });

  it("recognises the browser's out-of-quota error", () => {
    expect(isQuotaExceeded(new DOMException("nope", "QuotaExceededError"))).toBe(true);
    expect(isQuotaExceeded(new Error("the quota was exceeded"))).toBe(true);
    expect(isQuotaExceeded(new Error("network"))).toBe(false);
  });
});

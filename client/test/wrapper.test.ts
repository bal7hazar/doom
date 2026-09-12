import "fake-indexeddb/auto";
import { IDBFactory } from "fake-indexeddb";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { RunSubmission } from "@hellproof/wrapper-client";
import { RunStore } from "../src/store/runStore.js";
import { WrapperSubmitter, toBase64 } from "../src/wrapper/submitter.js";
import type { SegmentRecord } from "../src/prove/types.js";

let store: RunStore;
let counter = 0;

interface Call {
  method: string;
  path: string;
  body: string;
}

/**
 * A wrapper stand-in. `perSegment` decides whether the endpoints this client
 * would prefer exist — they do not, in the service as it stands, which is what
 * the fallback test pins.
 */
function fakeServer(options: { perSegment?: boolean; failFirst?: number } = {}): {
  fetch: typeof globalThis.fetch;
  calls: Call[];
  held: number[];
} {
  const calls: Call[] = [];
  const held: number[] = [];
  let failures = options.failFirst ?? 0;
  const json = (status: number, body: unknown): Response =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = new URL(String(input));
    const method = init?.method ?? "GET";
    // The whole-run path sends a `ReadableStream` where the browser supports one
    // (only one proof is base64'd at a time); drain it like a real server would.
    const body =
      init?.body === undefined || init.body === null
        ? ""
        : typeof init.body === "string"
          ? init.body
          : await new Response(init.body as BodyInit).text();
    calls.push({ method, path: url.pathname, body });

    const segmentMatch = /^\/v1\/runs\/([^/]+)\/segments(?:\/(\d+))?$/.exec(url.pathname);
    if (segmentMatch) {
      if (!options.perSegment) return json(404, { error: "not found" });
      if (method === "GET") return json(200, { held: [...held] });
      if (method === "PUT") {
        if (failures-- > 0) return json(503, { error: "busy" });
        held.push(Number(segmentMatch[2]));
        return json(200, { index: Number(segmentMatch[2]), stored: true });
      }
    }
    if (/^\/v1\/runs\/[^/]+\/complete$/.test(url.pathname)) {
      return json(202, { run_id: "wrapper-run", status: "verifying", segments: held.length });
    }
    if (url.pathname === "/v1/runs" && method === "POST") {
      if (failures-- > 0) return json(503, { error: "busy" });
      const parsed = JSON.parse(body) as RunSubmission;
      return json(202, {
        run_id: parsed.run_id ?? "wrapper-run",
        status: "verifying",
        segments: parsed.segments.length,
      });
    }
    if (/^\/v1\/runs\/[^/]+$/.test(url.pathname) && method === "GET") {
      return json(200, {
        run_id: "wrapper-run",
        status: "done",
        program: "segment_stub10",
        solo: false,
        batch_id: "batch-1",
        batch_status: "done",
        created_at_ms: 0,
        updated_at_ms: 0,
        progress: { segments: 2, verified: 2, leaves_done: 2, leaves_cached: 0 },
        segments: [],
        timings: { verify_ms_total: 41, leaf_ms_total: 48_000 },
      });
    }
    if (/^\/v1\/batches\/[^/]+$/.test(url.pathname)) {
      return json(200, { batch_id: "batch-1", status: "done", root_proof_felt_count: 93_797 });
    }
    return json(404, { error: `unexpected ${method} ${url.pathname}` });
  }) as typeof globalThis.fetch;

  return { fetch: fetchImpl, calls, held };
}

function segment(runId: string, index: number, over: Partial<SegmentRecord> = {}): SegmentRecord {
  const ticStart = index * 10;
  return {
    runId,
    index,
    ticStart,
    ticEnd: ticStart + 10,
    args: ["0x1", `0x${ticStart.toString(16)}`, "0xa"],
    outputPreimage: ["0xdead", "0x1", "0x1", "0x2", "0x0", "0xa", "0x0", "0xc0", "0x0", "0x0", "0x0"],
    publicOutputs: ["0xaaaa", "0xbbbb"],
    output: {
      version: 1,
      hIn: "0x1",
      hOut: "0x2",
      ticStart,
      ticEnd: ticStart + 10,
      status: 0,
      inputsCommitment: "0xc0",
      kills: 0,
      items: 0,
      secrets: 0,
    },
    stage: "proved",
    proofBytes: 256,
    verified: true,
    attempts: 1,
    threads: 4,
    retriedSingleThread: false,
    timings: {},
    memoryBytes: 0,
    resources: null,
    submission: "local",
    updatedAt: 0,
    ...over,
  };
}

async function seedRun(over: { keepOffline?: boolean; segments?: number } = {}): Promise<string> {
  const run = await store.createRun({
    program: "segment_stub10",
    programHashFunction: "poseidon",
    genesis: "0x1",
    ...(over.keepOffline === undefined ? {} : { keepOffline: over.keepOffline }),
  });
  for (let i = 0; i < (over.segments ?? 2); i++) {
    await store.putSegment(
      segment(run.id, i),
      Uint8Array.from({ length: 256 }, (_, k) => (k + i) & 0xff),
    );
  }
  return run.id;
}

beforeEach(async () => {
  globalThis.indexedDB = new IDBFactory();
  store = await RunStore.open(`hellproof-wrapper-${counter++}`);
});

afterEach(() => {
  store.close();
});

describe("toBase64", () => {
  it("matches Buffer's encoding, chunk boundaries included", () => {
    for (const size of [0, 1, 2, 3, 0x8000 - 1, 0x8000, 0x8000 + 5]) {
      const bytes = Uint8Array.from({ length: size }, (_, i) => (i * 31) & 0xff);
      expect(toBase64(bytes)).toBe(Buffer.from(bytes).toString("base64"));
    }
  });
});

describe("WrapperSubmitter", () => {
  it("falls back to POST /v1/runs when the per-segment endpoints are absent", async () => {
    const runId = await seedRun();
    const server = fakeServer({ perSegment: false });
    const submitter = new WrapperSubmitter({ baseUrl: "http://wrapper.test", store, fetchImpl: server.fetch });

    const response = await submitter.submit(runId, { solo: true });
    expect(response.status).toBe("verifying");

    const posts = server.calls.filter((c) => c.method === "POST" && c.path === "/v1/runs");
    expect(posts).toHaveLength(1);
    const body = JSON.parse(posts[0]!.body) as RunSubmission;
    expect(body.program).toBe("segment_stub10");
    expect(body.program_hash_function).toBe("poseidon");
    expect(body.solo).toBe(true);
    expect(body.segments).toHaveLength(2);
    expect(body.segments[0]?.proof.format).toBe("bincode_b64");
    expect(body.segments[0]?.output_preimage).toHaveLength(11);
    // The proof really travelled, base64 of the stored bytes.
    const sent = Uint8Array.from(Buffer.from(body.segments[1]!.proof.data!, "base64"));
    expect(sent).toEqual(await store.getProof(runId, 1));
  });

  it("uses the per-segment endpoints when the wrapper offers them, and skips what it holds", async () => {
    const runId = await seedRun({ segments: 3 });
    const server = fakeServer({ perSegment: true });
    server.held.push(0); // the server already has segment 0 from a previous attempt
    const progress: string[] = [];
    const submitter = new WrapperSubmitter({
      baseUrl: "http://wrapper.test",
      store,
      fetchImpl: server.fetch,
      onProgress: (p) => progress.push(`${p.stage}:${p.uploaded}/${p.total}`),
    });

    await submitter.submit(runId);

    const puts = server.calls.filter((c) => c.method === "PUT");
    expect(puts.map((c) => c.path)).toEqual([
      "/v1/runs/segment_stub10-" + runId.slice(0, 24) + "/segments/1",
      "/v1/runs/segment_stub10-" + runId.slice(0, 24) + "/segments/2",
    ]);
    expect(server.calls.some((c) => c.path.endsWith("/complete"))).toBe(true);
    expect(progress.some((p) => p.startsWith("uploading:"))).toBe(true);
    expect(progress.at(-1)).toMatch(/^done:3\/3$/);
  });

  it("retries a 5xx with the same run id, so the server can dedupe", async () => {
    const runId = await seedRun();
    const server = fakeServer({ perSegment: true, failFirst: 1 });
    const submitter = new WrapperSubmitter({
      baseUrl: "http://wrapper.test",
      store,
      fetchImpl: server.fetch,
      maxAttempts: 3,
    });
    await submitter.submit(runId);
    const puts = server.calls.filter((c) => c.method === "PUT");
    // Two segments, one of which needed a second attempt.
    expect(puts).toHaveLength(3);
    expect(new Set(puts.map((c) => c.path)).size).toBe(2);
  });

  it("reuses the stored wrapper run id across submissions (the resume key)", async () => {
    const runId = await seedRun();
    const server = fakeServer({ perSegment: false });
    const submitter = new WrapperSubmitter({ baseUrl: "http://wrapper.test", store, fetchImpl: server.fetch });
    await submitter.submit(runId);
    const first = (await store.getRun(runId))?.submission.runId;
    await submitter.submit(runId);
    const second = (await store.getRun(runId))?.submission.runId;
    expect(first).toBeDefined();
    expect(second).toBe(first);
    const bodies = server.calls.filter((c) => c.path === "/v1/runs").map((c) => JSON.parse(c.body).run_id);
    expect(new Set(bodies).size).toBe(1);
  });

  it("refuses to upload a run the player marked keep-offline (C6)", async () => {
    const runId = await seedRun({ keepOffline: true });
    const server = fakeServer({ perSegment: false });
    const submitter = new WrapperSubmitter({ baseUrl: "http://wrapper.test", store, fetchImpl: server.fetch });
    await expect(submitter.submit(runId)).rejects.toThrow(/keep offline/);
    expect(server.calls).toHaveLength(0);
  });

  it("refuses a run with no proved segment, or with a gap in the indices", async () => {
    const empty = await seedRun({ segments: 0 });
    const server = fakeServer({ perSegment: false });
    const submitter = new WrapperSubmitter({ baseUrl: "http://wrapper.test", store, fetchImpl: server.fetch });
    await expect(submitter.submit(empty)).rejects.toThrow(/no proved segment/);

    const gapped = await seedRun({ segments: 1 });
    await store.putSegment(segment(gapped, 2), new Uint8Array(16));
    await expect(submitter.submit(gapped)).rejects.toThrow(/contiguous/);
  });

  it("records the failure locally instead of losing it", async () => {
    const runId = await seedRun();
    const submitter = new WrapperSubmitter({
      baseUrl: "http://wrapper.test",
      store,
      fetchImpl: (async () => {
        throw new Error("network down");
      }) as unknown as typeof globalThis.fetch,
      maxAttempts: 1,
    });
    await expect(submitter.submit(runId)).rejects.toThrow(/network down/);
    const after = await store.getRun(runId);
    expect(after?.submission.status).toBe("failed");
    expect(after?.submission.error).toMatch(/network down/);
    // …and the run id is kept, so the retry is a resume.
    expect(after?.submission.runId).toBeDefined();
  });

  it("mirrors the run status and the batch summary into the local record", async () => {
    const runId = await seedRun();
    const server = fakeServer({ perSegment: false });
    const submitter = new WrapperSubmitter({ baseUrl: "http://wrapper.test", store, fetchImpl: server.fetch });
    await submitter.submit(runId);
    const status = await submitter.waitForRun(runId, { pollMs: 1 });
    expect(status.status).toBe("done");

    const summary = await submitter.fetchBatchSummary(runId, "batch-1");
    expect(summary.rootProofFeltCount).toBe(93_797);
    const local = await store.getRun(runId);
    expect(local?.submission.batchId).toBe("batch-1");
    expect(local?.submission.batchStatus).toBe("done");
    expect(local?.submission.rootProofFeltCount).toBe(93_797);
  });

  it("marks every uploaded segment as submitted", async () => {
    const runId = await seedRun();
    const server = fakeServer({ perSegment: false });
    const submitter = new WrapperSubmitter({ baseUrl: "http://wrapper.test", store, fetchImpl: server.fetch });
    await submitter.submit(runId);
    const segments = await store.listSegments(runId);
    expect(segments.every((s) => s.submission === "submitted")).toBe(true);
    expect((await store.getRun(runId))?.submission.uploadedSegments).toBe(2);
  });
});

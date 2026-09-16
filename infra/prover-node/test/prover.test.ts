// SPDX-License-Identifier: Apache-2.0
/** The proof lock, the process-group timeout, the subprocess prover on a stand-in binary, and
 * the resume after an interruption (nothing proved twice). */
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { FakeExecutor } from "../src/executor.js";
import { FakeProver, ProofLock, ProofTimeoutError, proofFormatFlag, spawnWithTimeout, SubprocessProver } from "../src/prover.js";
import { proveSegments } from "../src/proving.js";
import { cutJournal } from "../src/segmenter.js";
import { FileJobStore, newJob } from "../src/store.js";
import { fakeCommitment, fixtureJournal } from "./fixtures.js";

const FAKE_STWO = join(import.meta.dirname, "fixtures/fake-stwo.mjs");
const words = fixtureJournal(0);
const dirs: string[] = [];
const scratch = (): string => {
  const d = mkdtempSync(join(tmpdir(), "prover-node-"));
  dirs.push(d);
  return d;
};
afterEach(() => dirs.splice(0).forEach((d) => rmSync(d, { recursive: true, force: true })));

async function cutJob(store: FileJobStore) {
  const executor = new FakeExecutor({ terminal: { tic: 297, status: 2 } });
  const genesis = (await executor.genesis(1)).hash;
  const job = newJob(fakeCommitment(words, { genesis }));
  job.segments = (await cutJournal(executor, words, { genesis, levelId: 1 })).segments;
  job.stage = "cut";
  return store.put(job);
}

describe("the proof lock", () => {
  it("is exclusive, times out while busy and is released only by its owner", async () => {
    const dir = join(scratch(), ".proof-lock");
    const a = new ProofLock(dir);
    await a.acquire({ timeoutMs: 100, pollMs: 10 });
    expect(readFileSync(a.ownerFile, "utf8").trim()).toBe(String(process.pid));
    const b = new ProofLock(dir);
    const t0 = Date.now();
    await expect(b.acquire({ timeoutMs: 150, pollMs: 20 })).rejects.toThrow(/proof lock .* busy \(owner pid/);
    expect(Date.now() - t0).toBeGreaterThanOrEqual(140);
    b.release(); // not the holder: a no-op
    expect(existsSync(dir)).toBe(true);
    // A lock held by someone else is never removed, even by a process that once held it.
    writeFileSync(a.ownerFile, "424242\n");
    a.release();
    expect(existsSync(dir)).toBe(true);
    writeFileSync(a.ownerFile, `${process.pid}\n`);
    await a.acquire({ timeoutMs: 50, pollMs: 10 }).catch(() => {});
    new ProofLock(dir).release();
    expect(existsSync(dir)).toBe(true);
  });

  it("reclaims a stale lock only when asked", async () => {
    const dir = join(scratch(), ".proof-lock");
    const stale = new ProofLock(dir);
    await stale.acquire();
    writeFileSync(stale.ownerFile, "999999999\n");
    await expect(new ProofLock(dir).acquire({ timeoutMs: 30, pollMs: 10 })).rejects.toThrow(/busy/);
    const fresh = new ProofLock(dir);
    await fresh.acquire({ timeoutMs: 30, pollMs: 10, reclaimStale: true });
    expect(readFileSync(fresh.ownerFile, "utf8").trim()).toBe(String(process.pid));
    fresh.release();
    expect(existsSync(dir)).toBe(false);
  });
});

describe("spawnWithTimeout", () => {
  it("kills a hanging process group and reports the timeout", async () => {
    const log = join(scratch(), "hang.log");
    const r = await spawnWithTimeout(process.execPath, ["-e", "setTimeout(() => {}, 30000)"], { timeoutMs: 300, logPath: log });
    expect(r.timedOut).toBe(true);
    expect(r.wallMs).toBeLessThan(5000);
    expect(readFileSync(log, "utf8")).toMatch(/TIMEOUT: proof process group killed/);
    const ok = await spawnWithTimeout(process.execPath, ["-e", "console.log('hi')"], { timeoutMs: 5000, logPath: log });
    expect(ok).toMatchObject({ exitCode: 0, timedOut: false });
    expect(readFileSync(log, "utf8")).toBe("hi\n");
  });
});

describe("SubprocessProver on a stand-in stwo-run-and-prove", () => {
  /** The "binary" is `node test/fixtures/fake-stwo.mjs …`, everything else is the real class. */
  const prover = (work: string, env: Record<string, string>, proofFormat: "bincode" | "cairo-serde" = "bincode") =>
    new SubprocessProver({
      bin: process.execPath,
      prefixArgs: [FAKE_STWO],
      bootloader: "/bootloader.json",
      params: "/leaf.json",
      executable: "/run_segment.executable.json",
      lockDir: join(work, ".proof-lock"),
      proofFormat,
      env,
      lockTimeoutMs: 500,
      lockPollMs: 20,
    });
  const request = (work: string) => ({
    index: 3,
    args: ["0x1", "0x2", "0x3"],
    expectedOutput: ["0x1", "0xa", "0xb", "0x0", "0x5", "0x2", "0xc", "0x1", "0x0", "0x0"],
    workDir: work,
  });

  it("writes the bootloader task, proves under the lock and reads the preimage and proof back", async () => {
    const work = scratch();
    const preimage = ["0x5eed", ...request(work).expectedOutput];
    const artifact = await prover(work, { FAKE_STWO_PREIMAGE: JSON.stringify(preimage) }).prove(request(work), { timeoutMs: 10_000 });
    expect(artifact).toMatchObject({ index: 3, format: "bincode_b64", programHash: "0x5eed", outputPreimage: preimage });
    expect(Buffer.from(artifact.data!, "base64").toString()).toBe("bincode:3");
    expect(existsSync(join(work, ".proof-lock"))).toBe(false);
    const input = JSON.parse(readFileSync(join(work, "segment-3/bl_input.json"), "utf8"));
    expect(input.tasks[0]).toMatchObject({ type: "Cairo1Executable", program_hash_function: "blake", path: "/run_segment.executable.json" });
    expect(JSON.parse(readFileSync(input.tasks[0].user_args_file, "utf8"))).toEqual(["0x1", "0x2", "0x3"]);
    const log = readFileSync(join(work, "segment-3/prove.log"), "utf8");
    expect(log).toMatch(/proved 3 args with blake/);
    // The wrapper's `bincode_b64` is the extended CairoProof, which the binary only writes as
    // `extended-binary`; `bincode` is not a value of its `--proof-format`.
    expect(log).toMatch(/--proof-format extended-binary --program_output/);
    expect(log).toMatch(/--verify/);
    expect(JSON.parse(readFileSync(join(work, "segment-3/proof_metrics.json"), "utf8"))).toMatchObject({ exitCode: 0, timedOut: false });

    const felts = await prover(work, { FAKE_STWO_PREIMAGE: JSON.stringify(preimage) }, "cairo-serde").prove(request(work));
    expect(felts.format).toBe("cairo_serde_felts");
    expect(felts.felts).toEqual(["0x1", "0x2", "0x3"]);
    expect(readFileSync(join(work, "segment-3/prove.log"), "utf8")).toMatch(/--proof-format cairo-serde/);
    expect(proofFormatFlag("bincode")).toBe("extended-binary");
  });

  it("times out, kills the group, releases the lock and never returns a proof", async () => {
    const work = scratch();
    await expect(prover(work, { FAKE_STWO_MODE: "hang" }).prove(request(work), { timeoutMs: 400 })).rejects.toBeInstanceOf(ProofTimeoutError);
    expect(existsSync(join(work, ".proof-lock"))).toBe(false);
    expect(JSON.parse(readFileSync(join(work, "segment-3/proof_metrics.json"), "utf8")).timedOut).toBe(true);
    expect(existsSync(join(work, "segment-3/output_preimage.json"))).toBe(false);
    await expect(prover(work, { FAKE_STWO_MODE: "fail" }).prove(request(work))).rejects.toThrow(/exited 3/);
    expect(existsSync(join(work, ".proof-lock"))).toBe(false);
  });

  it("waits for a busy lock and gives up after the lock timeout", async () => {
    const work = scratch();
    const holder = new ProofLock(join(work, ".proof-lock"));
    await holder.acquire();
    await expect(prover(work, { FAKE_STWO_PREIMAGE: "[]" }).prove(request(work))).rejects.toThrow(/proof lock .* busy/);
    holder.release();
  });
});

describe("proveSegments resumes after an interruption", () => {
  it("keeps the first proof, fails on the second, then proves only what is missing", async () => {
    const store = new FileJobStore(scratch());
    const job = await cutJob(store);
    const id = job.commitment.commitmentId;
    const n = job.segments!.length;
    expect(n).toBeGreaterThan(2);

    const flaky = new FakeProver({ failOnce: [1] });
    await expect(proveSegments(job, store, flaky, { programHash: "0x5eed" })).rejects.toThrow(/segment 1: fake prover failed once/);
    expect(flaky.calls).toEqual([0, 1]);
    expect(store.proofIndices(id)).toEqual([0]);
    expect(store.get(id)).toMatchObject({ stage: "proving", proved: [0] });

    // The relaunch: a fresh process reloads the job and a fresh prover.
    const resumed = store.get(id)!;
    const steady = new FakeProver();
    const artifacts = await proveSegments(resumed, store, steady, { programHash: "0x5eed" });
    expect(steady.calls).toEqual(Array.from({ length: n - 1 }, (_, i) => i + 1));
    expect(artifacts.map((a) => a.index)).toEqual(Array.from({ length: n }, (_, i) => i));
    expect(store.proofIndices(id)).toEqual(artifacts.map((a) => a.index));
    expect(store.get(id)).toMatchObject({ stage: "proved", proved: artifacts.map((a) => a.index) });
    // Segment 0's proof is byte-identical to the one the first run persisted.
    expect(artifacts[0]).toEqual(store.getProof(id, 0));

    // A third run proves nothing at all.
    const idle = new FakeProver();
    await proveSegments(store.get(id)!, store, idle);
    expect(idle.calls).toEqual([]);
  });

  it("refuses a proof whose preimage or program hash does not match the execution", async () => {
    const store = new FileJobStore(scratch());
    const job = await cutJob(store);
    await expect(proveSegments(job, store, new FakeProver({ corrupt: [0] }))).rejects.toThrow(/public output differs/);
    expect(store.proofIndices(job.commitment.commitmentId)).toEqual([]);
    await expect(proveSegments(job, store, new FakeProver({ programHash: "0x1" }), { programHash: "0x2" })).rejects.toThrow(/proved with program 0x1/);
  });

  it("round-trips the job record with its bigint bounty", async () => {
    const store = new FileJobStore(scratch());
    const job = await cutJob(store);
    const back = store.get(job.commitment.commitmentId)!;
    expect(back.commitment.bounty).toBe(5_000_000_000_000_000_000n);
    expect(back.segments).toEqual(job.segments);
    expect(store.list().map((j) => j.commitment.commitmentId)).toEqual([job.commitment.commitmentId]);
  });
});

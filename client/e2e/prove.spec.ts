import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { expect, test } from "@playwright/test";

/**
 * End-to-end proving, in the browser the product ships on (roadmap **P3.2**,
 * exit criteria of **R1-A7** and **R6-A2**).
 *
 * It proves **two** `segment_stub10` segments in headless Chromium against the
 * real wasm64 Stwo prover, verifies each proof *in the browser*, checks the
 * `h_in`/`h_out` chain, and then **reloads the page** and finds both proofs
 * still there — which is the whole point of P2.5: "close the tab at 50 %,
 * reopen, finish".
 *
 * Single-threaded and with a tiny K on purpose: the threaded path is the one
 * R1-A8 says can hang, and this test must be a regression gate, not a
 * benchmark. `prover/wasm/harness` is where thread scaling is measured.
 */

const PROVER_WASM = fileURLToPath(
  new URL("../public/prover/wasm/hellproof_prover_wasm.wasm", import.meta.url),
);
const PROVER_WORKER = fileURLToPath(
  new URL("../public/prover/dist/prover-worker.js", import.meta.url),
);

/** The run id is fixed so the reload half of the test can find it again. */
const RUN_ID = "e2e-two-segments";
const TICS = 7;
const SEGMENTS = 2;

/** What `prove.html` hangs on `window.hellproof` for this test to drive. */
interface HellproofApi {
  state(): {
    runId: string;
    proved: number;
    total: number;
    ticsRecorded: number;
    chain: { ok: boolean; tics?: number; reason?: string } | null;
    error?: string;
  };
  listSegments(): Promise<SegmentView[]>;
  getProofLength(index: number): Promise<number>;
  verifyPersistedChain(): Promise<{ ok: boolean; tics?: number; reason?: string }>;
  exportBytes(): Promise<Uint8Array>;
  reverifyAll(): Promise<boolean>;
}

/**
 * `prove.html` hangs the API on the page's global. Declaring it here is what
 * lets the `page.evaluate` callbacks below be written as plain code.
 */
declare global {
  // eslint-disable-next-line no-var
  var hellproof: HellproofApi | undefined;
}

interface SegmentView {
  index: number;
  ticStart: number;
  ticEnd: number;
  stage: string;
  verified: boolean;
  proofBytes: number;
  threads: number;
  attempts: number;
  retriedSingleThread: boolean;
  memoryBytes: number;
  timings: { executeMs?: number; proveMs?: number; verifyMs?: number; totalMs?: number };
  resources: { nSteps: number; maxComponent: string; maxComponentRows: number; utilisation: number } | null;
  output: { hIn: string; hOut: string; ticStart: number; ticEnd: number; status: number } | null;
}

test.describe("proving pipeline", () => {
  test.skip(
    !existsSync(PROVER_WASM) || !existsSync(PROVER_WORKER),
    "the wasm64 prover is not staged: run `npm run prover` in client/ (see scripts/prepare-prover.sh)",
  );

  // Two ~2^17-step leaf proofs single-threaded, plus two 45 MB module
  // instantiations. 23 s per proof was measured in Node 24; Chrome is faster,
  // but the budget is generous so a slow machine fails on a real regression.
  test.setTimeout(15 * 60_000);

  test("proves, verifies and persists two stub segments, then finds them after a reload", async ({
    page,
  }) => {
    const consoleErrors: string[] = [];
    page.on("console", (message) => {
      if (message.type() === "error") consoleErrors.push(message.text());
    });
    page.on("pageerror", (error) => consoleErrors.push(String(error)));

    await page.goto(
      `/prove.html?run=${RUN_ID}&tics=${TICS}&segments=${SEGMENTS}&threads=1&reset=1&autostart=1`,
    );

    // The page is cross-origin isolated even though this run is single-threaded:
    // the COOP/COEP headers are the production ones (P2.7).
    expect(await page.evaluate(() => globalThis.crossOriginIsolated)).toBe(true);

    await page.waitForFunction(
      (want: number) => {
        if (!globalThis.hellproof) return false;
        const state = globalThis.hellproof.state();
        return state.proved >= want || state.error !== undefined;
      },
      SEGMENTS,
      { timeout: 14 * 60_000, polling: 1000 },
    );

    const state = await page.evaluate(() => hellproof!.state());
    expect(state).toMatchObject({ runId: RUN_ID, proved: SEGMENTS, total: SEGMENTS });
    expect((state as { error?: string }).error).toBeUndefined();
    expect((state as { chain: { ok: boolean } }).chain.ok).toBe(true);

    const segments = await page.evaluate(() => hellproof!.listSegments());

    expect(segments).toHaveLength(SEGMENTS);
    for (const [index, segment] of segments.entries()) {
      expect(segment.index).toBe(index);
      expect(segment.stage).toBe("proved");
      expect(segment.verified).toBe(true);
      expect(segment.threads).toBe(1);
      expect(segment.attempts).toBe(1);
      expect(segment.retriedSingleThread).toBe(false);
      // A leaf proof is ~4.2 MB of bincode whatever the segment size (P3.1).
      expect(segment.proofBytes).toBeGreaterThan(3_000_000);
      expect(segment.proofBytes).toBeLessThan(6_000_000);
      expect(segment.timings.proveMs).toBeGreaterThan(0);
      expect(segment.timings.verifyMs).toBeGreaterThan(0);
      expect(segment.memoryBytes).toBeGreaterThan(512 * 1024 * 1024);
      // The planner accepted it because `resources()` said it fits, with margin.
      expect(segment.resources?.nSteps).toBeGreaterThan(0);
      expect(segment.resources?.maxComponentRows).toBeLessThanOrEqual(2 ** 20);
      expect(segment.resources?.utilisation).toBeLessThanOrEqual(0.8);
      expect(segment.ticStart).toBe(index * TICS);
      expect(segment.ticEnd).toBe((index + 1) * TICS);
    }

    // The chain: segment 0 starts at the genesis, segment 1 continues it (D14).
    expect(segments[0]!.output!.hIn).toBe("0x1");
    expect(segments[1]!.output!.hIn).toBe(segments[0]!.output!.hOut);
    expect(segments.every((s) => s.output!.status === 0)).toBe(true);

    // …and the bytes are really in IndexedDB, not just in the page's memory.
    const storedBytes = await page.evaluate(async () => [
      await hellproof!.getProofLength(0),
      await hellproof!.getProofLength(1),
    ]);
    expect(storedBytes[0]).toBe(segments[0]!.proofBytes);
    expect(storedBytes[1]).toBe(segments[1]!.proofBytes);

    const timings = segments.map((s) => ({
      index: s.index,
      steps: s.resources?.nSteps,
      proveS: Math.round((s.timings.proveMs ?? 0) / 100) / 10,
      verifyMs: Math.round(s.timings.verifyMs ?? 0),
      peakGiB: Math.round((s.memoryBytes / 2 ** 30) * 100) / 100,
      proofMB: Math.round(s.proofBytes / 1e5) / 10,
    }));
    // eslint-disable-next-line no-console
    console.log("segments:", JSON.stringify(timings));

    // ---------------------------------------------------------------------
    // Reload: the run has to come back from IndexedDB, proofs included, and
    // nothing may be re-proved (R1-A7 / R6-A2).
    // ---------------------------------------------------------------------
    await page.goto(
      `/prove.html?run=${RUN_ID}&tics=${TICS}&segments=${SEGMENTS}&threads=1&autostart=0`,
    );
    await page.waitForFunction(() => globalThis.hellproof !== undefined, undefined, {
      timeout: 60_000,
    });

    const afterReload = await page.evaluate(() => hellproof!.listSegments());
    expect(afterReload).toHaveLength(SEGMENTS);
    expect(afterReload.every((s) => s.stage === "proved" && s.verified)).toBe(true);
    expect(afterReload.map((s) => s.proofBytes)).toEqual(segments.map((s) => s.proofBytes));

    const reloadedState = await page.evaluate(() => hellproof!.state());
    expect(reloadedState.proved).toBe(SEGMENTS);
    expect(reloadedState.total).toBe(SEGMENTS);
    expect(reloadedState.ticsRecorded).toBe(TICS * SEGMENTS);

    const chain = await page.evaluate(() => hellproof!.verifyPersistedChain());
    expect(chain.ok, chain.reason).toBe(true);
    expect(chain.tics).toBe(TICS * SEGMENTS);

    // A `.hellproof` export carries the manifest and both proofs.
    const exportSize = await page.evaluate(async () => (await hellproof!.exportBytes()).byteLength);
    expect(exportSize).toBeGreaterThan(segments[0]!.proofBytes + segments[1]!.proofBytes);

    // Every stored proof re-verifies from disk, with a prover that never saw it
    // produced — the "verify locally" button of the end-of-game flow.
    const reverified = await page.evaluate(() => hellproof!.reverifyAll());
    expect(reverified).toBe(true);

    expect(consoleErrors, `console errors: ${consoleErrors.join(" | ")}`).toHaveLength(0);
  });
});

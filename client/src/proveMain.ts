/**
 * `prove.html` — the proving pipeline on its own, without the renderer.
 *
 * It is the page the Playwright end-to-end test drives and the page to open when
 * working on P3.2: it feeds a synthetic ticcmd journal to the real
 * {@link ProofPipeline}, against the real `segment_stub10` executable and the
 * real wasm64 prover, and persists everything through the real {@link RunStore}.
 * The game plugs into exactly the same three calls (`attach`, `appendTics`,
 * `finish`) once P2.4 produces ticcmds.
 *
 * Query parameters (all optional):
 *
 * | param | default | what |
 * |---|---|---|
 * | `run` | a fresh id | attach to this run id — reload with the same one to exercise resume |
 * | `tics` | `21` | tics per segment |
 * | `segments` | `2` | segments to produce before finishing |
 * | `threads` | `auto` | `1` forces the single-threaded artifact |
 * | `autostart` | `1` | start proving immediately |
 * | `reset` | `0` | delete the run before attaching |
 * | `wrapper` | — | base URL of a wrapper service, for the submit button |
 *
 * `window.hellproof` exposes the pipeline, the store and a few helpers so the
 * test can assert on them.
 */
import { probeCapabilities, probeStorage } from "./caps/capabilities.js";
import { ProofPipeline } from "./prove/pipeline.js";
import { createStubProgram } from "./prove/program.js";
import { ProverClient } from "./prove/proverClient.js";
import { encodeCmd, quantize } from "./prove/ticcmd.js";
import type { PipelineEvent, SegmentRecord } from "./prove/types.js";
import { exportFileName, exportRun, importRun } from "./store/hellproofFile.js";
import { readStorageStatus, requestPersistence } from "./store/quota.js";
import { RunStore } from "./store/runStore.js";
import { ProofQueuePanel, type EndGameActions } from "./ui/proofQueue.js";
import { WrapperSubmitter } from "./wrapper/submitter.js";

const PROVER_WORKER_URL = "/prover/dist/prover-worker.js";

const params = new URLSearchParams(location.search);
const num = (key: string, fallback: number): number => {
  const raw = params.get(key);
  const value = raw === null ? Number.NaN : Number(raw);
  return Number.isFinite(value) ? value : fallback;
};

/** A deterministic, plausible journal: the pipeline only ever sees 32-bit words. */
function syntheticWords(count: number, offset: number): number[] {
  const words: number[] = [];
  for (let i = 0; i < count; i++) {
    const t = offset + i;
    words.push(
      encodeCmd(
        quantize({
          forward: ((t * 7) % 101) - 50,
          side: ((t * 13) % 61) - 30,
          turn: (((t * 29) % 41) - 20) * 256,
          buttons: t % 4,
        }),
      ),
    );
  }
  return words;
}

async function main(): Promise<void> {
  const statusEl = document.getElementById("status") as HTMLElement;
  const panelHost = document.getElementById("queue") as HTMLElement;

  const caps = await probeStorage(probeCapabilities());
  const ticsPerSegment = Math.max(1, Math.round(num("tics", 21)));
  const segmentCount = Math.max(1, Math.round(num("segments", 2)));
  const threadsParam = params.get("threads");
  const threads = threadsParam === null || threadsParam === "auto" ? "auto" : Number(threadsParam);
  const timeoutMs = Math.round(num("timeout", 15 * 60_000));

  const store = await RunStore.open();
  const runId = params.get("run") ?? undefined;
  if (params.get("reset") === "1" && runId) await store.deleteRun(runId);

  const persisted = await requestPersistence();
  const storage = await readStorageStatus();
  const program = createStubProgram({ executableUrl: "/programs/segment_stub10.executable.json" });

  // The actions are wired after the pipeline exists; the panel calls through
  // this indirection so it can be built first and receive every event.
  const handlers: EndGameActions = {};
  const actions: EndGameActions = {
    onProve: () => handlers.onProve?.(),
    onVerify: () => handlers.onVerify?.(),
    onSubmit: () => handlers.onSubmit?.(),
    onExport: () => handlers.onExport?.(),
    onImport: (file) => handlers.onImport?.(file),
    onReset: () => handlers.onReset?.(),
    onKeepOffline: (value) => handlers.onKeepOffline?.(value),
  };
  const panel = new ProofQueuePanel({ title: "Proof queue (segment_stub10)", actions });
  panelHost.append(panel.element);

  const events: PipelineEvent[] = [];
  let pipeline!: ProofPipeline;

  const render = (): void => {
    const state = pipeline.state;
    statusEl.textContent = [
      `run ${state.runId}`,
      `${state.proved}/${state.total} proved`,
      `${state.ticsPlanned}/${state.ticsRecorded} tics`,
      `${state.threads} thread(s)`,
      `peak ${(state.peakMemoryBytes / 2 ** 30).toFixed(2)} GiB`,
      state.chain ? (state.chain.ok ? "chain ok" : `chain broken: ${state.chain.reason}`) : "chain —",
      state.error ?? "",
    ]
      .filter(Boolean)
      .join(" · ");
  };

  pipeline = new ProofPipeline({
    store,
    program,
    proverWorkerUrl: PROVER_WORKER_URL,
    threads,
    planner: {
      // The stub's cost is dominated by a fixed ~2^17-step loop, so the model
      // would happily propose tens of thousands of tics; the harness wants short
      // segments it can prove twice inside a test.
      initialTics: ticsPerSegment,
      maxTics: ticsPerSegment,
      minTics: 1,
    },
    // A hung prove must fail the test, not stall it.
    proveTimeoutMs: timeoutMs,
    singleThreadProveTimeoutMs: timeoutMs,
    onEvent: (event) => {
      events.push(event);
      panel.handleEvent(event);
      panel.update(pipeline.state, pipeline.segmentRecords);
      render();
    },
  });

  const run = await pipeline.attach(runId);
  panel.setKeepOffline(run.keepOffline);
  panel.log(
    `cross-origin isolated: ${caps.crossOriginIsolated}; memory64: ${caps.wasm.memory64}; cores: ${caps.hardwareConcurrency}; storage ${storage.usageBytes ?? "?"} / ${storage.quotaBytes ?? "?"}${persisted ? " (persisted)" : ""}`,
  );

  // Feed the journal: enough tics for `segmentCount` segments, then close it.
  const wanted = ticsPerSegment * segmentCount;
  if (run.ticCount < wanted) await pipeline.appendTics(syntheticWords(wanted - run.ticCount, run.ticCount));
  await pipeline.flushJournal();

  const reverifyAll = async (): Promise<boolean> => {
    const prover = new ProverClient({ workerUrl: PROVER_WORKER_URL });
    try {
      await prover.init({ threads: 1 });
      const segments = await store.listSegments(run.id);
      if (segments.length === 0) return false;
      for (const segment of segments) {
        const proof = await store.getProof(run.id, segment.index);
        if (!proof) return false;
        if (!(await prover.verify(proof))) return false;
      }
      return true;
    } finally {
      prover.terminate();
    }
  };

  const api = {
    pipeline,
    store,
    runId: run.id,
    events,
    state: () => pipeline.state,
    segments: (): readonly SegmentRecord[] => pipeline.segmentRecords,
    listSegments: () => store.listSegments(run.id),
    getProofLength: async (index: number): Promise<number> =>
      (await store.getProof(run.id, index))?.byteLength ?? 0,
    verifyPersistedChain: () => pipeline.verifyPersistedChain(),
    reverifyAll,
    exportBytes: () => exportRun(store, run.id),
    exportFileName: () => exportFileName(run),
    importBytes: (bytes: Uint8Array) => importRun(store, bytes),
    reset: () => store.deleteRun(run.id),
    proveAll: () => pipeline.proveAll(),
  };
  (globalThis as unknown as { hellproof: typeof api }).hellproof = api;

  handlers.onProve = (): void => void pipeline.finish().then(() => pipeline.start());
  handlers.onVerify = (): void =>
    void reverifyAll().then((ok) => panel.log(`re-verified every stored proof: ${ok}`));
  handlers.onKeepOffline = (value): void => void store.updateRun(run.id, { keepOffline: value });
  handlers.onExport = (): void =>
    void api.exportBytes().then((bytes) => {
      const url = URL.createObjectURL(new Blob([bytes as BlobPart]));
      const a = document.createElement("a");
      a.href = url;
      a.download = exportFileName(run);
      a.click();
      URL.revokeObjectURL(url);
    });
  handlers.onImport = (file): void =>
    void file.arrayBuffer().then(async (buffer) => {
      const result = await importRun(store, buffer);
      panel.log(`imported run ${result.runId}: ${result.segments} segments, ${result.proofs} proofs`);
    });
  handlers.onReset = (): void => void api.reset().then(() => panel.log("run deleted (C6 reset)"));
  handlers.onSubmit = (): void => {
    // P4.3 owns the on-chain screen; this is the wrapper leg only.
    const base = params.get("wrapper");
    if (!base) {
      panel.log("no ?wrapper=<url> given: nothing to submit to");
      return;
    }
    const submitter = new WrapperSubmitter({
      baseUrl: base,
      store,
      ...(params.get("apiKey") ? { apiKey: params.get("apiKey") as string } : {}),
      onProgress: (p) => panel.log(`upload ${p.stage}: ${p.uploaded}/${p.total} (${p.mode})`),
    });
    void submitter
      .submit(run.id, { solo: params.get("solo") === "1" })
      .then((r) => panel.log(`wrapper accepted run ${r.run_id} (${r.status})`))
      .catch((error: unknown) => panel.log(`submission failed: ${String(error)}`));
  };

  panel.update(pipeline.state, pipeline.segmentRecords);
  render();

  if (params.get("autostart") !== "0") {
    await pipeline.finish();
    pipeline.start();
  }
}

void main().catch((error: unknown) => {
  const statusEl = document.getElementById("status");
  if (statusEl) statusEl.textContent = `failed: ${String(error)}`;
  (globalThis as unknown as { hellproofError?: string }).hellproofError = String(error);
  console.error(error);
});

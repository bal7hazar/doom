/**
 * `ProveSession` — the proving pipeline as the *game page* uses it.
 *
 * `ProofPipeline` knows about segments and proofs; this knows about a player: it
 * opens the database, attaches a run, records one `ticcmd` word per tic, owns the
 * proof-queue panel and wires the end-of-game buttons (prove, verify locally,
 * keep offline, export/import, reset, and submit — the wrapper upload followed
 * by the cost screen and the signed on-chain sequence of P4.3, `onchain.ts`).
 *
 * It is created **lazily**, on the first press of the proof-queue key: a clone
 * without `public/prover/` (the artifacts are 45 MB each and gitignored) must
 * still boot the renderer, and nothing here should cost a frame before the
 * player asks for it. A concrete Doom program supplies the acknowledged game
 * journal created at tic zero; create/start/finish synchronize it without losing
 * inputs recorded before the panel was opened.
 */
import type { WrapperBatch } from "../chain/batch.js";
import type { PriceSource } from "../chain/prices.js";
import type { RpcClient } from "../chain/rpc.js";
import type { Signer } from "../chain/signer.js";
import { exportFileName, exportRunBlob, importRun } from "../store/hellproofFile.js";
import { readStorageStatus, requestPersistence } from "../store/quota.js";
import { RunStore } from "../store/runStore.js";
import { connectController } from "../ui/controllerConnect.js";
import { ProofQueuePanel } from "../ui/proofQueue.js";
import { WrapperSubmitter } from "../wrapper/submitter.js";
import { OnChainSubmitter, type OnChainConfig, type OnChainConfigResult } from "./onchain.js";
import { ProofPipeline } from "./pipeline.js";
import { ProverClient } from "./proverClient.js";
import { createStubProgram, type SegmentProgram } from "./program.js";
import { encodeCmd, quantize, type TicCmd } from "./ticcmd.js";
import type { RunRecord } from "./types.js";

/** Where `scripts/prepare-prover.sh` stages the package. */
export const DEFAULT_PROVER_WORKER_URL = "/prover/dist/prover-worker.js";

/** The neutral command: no movement, no turn, no button. */
export const NEUTRAL_TICCMD_WORD = encodeCmd(quantize({ forward: 0, side: 0, turn: 0, buttons: 0 }));

export interface ProveSessionOptions {
  /** Where the panel is appended. */
  host: HTMLElement;
  /** Defaults to the `segment_stub10` stand-in until `doom_run` exists. */
  program?: SegmentProgram;
  proverWorkerUrl?: string;
  /** Defaults to `"auto"`: `min(4, hardwareConcurrency - 2)` when isolated. */
  threads?: number | "auto";
  /** Attach to an existing run instead of starting a new one. */
  runId?: string;
  /** Base URL of a wrapper service; without one the submit button explains itself. */
  wrapperUrl?: string | null;
  apiKey?: string;
  /**
   * The on-chain leg (P4.3). Without it a folded batch stops at its id; with a configuration
   * that is not complete the submit button says which variable is missing.
   */
  onchain?: OnChainSetup | null;
  signal?: AbortSignal;
  onImport?: (file: File) => Promise<void>;
}

/** What the game page supplies for the on-chain leg; the injectable parts are for tests. */
export interface OnChainSetup {
  config: OnChainConfigResult;
  /** Defaults to the Cartridge Controller with the submission session policies. */
  connectSigner?: (config: OnChainConfig) => Promise<Signer>;
  /** Defaults to `GET /v1/batches/{id}?include=proof` on the configured wrapper. */
  fetchBatch?: (batchId: string) => Promise<WrapperBatch>;
  rpc?: RpcClient;
  priceSource?: PriceSource;
}

/**
 * Is a local prover staged? A plain clone has no `public/prover/`, and the right
 * answer then is "prove later, or on another machine" (R6-A3) rather than a
 * stack trace.
 */
export async function proverIsAvailable(url = DEFAULT_PROVER_WORKER_URL, signal?: AbortSignal): Promise<boolean> {
  try {
    const res = await fetch(url, { method: "HEAD", signal });
    return res.ok;
  } catch {
    return false;
  }
}

export class ProveSession {
  private verification?: ProverClient;
  private verificationEpoch = 0;
  private verifying = false;
  private disposed = false;
  private constructor(
    readonly pipeline: ProofPipeline,
    readonly store: RunStore,
    readonly panel: ProofQueuePanel,
    private run: RunRecord,
    private readonly options: ProveSessionOptions,
  ) {}

  static async create(options: ProveSessionOptions): Promise<ProveSession> {
    const store = await RunStore.open();
    const program = options.program ?? createStubProgram();
    const workerUrl = options.proverWorkerUrl ?? DEFAULT_PROVER_WORKER_URL;

    let session: ProveSession;
    const panel = new ProofQueuePanel({
      actions: {
        onProve: () => void (program.journalWords ? session.finishAndProve() : session.startProving()).catch(error => panel.log(String(error))),
        onVerify: () => void session.verifyLocally().catch(error => panel.log(String(error))),
        onKeepOffline: (value) => void session.setKeepOffline(value),
        onExport: () => void session.exportRun().catch(error => panel.log(String(error))),
        onImport: (file) => void session.importRun(file).catch(error => panel.log(`Import refused: ${String(error)}`)),
        onReset: () => void session.reset(),
        onSubmit: () => void session.submit(),
      },
    });

    const pipeline = new ProofPipeline({
      store,
      program,
      proverWorkerUrl: workerUrl,
      threads: options.threads ?? "auto",
      onEvent: (event) => {
        panel.handleEvent(event);
        panel.update(pipeline.state, pipeline.segmentRecords);
      },
    });

    const abort = () => { void pipeline.stop(true).catch(() => undefined); program.dispose?.(); panel.element.remove(); };
    options.signal?.addEventListener("abort", abort, { once: true });
    try {
      options.signal?.throwIfAborted();
      const run = await pipeline.attach(options.runId);
      options.signal?.throwIfAborted();
      if (program.journalWords) await pipeline.syncGameJournal();
      session = new ProveSession(pipeline, store, panel, run, options);
      options.host.append(panel.element);
      panel.setKeepOffline(run.keepOffline);
      panel.update(pipeline.state, pipeline.segmentRecords);

      const available = await proverIsAvailable(workerUrl, options.signal);
      options.signal?.throwIfAborted();
      if (!available) {
        panel.log(
          `no local prover at ${workerUrl}: the run is still recorded and can be exported (.hellproof) and proved elsewhere (R6-A3). Stage one with \`npm run prover\`.`,
        );
      }
      const storage = await readStorageStatus();
      panel.log(
        `run ${run.id} · ${run.segments} segment(s) on disk · storage ${format(storage.usageBytes)} / ${format(storage.quotaBytes)}${storage.persisted ? " (persisted)" : ""}`,
      );
      options.signal?.throwIfAborted();
      return session;
    } catch (error) {
      try { await pipeline.stop(true); }
      finally { program.dispose?.(); panel.element.remove(); store.close(); }
      throw error;
    } finally { options.signal?.removeEventListener("abort", abort); }
  }

  get element(): HTMLElement {
    return this.panel.element;
  }

  /** One tic of input. Called from the game loop; buffered, not written per tic. */
  recordTic(word: number): void {
    void this.pipeline.appendTics([word]);
  }

  /** The same, from a command the input layer captured (P2.4). */
  recordCommand(cmd: TicCmd): void {
    this.recordTic(encodeCmd(quantize(cmd)));
  }

  /** Starts (or resumes) background proving, and asks for persistent storage. */
  async startProving(): Promise<void> {
    if (this.options.program?.journalWords) await this.pipeline.syncGameJournal();
    await requestPersistence();
    this.pipeline.start();
    this.panel.log("proving started (background; the sim and the renderer keep priority)");
  }

  /** No more tics: prove what is left and settle. */
  async finishAndProve(): Promise<void> {
    if (this.options.program?.journalWords) await this.pipeline.syncGameJournal();
    await requestPersistence();
    const chain = await this.pipeline.proveAll();
    if (this.pipeline.state.error) this.panel.log(`Proof refused: ${this.pipeline.state.error}. Export .hellproof to keep the journal, arguments and resource report. This run is not certified.`);
    else this.panel.log(chain?.ok ? `proved chain: ${chain.tics} tics` : `No certified chain: ${chain?.reason ?? "no proof produced"}`);
  }

  /**
   * Re-verifies every stored proof with a prover that never saw it produced, and
   * re-checks the chain from the database — the "verify locally" button.
   */
  async verifyLocally(): Promise<boolean> {
    if (this.disposed || this.verifying) return false;
    this.verifying = true;
    const epoch = this.verificationEpoch;
    const cancelled = () => this.disposed || epoch !== this.verificationEpoch;
    let prover: ProverClient | undefined;
    try {
      const chain = await this.pipeline.verifyPersistedChain();
      if (cancelled()) return false;
      if (!chain.ok) { this.panel.log(`chain rejected: ${chain.reason}`); return false; }
      const segments = await this.store.listSegments(this.run.id);
      if (cancelled()) return false;
      if (segments.length === 0) { this.panel.log("nothing to verify yet"); return false; }
      prover = new ProverClient({ workerUrl: this.options.proverWorkerUrl ?? DEFAULT_PROVER_WORKER_URL });
      this.verification = prover;
      await prover.init({ threads: 1 });
      if (cancelled()) return false;
      for (const segment of segments) {
        const proof = await this.store.getProof(this.run.id, segment.index);
        if (cancelled()) return false;
        if (!proof) { this.panel.log(`segment ${segment.index} has no stored proof`); return false; }
        const valid = await prover.verify(proof);
        if (cancelled()) return false;
        if (!valid) { this.panel.log(`segment ${segment.index} FAILED verification`); return false; }
        this.panel.log(`segment ${segment.index} verified from disk`);
      }
      this.panel.log(`all ${segments.length} proof(s) verified and the chain links up (${chain.tics} tics)`);
      return true;
    } catch (error) {
      if (cancelled()) return false;
      throw error;
    } finally {
      if (prover && this.verification === prover) { prover.terminate(); this.verification = undefined; }
      this.verifying = false;
    }
  }

  /** Cancel an in-flight local verification immediately, including during init. */
  cancelVerification(): void {
    ++this.verificationEpoch;
    this.verification?.terminate(); this.verification = undefined;
  }

  /** C6: nothing leaves this machine until the flag is cleared. */
  async setKeepOffline(keepOffline: boolean): Promise<void> {
    this.run = await this.store.updateRun(this.run.id, { keepOffline });
    this.panel.setKeepOffline(keepOffline);
    this.panel.log(keepOffline ? "run kept offline (C6)" : "run may be submitted");
  }

  async exportRun(): Promise<void> {
    if (this.options.program?.journalWords) await this.pipeline.syncGameJournal();
    const blob = await exportRunBlob(this.store, this.run.id);
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = exportFileName(this.run);
    anchor.click();
    URL.revokeObjectURL(url);
    this.panel.log(`exported ${anchor.download} (${format(blob.size)})`);
  }

  async importRun(file: File): Promise<void> {
    if (this.options.onImport) return this.options.onImport(file);
    const result = await importRun(this.store, await file.arrayBuffer());
    this.panel.log(
      `imported run ${result.runId}: ${result.segments} segment(s), ${result.proofs} proof(s)${result.renamed ? " (renamed: the id was taken)" : ""}`,
    );
  }

  /** Close this proof UI and release both Workers; the game journal remains owned by CairoClient. */
  async dispose(): Promise<void> {
    this.disposed = true; this.cancelVerification();
    try { await this.pipeline.stop(true); }
    finally {
      this.options.program?.dispose?.();
      this.panel.element.remove();
      this.store.close();
    }
  }

  /** The explicit reset C6 demands. */
  async reset(): Promise<void> {
    this.cancelVerification();
    await this.pipeline.stop(true);
    await this.store.deleteRun(this.run.id);
    this.panel.log(`run ${this.run.id} deleted`);
  }

  /**
   * The whole submission: upload to the wrapper, wait for the fold, then the on-chain leg
   * (P4.3) — the cost screen and the signed sequence. Pressing the button again after a
   * "wait" (C6) skips the upload: the batch id is on the run record.
   */
  async submit(): Promise<void> {
    this.run = (await this.store.getRun(this.run.id)) ?? this.run;
    if (this.run.keepOffline) {
      this.panel.log("run kept offline (C6): untick \"Keep offline\" to submit it");
      return;
    }
    const submitter = this.options.wrapperUrl
      ? new WrapperSubmitter({
          baseUrl: this.options.wrapperUrl,
          store: this.store,
          ...(this.options.apiKey ? { apiKey: this.options.apiKey } : {}),
          onProgress: (p) => this.panel.log(`upload ${p.stage}: ${p.uploaded}/${p.total} (${p.mode})`),
        })
      : null;
    let batchId = this.run.submission.batchId;
    try {
      if (!batchId) {
        if (!submitter) {
          this.panel.log("no wrapper configured (VITE_WRAPPER_URL): keeping the run local");
          return;
        }
        const response = await submitter.submit(this.run.id, { waitVerifyMs: 5000 });
        this.panel.log(`wrapper accepted run ${response.run_id} (${response.status})`);
        const status = await submitter.waitForRun(this.run.id, {
          onStatus: (r) => this.panel.log(`wrapper: ${r.status} — ${r.progress.leaves_done}/${r.progress.segments} leaves`),
        });
        if (!status.batch_id) {
          this.panel.log(`wrapper: run ${status.run_id} is ${status.status} with no batch${status.error ? ` — ${status.error}` : ""}`);
          return;
        }
        batchId = status.batch_id;
      }
      if (submitter) {
        const batch = await submitter.fetchBatchSummary(this.run.id, batchId);
        if (batch.status !== "done") {
          this.panel.log(`batch ${batchId} is ${batch.status}: the root proof is not ready yet — press Submit again later`);
          return;
        }
        this.panel.log(`batch ${batchId} done, root proof ${batch.rootProofFeltCount ?? "?"} felts`);
      }
      await this.submitOnChain(batchId, submitter);
    } catch (error) {
      this.panel.log(`submission failed: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  /** The cost screen and, on "submit", the signed sequence (P4.3, C5/C6). */
  private async submitOnChain(batchId: string, submitter: WrapperSubmitter | null): Promise<void> {
    const setup = this.options.onchain;
    if (!setup) {
      this.panel.log(`batch ${batchId} is ready but this page has no on-chain submission: export the run or use infra/submit`);
      return;
    }
    if (!setup.config.ok) {
      this.panel.log(setup.config.message);
      return;
    }
    const config = setup.config.config;
    const fetchBatch = setup.fetchBatch ?? (submitter ? (id: string) => submitter.fetchBatchProof(this.run.id, id) : null);
    if (!fetchBatch) {
      this.panel.log("no wrapper configured (VITE_WRAPPER_URL): the root proof cannot be fetched");
      return;
    }
    const onchain = new OnChainSubmitter({
      config,
      store: this.store,
      host: this.options.host,
      log: (message) => this.panel.log(message),
      fetchBatch,
      connectSigner: setup.connectSigner ?? connectSignerWithController,
      onKeepOffline: () => this.setKeepOffline(true),
      ...(setup.rpc ? { rpc: setup.rpc } : {}),
      ...(setup.priceSource ? { priceSource: setup.priceSource } : {}),
    });
    const outcome = await onchain.open(this.run, batchId);
    this.run = (await this.store.getRun(this.run.id)) ?? this.run;
    if (outcome.error) return;
    if (outcome.choice === "submit") this.panel.log(`run ${this.run.id} is on chain${outcome.fact ? ` (fact ${outcome.fact.slice(0, 14)}…)` : ""}`);
  }
}

/** The browser's signer: a Cartridge Controller session over exactly the submission policies. */
async function connectSignerWithController(config: OnChainConfig): Promise<Signer> {
  const { signer } = await connectController({
    router: config.router,
    doomRuns: config.doomRuns,
    chains: [{ rpcUrl: config.rpcUrl }],
    ...(config.chainId ? { defaultChainId: config.chainId } : {}),
    sponsored: config.sponsored,
  });
  return signer;
}

function format(bytes: number | null | undefined): string {
  if (bytes === null || bytes === undefined) return "?";
  if (bytes >= 2 ** 30) return `${(bytes / 2 ** 30).toFixed(2)} GiB`;
  return `${Math.round(bytes / 2 ** 20)} MiB`;
}

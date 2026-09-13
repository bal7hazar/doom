/**
 * The proving pipeline (roadmap **P3.2**, risks **R6-A1**, **R1-A7**, **R1-A8**).
 *
 * ## Shape
 *
 * ```text
 *   game loop ──► appendTics(words)  ──► journal (in memory, flushed to IndexedDB ~1 Hz)
 *                                           │
 *   ProofPipeline (page thread, orchestration only)
 *        plan K ─► execute ─► resources ─► accept? ─┐ shrink and probe again
 *                                                    ▼
 *                           prove ─► verify ─► chain ─► persist ─► drop the prover
 *                             │
 *   ProverClient ──► prover Worker (@hellproof/prover-wasm) ──► N rayon Workers
 * ```
 *
 * ## Why the orchestrator is on the page's thread
 *
 * Everything expensive is already off it: `execute`, `resources`, `prove` and
 * `verify` all run inside the prover Worker, which blocks on `Atomics.wait` when
 * it has threads. What is left here is `postMessage`, a few `await`s and the
 * IndexedDB writes — and one thing that can only be done from *outside* the
 * prover: killing it. R1-A8's hangs are unobservable from within the Worker that
 * is hung, so the deadline and the single-thread retry have to live on the other
 * side of the message port. Each step is handed to {@link PipelineOptions.schedule},
 * which defaults to `scheduler.postTask({priority: "background"})` where it
 * exists, so the orchestration yields to the sim and render loops (R6-A1).
 *
 * ## Segment lengths
 *
 * The planner ({@link SegmentPlanner}) proposes K, the pipeline *measures* it
 * with a real `execute()` + `resources()`, and only a candidate the prover
 * itself says fits the leaf registry is ever proved. Nothing counts steps to
 * decide a boundary (D1, revised).
 *
 * ## Memory
 *
 * One prover per segment by default (**R1-A7**): `WebAssembly.Memory` never
 * shrinks, so the 2–5 GiB a proof peaks at is only released by dropping the
 * Worker. The cost is re-instantiating the module, which is ~50 ms because the
 * artifact is already in the HTTP cache and V8's code cache.
 */
import type { ProverEvent, ProverInfo } from "@hellproof/prover-wasm";
import type { RunStore } from "../store/runStore.js";
import { projectQuota, readStorageStatus, requestPersistence } from "../store/quota.js";
import { verifyChain, type ChainResult } from "./chain.js";
import { normalizeFelt } from "./felt.js";
import { DEFAULT_PLANNER_CONFIG, SegmentPlanner, rawMaxComponentRows, type PlannerConfig } from "./planner.js";
import { decodeSegmentOutput, splitPreimage, type SegmentProgram } from "./program.js";
import { ProverClient, ProverTimeoutError, type ProverLike } from "./proverClient.js";
import { TicLog } from "./ticcmd.js";
import { SegmentStatus } from "./types.js";
import type {
  Felt,
  PipelineEvent,
  RunRecord,
  SegmentOutput,
  SegmentRecord,
  SegmentResources,
} from "./types.js";

export interface PipelineOptions {
  store: RunStore;
  program: SegmentProgram;
  /** URL of the prover Worker, served statically out of `public/prover/`. */
  proverWorkerUrl: string | URL;
  /** Overrides for the two 45 MB artifacts; the package's defaults are relative to itself. */
  wasmUrl?: string;
  threadedWasmUrl?: string;
  /**
   * `"auto"` = `min(4, hardwareConcurrency - 2)` when the page is cross-origin
   * isolated, 1 otherwise (R6-A1 leaves two cores to the game; 4 is where the
   * wasm allocator's spin lock starts winning, P3.1 §Threads).
   */
  threads?: number | "auto";
  planner?: Partial<PlannerConfig>;
  /** Deadline of one threaded `prove()`. Past it the Worker is killed (R1-A8). */
  proveTimeoutMs?: number;
  /** Deadline of the single-threaded retry — it is ~3x slower, so it gets more. */
  singleThreadProveTimeoutMs?: number;
  /** Drop the prover after every segment to release its linear memory (R1-A7). */
  freshProverPerSegment?: boolean;
  /** Flush the journal to IndexedDB every N tics. */
  journalFlushTics?: number;
  /** Yields the orchestration below the sim/render loops. */
  schedule?: (fn: () => void) => void;
  onEvent?: (event: PipelineEvent) => void;
  /** Injected by the tests. */
  createProver?: (options: { onEvent: (e: ProverEvent) => void }) => ProverLike;
}

export interface PipelineState {
  runId: string;
  running: boolean;
  /** Segments proved and verified. */
  proved: number;
  /** Segments known (proved or in flight). */
  total: number;
  ticsRecorded: number;
  ticsPlanned: number;
  threads: number;
  peakMemoryBytes: number;
  chain: ChainResult | null;
  error?: string;
}

const IDLE_POLL_MS = 100;

function defaultSchedule(fn: () => void): void {
  const scheduler = (globalThis as { scheduler?: { postTask(cb: () => void, o?: unknown): unknown } })
    .scheduler;
  if (scheduler?.postTask) {
    void Promise.resolve(scheduler.postTask(fn, { priority: "background" })).catch(() => fn());
    return;
  }
  setTimeout(fn, 0);
}

/** `min(4, hardwareConcurrency - 2)`, and 1 without cross-origin isolation. */
export function autoThreadCount(): number {
  if (globalThis.crossOriginIsolated !== true) return 1;
  const cores = globalThis.navigator?.hardwareConcurrency ?? 4;
  return Math.max(1, Math.min(4, cores - 2));
}

// Admission failures remain resumable, but a different thread count cannot repair stale sizing.
class ResourceAdmissionError extends Error {}

export class ProofPipeline {
  private readonly options: Required<
    Pick<
      PipelineOptions,
      | "proveTimeoutMs"
      | "singleThreadProveTimeoutMs"
      | "freshProverPerSegment"
      | "journalFlushTics"
      | "schedule"
    >
  > &
    PipelineOptions;
  readonly planner: SegmentPlanner;
  private readonly store: RunStore;
  private readonly program: SegmentProgram;

  private run: RunRecord | null = null;
  private journal = new TicLog();
  private flushedTics = 0;
  private segments: SegmentRecord[] = [];
  private prover: ProverLike | null = null;
  private proverInfo: ProverInfo | null = null;
  private threads = 1;
  private peakMemoryBytes = 0;
  private running = false;
  private stopping = false;
  private flushing = false;
  private loopPromise: Promise<void> | null = null;
  private wake: (() => void) | null = null;
  private chain: ChainResult | null = null;
  private lastError: string | undefined;
  private currentStageDetail: string | undefined;

  constructor(options: PipelineOptions) {
    this.options = {
      proveTimeoutMs: 10 * 60_000,
      singleThreadProveTimeoutMs: 30 * 60_000,
      freshProverPerSegment: true,
      journalFlushTics: 35,
      schedule: defaultSchedule,
      ...options,
    };
    this.store = options.store;
    this.program = options.program;
    this.planner = new SegmentPlanner({ ...DEFAULT_PLANNER_CONFIG, ...options.planner });
  }

  private emit(event: PipelineEvent): void {
    this.options.onEvent?.(event);
  }

  /** Yields to the sim/render loops between pipeline steps (R6-A1). */
  private yieldToGame(): Promise<void> {
    return new Promise((resolve) => this.options.schedule(resolve));
  }

  // -- run lifecycle --------------------------------------------------------

  /**
   * Attaches to a run: a fresh one, or an existing one whose unfinished segments
   * are re-queued (R1-A7 — "reload the tab mid-proof and resume without loss").
   */
  async attach(runId?: string): Promise<RunRecord> {
    const existing = runId ? await this.store.getRun(runId) : undefined;
    let run =
      existing ??
      (await this.store.createRun({
        ...(runId ? { id: runId } : {}),
        program: this.program.id,
        programHashFunction: this.program.hashFunction,
        genesis: normalizeFelt(this.program.genesis),
      }));
    if (existing && (this.program.identity || run.programIdentity) && (run.program !== this.program.id || run.programHashFunction !== this.program.hashFunction
        || normalizeFelt(run.genesis) !== normalizeFelt(this.program.genesis)
        || run.programIdentity !== this.program.identity)) throw new Error("incompatible persisted program identity; export the old run before switching engines");
    if (!existing && this.program.identity) run = await this.store.updateRun(run.id, { programIdentity: this.program.identity });
    this.run = run;

    const inputs = await this.store.getInputs(run.id);
    this.journal = TicLog.fromPersisted(inputs.packed, inputs.tail);
    this.flushedTics = this.journal.length;
    this.program.validateJournal?.(this.journal.toWords());

    this.segments = await this.store.listSegments(run.id);
    let requeued = 0;
    for (const segment of this.segments) {
      if (this.program.prepareArgs) {
        const args = await this.program.prepareArgs({ hIn: segment.output?.hIn ?? run.genesis,
          ticStart: segment.ticStart, ticCount: segment.ticEnd - segment.ticStart,
          words: this.journal.slice(segment.ticStart, segment.ticEnd), index: segment.index });
        if (JSON.stringify(args) !== JSON.stringify(segment.args)) throw new Error("persisted arguments differ from genesis journal replay");
        this.program.validateOutput?.(args, segment.outputPreimage);
      }
      if (segment.stage !== "proved") {
        segment.stage = "planned";
        delete segment.error;
        requeued++;
        await this.store.putSegment(segment);
      }
    }
    if (requeued > 0) {
      this.emit({
        type: "log",
        level: "info",
        message: `resumed run ${run.id}: ${this.segments.length - requeued} proved, ${requeued} re-queued`,
      });
    }
    this.recomputeChain();
    this.emit({ type: "run", run });
    return run;
  }

  get state(): PipelineState {
    return {
      runId: this.run?.id ?? "",
      running: this.running,
      proved: this.segments.filter((s) => s.stage === "proved").length,
      total: this.segments.length,
      ticsRecorded: this.journal.length,
      ticsPlanned: this.run?.ticsPlanned ?? 0,
      threads: this.threads,
      peakMemoryBytes: this.peakMemoryBytes,
      chain: this.chain,
      ...(this.lastError === undefined ? {} : { error: this.lastError }),
    };
  }

  /** A snapshot of the segments, for the queue panel. */
  get segmentRecords(): readonly SegmentRecord[] {
    return this.segments;
  }

  // -- input ---------------------------------------------------------------

  /** Copy the acknowledged game journal, including play before the proof UI was opened. */
  async syncGameJournal(): Promise<void> {
    if (!this.program.journalWords) throw new Error("program has no game journal");
    const words = this.program.journalWords();
    const prior = this.journal.toWords();
    if (prior.length > words.length || prior.some((w, i) => words[i] !== w)) throw new Error("game journal changed its persisted prefix");
    await this.appendTics(words.slice(prior.length));
    await this.flushJournal();
  }

  /** Feeds the journal. `words` are 32-bit `ticcmd` words, one per tic. */
  async appendTics(words: readonly number[]): Promise<void> {
    this.program.validateJournal?.([...this.journal.toWords(), ...words]);
    for (const word of words) this.journal.push(word);
    if (this.journal.length - this.flushedTics >= this.options.journalFlushTics) {
      await this.flushJournal();
    }
    this.wake?.();
  }

  /** Persists the journal. Called on a timer, on `finish()` and on `stop()`. */
  async flushJournal(): Promise<void> {
    if (!this.run) return;
    this.flushedTics = this.journal.length;
    await this.store.putInputs({
      runId: this.run.id,
      ticCount: this.journal.length,
      packed: [...this.journal.completeFelts],
      tail: [...this.journal.tailWords],
    });
    this.run = { ...this.run, ticCount: this.journal.length };
  }

  /**
   * No more tics will arrive: the pipeline stops waiting for a full-size segment
   * and cuts whatever is left (possibly a short one).
   *
   * This is *not* "the game was finished": a player who quits halfway closes the
   * journal too. Whether the run is complete is the last segment's `status`
   * (D14), which only the program can say, so `RunRecord.finished` is set when a
   * proved segment comes back with a terminal one.
   */
  async finish(): Promise<void> {
    this.flushing = true;
    await this.flushJournal();
    if (this.run) this.run = await this.store.updateRun(this.run.id, { stage: "proving" });
    this.wake?.();
  }

  // -- the loop -------------------------------------------------------------

  /** Starts proving. Returns as soon as the loop is running. */
  start(): void {
    if (this.running) return;
    if (!this.run) throw new Error("call attach() before start()");
    this.lastError = undefined;
    this.running = true;
    this.stopping = false;
    this.loopPromise = this.loop().catch((error: unknown) => {
      this.dropProver();
      this.program.releasePreparation?.();
      this.lastError = error instanceof Error ? error.message : String(error);
      this.emit({ type: "log", level: "error", message: `pipeline stopped: ${this.lastError}` });
      this.running = false;
    });
  }

  /** Stops after the segment in flight; `hard` kills the prover immediately. */
  async stop(hard = false): Promise<void> {
    this.stopping = true;
    this.wake?.();
    if (hard) { this.dropProver(); this.program.releasePreparation?.(); }
    await this.loopPromise?.catch(() => undefined);
    this.running = false;
    await this.flushJournal();
  }

  /** Proves everything that is left and resolves when the run is complete. */
  async proveAll(): Promise<ChainResult | null> {
    await this.finish();
    if (!this.running) this.start();
    await this.loopPromise;
    return this.chain;
  }

  private async loop(): Promise<void> {
    while (!this.stopping) {
      const pending = this.segments.find((s) => s.stage !== "proved");
      if (pending) {
        await this.proveSegment(pending);
        continue;
      }
      const planned = await this.planNext();
      if (planned) continue;
      if (this.flushing) break;
      await this.idle();
    }
    this.running = false;
    await this.flushJournal();
    this.dropProver();
    this.program.releasePreparation?.();
  }

  private idle(): Promise<void> {
    return new Promise<void>((resolve) => {
      let done = false;
      const finish = (): void => {
        if (done) return;
        done = true;
        this.wake = null;
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(finish, IDLE_POLL_MS);
      this.wake = finish;
    });
  }

  // -- planning -------------------------------------------------------------

  /**
   * Cuts the next segment, if one can be cut: proposes K, measures it, shrinks
   * until `resources()` approves, and persists the boundary with the ten felts
   * the execution already produced — the chain is checked *before* anything is
   * proved, so a broken chain costs no proving time.
   */
  private async planNext(): Promise<boolean> {
    const run = this.run;
    if (!run) return false;
    const available = this.journal.length - run.ticsPlanned;
    if (available <= 0) return false;

    // What the planner would cut with an unlimited journal, and what it can cut
    // with this one. Mid-game, a segment shorter than the model's ideal is not
    // worth cutting: a proof costs the same fixed 2^21-row trees whatever it
    // carries, so a half-full segment doubles the work for the same game.
    const wanted = this.planner.propose(Number.MAX_SAFE_INTEGER, this.threads);
    let candidate = Math.min(wanted, available);
    if (candidate <= 0) return false;
    if (!this.flushing && candidate < wanted) return false;

    const prover = await this.ensureProver();
    const index = this.segments.length;
    const previous = this.segments[index - 1];
    const hIn = previous?.output ? previous.output.hOut : normalizeFelt(run.genesis);
    const ticStart = previous?.output ? previous.output.ticEnd : 0;
    const startedAt = performance.now();

    const executable = await this.program.executableJson();
    let probes = 0;
    for (;;) {
      probes++;
      const words = this.journal.slice(ticStart, ticStart + candidate);
      const request = { hIn, ticStart, ticCount: candidate, words, index };
      const args = this.program.prepareArgs ? await this.program.prepareArgs(request) : this.program.encodeArgs(request);
      this.emitProgress(index, "executing", startedAt);
      const executed = await prover.execute(executable, args);
      this.program.validateOutput?.(args, executed.stats.output_preimage);
      await this.yieldToGame();
      const summary = await prover.resources(executed.input);
      const verdict = this.planner.judge(candidate, summary, this.threads);

      if (verdict.verdict === "accept") {
        const { output } = splitPreimage(executed.stats.output_preimage);
        const raw = rawMaxComponentRows(summary);
        const resources: SegmentResources = {
          nSteps: summary.n_steps,
          maxComponent: summary.max_component,
          maxComponentRows: summary.max_component_rows,
          logMaxComponentSize: summary.log_max_component_size,
          utilisation: raw.rows / this.planner.rowCeiling,
          fitsLeafRegistry: summary.fits_leaf_registry,
        };
        const segment: SegmentRecord = {
          runId: run.id,
          index,
          ticStart,
          ticEnd: output.ticEnd,
          args,
          outputPreimage: executed.stats.output_preimage,
          publicOutputs: executed.stats.output,
          output,
          stage: "planned",
          proofBytes: 0,
          verified: false,
          attempts: 0,
          threads: this.threads,
          retriedSingleThread: false,
          timings: { executeMs: executed.ms, resourcesMs: 0 },
          memoryBytes: prover.peakMemoryBytes,
          resources,
          submission: "local",
          updatedAt: Date.now(),
        };
        this.assertSegmentMatches(segment, hIn, ticStart, candidate);
        this.segments.push(segment);
        await this.store.putSegment(segment);
        this.run = await this.store.updateRun(run.id, {
          ticsPlanned: output.ticEnd,
          segments: this.segments.length,
          stage: "proving",
        });
        this.recomputeChain();
        this.emit({ type: "segment", segment, total: this.segments.length });
        this.emit({
          type: "log",
          level: "info",
          message: `segment ${index}: ${candidate} tics, ${summary.n_steps} steps, ${summary.max_component} at ${Math.round(resources.utilisation * 100)} % of 2^${this.planner.config.maxComponentLogSize} rows (${probes} probe${probes > 1 ? "s" : ""})`,
        });
        return true;
      }

      if (this.program.identity) {
        await this.flushJournal();
        this.run = await this.store.updateRun(run.id, { admissionFailure: {
          ticStart, ticCount: candidate, args, outputPreimage: executed.stats.output_preimage,
          reason: verdict.reason, resources: summary, updatedAt: Date.now(),
        } });
      }
      if (verdict.verdict === "impossible") {
        throw new Error(`no segment length fits the leaf registry: ${verdict.reason}`);
      }
      this.emit({
        type: "log",
        level: "warn",
        message: `segment ${index}: ${candidate} tics rejected (${verdict.reason}); retrying with ${verdict.tics}`,
      });
      candidate = verdict.tics;
      if (probes >= this.planner.config.maxProbes) {
        candidate = Math.max(this.planner.config.minTics, Math.floor(candidate / 2));
      }
      await this.yieldToGame();
    }
  }

  /** The executable must agree with what we asked for; anything else is a bug. */
  private assertSegmentMatches(
    segment: SegmentRecord,
    hIn: Felt,
    ticStart: number,
    requested: number,
  ): void {
    const out = segment.output as SegmentOutput;
    if (normalizeFelt(out.hIn) !== normalizeFelt(hIn)) {
      throw new Error(`segment ${segment.index}: the program returned h_in ${out.hIn}, expected ${hIn}`);
    }
    if (out.ticStart !== ticStart) {
      throw new Error(`segment ${segment.index}: tic_start ${out.ticStart}, expected ${ticStart}`);
    }
    if (out.ticEnd > ticStart + requested) {
      throw new Error(
        `segment ${segment.index}: tic_end ${out.ticEnd} runs past the ${requested} tics it was given`,
      );
    }
  }

  // -- proving --------------------------------------------------------------

  private async proveSegment(segment: SegmentRecord): Promise<void> {
    const run = this.run;
    if (!run) return;
    const startedAt = performance.now();
    const executable = await this.program.executableJson();
    let singleThread = segment.retriedSingleThread;

    for (let attempt = 0; attempt < 2; attempt++) {
      const prover = await this.ensureProver(singleThread ? 1 : undefined);
      try {
        segment.stage = "executing";
        segment.attempts++;
        this.emitProgress(segment.index, "executing", startedAt);
        if (this.program.prepareArgs) {
          const args = await this.program.prepareArgs({ hIn: segment.output?.hIn ?? run.genesis,
            ticStart: segment.ticStart, ticCount: segment.ticEnd - segment.ticStart,
            words: this.journal.slice(segment.ticStart, segment.ticEnd), index: segment.index });
          if (JSON.stringify(args) !== JSON.stringify(segment.args)) throw new Error("persisted arguments differ from genesis replay");
        }
        const executed = await prover.execute(executable, segment.args);
        this.program.validateOutput?.(segment.args, executed.stats.output_preimage);
        await this.yieldToGame();

        // Re-execution after reload/retry must be admitted with this worker's fresh counters.
        // Use a separate policy evaluator so the repeated probe does not train the planner twice.
        const summary = await prover.resources(executed.input);
        const admission = new SegmentPlanner(this.planner.config).judge(
          segment.ticEnd - segment.ticStart, summary, singleThread ? 1 : this.threads,
        );
        if (admission.verdict !== "accept") {
          throw new ResourceAdmissionError(`fresh execution is not admissible: ${admission.reason}`);
        }

        segment.stage = "proving";
        this.emitProgress(segment.index, "proving", startedAt);
        const timeout = singleThread
          ? this.options.singleThreadProveTimeoutMs
          : this.options.proveTimeoutMs;
        const t0 = performance.now();
        const proved = await prover.prove(executed.input, timeout);
        const proveMs = performance.now() - t0;
        await this.yieldToGame();

        segment.stage = "verifying";
        this.emitProgress(segment.index, "verifying", startedAt);
        const tVerify = performance.now();
        const valid = await prover.verify(proved.proof);
        const verifyMs = performance.now() - tVerify;
        if (!valid) throw new Error("the prover refused its own proof");

        // The outputs are re-read from *this* execution: a retry must not inherit
        // the boundary's felts on trust.
        const { output } = splitPreimage(executed.stats.output_preimage);
        segment.output = output;
        segment.outputPreimage = executed.stats.output_preimage;
        segment.publicOutputs = executed.stats.output;
        segment.ticEnd = output.ticEnd;
        segment.proofBytes = proved.proof.byteLength;
        segment.verified = true;
        segment.threads = singleThread ? 1 : this.threads;
        segment.retriedSingleThread = singleThread && attempt > 0;
        segment.memoryBytes = Math.max(segment.memoryBytes, prover.peakMemoryBytes);
        segment.timings = {
          executeMs: executed.ms,
          proveMs,
          verifyMs,
          totalMs: performance.now() - startedAt,
        };
        segment.stage = "proved";
        delete segment.error;
        this.peakMemoryBytes = Math.max(this.peakMemoryBytes, prover.peakMemoryBytes);

        await this.persistProof(segment, proved.proof);
        if (output.status !== SegmentStatus.RUNNING && this.run && !this.run.finished) {
          this.run = await this.store.updateRun(this.run.id, { finished: true });
        }
        this.recomputeChain();
        this.emit({ type: "segment", segment, total: this.segments.length });
        this.emit({
          type: "log",
          level: "info",
          message: `segment ${segment.index} proved in ${(proveMs / 1000).toFixed(1)} s on ${segment.threads} thread(s), ${(proved.proof.byteLength / 1e6).toFixed(2)} MB, verified in ${verifyMs.toFixed(0)} ms, peak ${(segment.memoryBytes / 2 ** 30).toFixed(2)} GiB`,
        });
        if (this.options.freshProverPerSegment) this.dropProver();
        await this.maybeWarnAboutQuota();
        return;
      } catch (error) {
        const timedOut = error instanceof ProverTimeoutError;
        this.dropProver();
        const message = error instanceof Error ? error.message : String(error);
        if (!(error instanceof ResourceAdmissionError) && attempt === 0 && !singleThread && this.threads > 1) {
          // R1-A8: the threaded path is the one that hangs. One retry, single
          // threaded, which has never failed in S2 or P3.1.
          singleThread = true;
          segment.retriedSingleThread = true;
          this.emit({
            type: "log",
            level: "warn",
            message: `segment ${segment.index} ${timedOut ? "timed out" : "failed"} with ${this.threads} threads (${message}); retrying single-threaded (R1-A8)`,
          });
          segment.stage = "planned";
          await this.store.putSegment(segment);
          await this.yieldToGame();
          continue;
        }
        segment.stage = "failed";
        segment.error = message;
        await this.store.putSegment(segment);
        this.emit({ type: "segment", segment, total: this.segments.length });
        throw new Error(`segment ${segment.index} could not be proved: ${message}`);
      }
    }
  }

  private async persistProof(segment: SegmentRecord, proof: Uint8Array): Promise<void> {
    try {
      await this.store.putSegment(segment, proof);
    } catch (error) {
      // A quota failure must not lose the proof silently: the segment stays
      // `failed`, the UI offers an export, and the run is resumable after a reset.
      segment.stage = "failed";
      segment.error = error instanceof Error ? error.message : String(error);
      await this.store.putSegment(segment).catch(() => undefined);
      throw error;
    }
  }

  private async maybeWarnAboutQuota(): Promise<void> {
    const status = await readStorageStatus();
    const pending = Math.max(0, this.segments.filter((s) => s.stage !== "proved").length);
    const projection = projectQuota(status, pending + 2);
    this.emit({
      type: "quota",
      usageBytes: status.usageBytes ?? 0,
      quotaBytes: status.quotaBytes ?? 0,
      persisted: status.persisted,
      warning: projection.warning,
    });
    if (projection.warning) {
      this.emit({ type: "log", level: "warn", message: projection.message });
    }
  }

  // -- prover lifecycle -----------------------------------------------------

  private async ensureProver(forceThreads?: number): Promise<ProverLike> {
    if (this.prover && !this.prover.isDead && (forceThreads === undefined || this.threads === forceThreads)) {
      return this.prover;
    }
    this.dropProver();
    const onEvent = (event: ProverEvent): void => {
      if (event.type === "log") {
        this.emit({ type: "log", level: event.level, message: event.message });
      } else if (event.type === "span") {
        this.currentStageDetail = event.name;
      }
      if (event.type !== "log") {
        this.peakMemoryBytes = Math.max(this.peakMemoryBytes, event.memoryBytes);
      }
    };
    const prover = this.options.createProver
      ? this.options.createProver({ onEvent })
      : new ProverClient({ workerUrl: this.options.proverWorkerUrl, onEvent });
    const want = forceThreads ?? (this.options.threads ?? "auto");
    this.prover = prover; // Own the Worker before its asynchronous initialization.
    try {
      const info = await prover.init({
        threads: want === "auto" ? autoThreadCount() : want,
        ...(this.options.wasmUrl ? { wasmUrl: this.options.wasmUrl } : {}),
        ...(this.options.threadedWasmUrl ? { threadedWasmUrl: this.options.threadedWasmUrl } : {}),
      });
      if (this.prover !== prover || prover.isDead || this.stopping) throw new Error("prover initialization cancelled");
      this.proverInfo = info;
      this.threads = info.threads;
      this.emit({
        type: "prover",
        threads: info.threads,
        threaded: info.threaded,
        wasmUrl: info.wasmUrl,
        instantiateMs: info.instantiateMs,
      });
      return prover;
    } catch (error) {
      if (this.prover === prover) this.dropProver();
      throw error;
    }
  }

  private dropProver(): void {
    this.prover?.terminate();
    this.prover = null;
  }

  /** What `init()` reported for the prover currently loaded. */
  get currentProverInfo(): ProverInfo | null {
    return this.proverInfo;
  }

  // -- chain ----------------------------------------------------------------

  private recomputeChain(): void {
    const run = this.run;
    if (!run) return;
    const outputs = this.segments
      .filter((s) => s.output !== null)
      .map((s) => s.output as SegmentOutput);
    if (outputs.length === 0) {
      this.chain = null;
      return;
    }
    this.chain = verifyChain(outputs, {
      genesis: normalizeFelt(run.genesis),
      requireFinished: run.finished,
    });
    this.emit({
      type: "chain",
      ok: this.chain.ok,
      ...(this.chain.reason ? { reason: this.chain.reason } : {}),
      segments: outputs.length,
    });
  }

  /** Re-reads the run from the database and re-checks the chain end to end. */
  async verifyPersistedChain(): Promise<ChainResult> {
    const run = this.run;
    if (!run) throw new Error("no run attached");
    const segments = await this.store.listSegments(run.id);
    const outputs = segments
      .filter((s) => s.output !== null || s.outputPreimage.length > 0)
      .map((s) => s.output ?? decodeSegmentOutput(s.outputPreimage.slice(1)));
    return verifyChain(outputs, {
      genesis: normalizeFelt(run.genesis),
      requireFinished: run.finished,
    });
  }

  /** Asks for persistent storage up front, so proofs are not evicted (P2.5). */
  async requestPersistentStorage(): Promise<boolean> {
    return requestPersistence();
  }

  private emitProgress(index: number, stage: SegmentRecord["stage"], startedAt: number): void {
    this.emit({
      type: "progress",
      index,
      total: Math.max(this.segments.length, index + 1),
      stage,
      elapsedMs: performance.now() - startedAt,
      memoryBytes: this.prover?.peakMemoryBytes ?? 0,
      ...(this.currentStageDetail ? { detail: this.currentStageDetail } : {}),
    });
  }
}

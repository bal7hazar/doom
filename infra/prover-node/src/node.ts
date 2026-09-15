// SPDX-License-Identifier: Apache-2.0
/**
 * The node: discovery, selection, and a per-commitment stage machine that every relaunch
 * resumes from the last persisted stage.
 *
 * ```text
 *   poll ─► discover (RunCommitted − CommitmentSettled) ─► policy ─► queue
 *            resume pending jobs first, then the newly selected ones
 *
 *   job: discovered ─► reconstructed ─► cut ─► proving ─► proved ─► folding ─► folded
 *        ─► registering ─► registered           (refused: the commitment itself is invalid;
 *                                                failed: gave up after maxAttempts)
 * ```
 *
 * Every stage is a pluggable interface (`EventSource`, `Executor`, `Prover`, `WrapperClient`,
 * `RpcClient` + `Signer`), which is what makes the whole machine testable without a proof or a
 * network: `test/node.test.ts` runs it end to end on fakes.
 */
import type { BatchResponse as ChainBatchResponse } from "../../../client/src/chain/batch.js";
import { parseWrapperBatch } from "../../../client/src/chain/batch.js";
import type { RpcClient } from "../../../client/src/chain/rpc.js";
import type { EchoStore } from "../../../client/src/chain/sequence.js";
import type { Signer } from "../../../client/src/chain/signer.js";
import type { PlannerConfig } from "../../../client/src/prove/planner.js";
import type { Felt } from "../../../client/src/prove/types.js";
import type { WrapperClient } from "../../../prover/wrapper/client-ts/src/index.js";
import type { EventSource } from "../../indexer/src/types.js";
import type { RunCommitment } from "./commitments.js";
import { discoverOnce, type DiscoveryResult, type DiscoveryState, type FileDiscoveryStore } from "./discovery.js";
import type { Executor } from "./executor.js";
import { foldRun } from "./fold.js";
import { reconstructJournal } from "./journal.js";
import type { Logbook } from "./log.js";
import type { MetricsFile } from "./metrics.js";
import { selectCommitments, type Selection, type SelectionPolicy } from "./policy.js";
import type { Prover } from "./prover.js";
import { proveSegments } from "./proving.js";
import { registerRun, type RegisterOptions } from "./register.js";
import { cutJournal } from "./segmenter.js";
import { newJob, type FileJobStore, type JobRecord, type JobStage } from "./store.js";

/** The commitment is invalid or unprovable: never retried. */
export class RefusedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RefusedError";
  }
}

export interface NodeConfig {
  doomRuns: string;
  router: string;
  startBlock: number;
  reorgDepth?: number;
  policy: SelectionPolicy;
  planner?: Partial<PlannerConfig>;
  threads?: number;
  proofTimeoutMs?: number;
  /** Expected genesis per `"<version>:<level>"`, when the operator pins it; else the commitment's. */
  genesis?: Record<string, Felt>;
  /** Program hash every proof must carry (the version table's); unchecked when absent. */
  programHash?: Felt;
  wrapperPollMs?: number;
  wrapperTimeoutMs?: number;
  /** Stop after this stage (a dry run): `cut`, `proved` or `folded`. */
  stopAfter?: "cut" | "proved" | "folded";
  replay?: boolean;
  maxAttempts?: number;
}

export interface NodeDeps {
  source: EventSource;
  executor: Executor;
  prover: Prover;
  wrapper: WrapperClient | null;
  rpc: RpcClient | null;
  signer: Signer | null;
  echoStore: EchoStore;
  /** Test hook: bounds for the registration sequence. */
  estimate?: RegisterOptions["estimate"];
  estimateCall?: RegisterOptions["estimateCall"];
}

export interface NodeStores {
  jobs: FileJobStore;
  discovery: FileDiscoveryStore;
  metrics: MetricsFile;
  log: Logbook;
}

export interface PollOutcome {
  discovery: DiscoveryResult;
  selection: Selection;
  processed: JobRecord[];
}

const TERMINAL: JobStage[] = ["registered", "refused", "failed"];
const isTerminal = (j: JobRecord): boolean => TERMINAL.includes(j.stage);

export class ProverNode {
  private discoveryState: DiscoveryState;

  constructor(
    readonly config: NodeConfig,
    readonly deps: NodeDeps,
    readonly stores: NodeStores,
  ) {
    this.discoveryState = stores.discovery.load();
  }

  /** One poll: resume what is pending, discover, select, process. */
  async pollOnce(): Promise<PollOutcome> {
    const { jobs, metrics, log } = this.stores;
    const processed: JobRecord[] = [];

    const discovery = await discoverOnce(this.deps.source, this.discoveryState, {
      address: this.config.doomRuns,
      startBlock: this.config.startBlock,
      ...(this.config.reorgDepth !== undefined ? { reorgDepth: this.config.reorgDepth } : {}),
    });
    this.stores.discovery.save(this.discoveryState);
    metrics.poll();
    metrics.bump("commitmentsSeen", discovery.seen);
    log.info(`poll: blocks ${discovery.fromBlock}..${discovery.head}, ${discovery.seen} commitment event(s), ${discovery.open.length} open, ${discovery.incomplete.length} incomplete`);
    for (const i of discovery.incomplete) log.warn(`journal incomplete: ${i.reason}`, i.commitmentId);

    // Pending work first: a job interrupted mid-way, or one whose race was lost meanwhile.
    const me = this.deps.signer ? BigInt(this.deps.signer.address) : null;
    for (const job of jobs.list().filter((j) => !isTerminal(j))) {
      const settled = this.discoveryState.settled[job.commitment.commitmentId];
      if (settled && (settled.kind === "CommitmentReclaimed" || BigInt(settled.prover) !== me)) {
        job.stage = "failed";
        job.error =
          settled.kind === "CommitmentReclaimed"
            ? "reclaimed by its player before this node finished"
            : `proved by ${settled.prover} (run ${settled.runId}) before this node finished`;
        jobs.put(job);
        metrics.bump("lostRace");
        log.warn(job.error, job.commitment.commitmentId);
        continue;
      }
      processed.push(await this.process(job));
    }

    const all = jobs.list();
    const selection = selectCommitments(discovery.open, this.config.policy, {
      done: new Set(all.filter(isTerminal).map((j) => j.commitment.commitmentId)),
      inFlight: new Set(all.filter((j) => !isTerminal(j)).map((j) => j.commitment.commitmentId)),
    });
    metrics.bump("selected", selection.selected.length);
    metrics.bump("skipped", selection.skipped.length);
    for (const s of selection.skipped) log.info(`skipped: ${s.reason}`, s.commitmentId);
    for (const c of selection.selected) {
      log.info(`selected: ${c.tics} tics, bounty ${c.bounty} FRI, version ${c.versionId} level ${c.levelId}, by ${c.player}`, c.commitmentId);
      processed.push(await this.process(jobs.put(newJob(c))));
    }
    return { discovery, selection, processed };
  }

  /** Runs `pollOnce` every `intervalMs` until `signal` aborts; an error never stops the loop. */
  async watch(intervalMs: number, signal?: AbortSignal): Promise<void> {
    while (!signal?.aborted) {
      try {
        await this.pollOnce();
      } catch (e) {
        this.stores.log.error(`poll failed: ${(e as Error).message}`);
      }
      if (signal?.aborted) break;
      await new Promise<void>((resolve) => {
        const t = setTimeout(resolve, intervalMs);
        signal?.addEventListener("abort", () => {
          clearTimeout(t);
          resolve();
        }, { once: true });
      });
    }
  }

  /** Advances one job from its persisted stage as far as it can go. */
  async process(job: JobRecord): Promise<JobRecord> {
    const { jobs, metrics, log } = this.stores;
    const id = job.commitment.commitmentId;
    const stageLog = log.for(id);
    const stopAfter = this.config.stopAfter;
    try {
      if (job.stage === "discovered") {
        await this.timed(job, "reconstructed", async () => {
          const expected = this.config.genesis?.[`${job.commitment.versionId}:${job.commitment.levelId}`];
          try {
            reconstructJournal(job.commitment, {
              ...(expected ? { genesis: expected } : {}),
              ...(this.discoveryState.lastBlock !== null ? { head: this.discoveryState.lastBlock } : {}),
            });
          } catch (e) {
            throw new RefusedError((e as Error).message);
          }
          stageLog(`journal reconstructed: ${job.commitment.tics} tics, commitment verified`);
        });
      }
      if (job.stage === "reconstructed") {
        await this.timed(job, "cut", async () => {
          const { words } = reconstructJournal(job.commitment);
          let cut;
          try {
            cut = await cutJournal(this.deps.executor, words, {
              genesis: job.commitment.genesis,
              levelId: job.commitment.levelId,
              ...(this.config.planner ? { planner: this.config.planner } : {}),
              ...(this.config.threads !== undefined ? { threads: this.config.threads } : {}),
              log: stageLog,
            });
          } catch (e) {
            // The runtime disagreeing with the journal is final; the runtime failing is not.
            const m = (e as Error).message;
            if (/ABORT|genesis|still RUNNING|past the terminal|segment chain|expected|7-tic/.test(m)) throw new RefusedError(m);
            throw e;
          }
          job.segments = cut.segments;
          metrics.bump("segmentsCut", cut.segments.length);
          stageLog(`cut into ${cut.segments.length} segment(s), chain ${cut.chain.ok ? "continuous" : "broken"}, final status ${cut.chain.finalStatus}`);
        });
        if (stopAfter === "cut") return jobs.put(job);
      }
      if (job.stage === "cut" || job.stage === "proving") {
        await this.timed(job, "proved", async () => {
          const before = job.proved.length;
          try {
            await proveSegments(job, jobs, this.deps.prover, {
              ...(this.config.proofTimeoutMs !== undefined ? { timeoutMs: this.config.proofTimeoutMs } : {}),
              ...(this.config.programHash ? { programHash: this.config.programHash } : {}),
              log: stageLog,
            });
          } finally {
            metrics.bump("segmentsProved", job.proved.length - before);
          }
        }, () => metrics.bump("proofFailures"));
        if (stopAfter === "proved") return jobs.put(job);
      }
      if (job.stage === "proved" || job.stage === "folding") {
        if (!this.deps.wrapper) throw new Error("no wrapper configured (--wrapper)");
        const wrapper = this.deps.wrapper;
        await this.timed(job, "folded", async () => {
          job.stage = "folding";
          jobs.put(job);
          const artifacts = job.segments!.map((s) => {
            const a = jobs.getProof(id, s.index);
            if (!a) throw new Error(`proof ${s.index} missing on disk`);
            return a;
          });
          const folded = await foldRun({
            client: wrapper,
            job,
            artifacts,
            ...(this.config.wrapperPollMs !== undefined ? { pollMs: this.config.wrapperPollMs } : {}),
            ...(this.config.wrapperTimeoutMs !== undefined ? { timeoutMs: this.config.wrapperTimeoutMs } : {}),
            log: stageLog,
          });
          jobs.putBatch(id, {
            batch_id: folded.response.batch_id,
            leaves: folded.response.leaves,
            packed_output: folded.response.packed_output,
            root_proof_felts: folded.response.root_proof_felts,
            logs: folded.batch.logs?.map((l) => l.map((f) => "0x" + f.toString(16))) ?? [],
          });
        });
        if (stopAfter === "folded") return jobs.put(job);
      }
      if (job.stage === "folded" || job.stage === "registering") {
        const { rpc, signer } = this.deps;
        if (!rpc || !signer) throw new Error("no signer configured: set PROVER_NODE_ADDRESS / PROVER_NODE_PRIVATE_KEY, or use --stop-after folded");
        await this.timed(job, "registered", async () => {
          job.stage = "registering";
          jobs.put(job);
          const doc = jobs.getBatch<ChainBatchResponse>(id);
          if (!doc || !job.wrapper?.runId) throw new Error("the folded batch is not on disk; re-run the fold");
          const result = await registerRun({
            rpc,
            signer,
            batch: parseWrapperBatch(doc),
            job,
            runId: job.wrapper.runId,
            router: this.config.router,
            doomRuns: this.config.doomRuns,
            echoStore: this.deps.echoStore,
            ...(this.config.replay !== undefined ? { replay: this.config.replay } : {}),
            ...(this.deps.estimate ? { estimate: this.deps.estimate } : {}),
            ...(this.deps.estimateCall ? { estimateCall: this.deps.estimateCall } : {}),
            log: stageLog,
            onProgress: (p) => {
              if (p.state === "accepted") stageLog(`${p.label}: ${p.transactionHash} (${p.l2Gas} L2 gas)`);
              if (p.state === "skipped") stageLog(`${p.label}: already on chain`);
            },
          });
          metrics.bump("registered");
          if (result.settlement) metrics.addBounty(job.commitment.bounty);
          else metrics.bump("unsettled");
          stageLog(`registered: run ${result.onChainRunId}${result.fact ? `, fact ${result.fact}` : ""}, bounty ${result.settlement ? "settled" : "NOT settled"}`);
        });
      }
      delete job.error;
      return jobs.put(job);
    } catch (e) {
      const message = (e as Error).message;
      job.attempts++;
      job.error = message;
      if (e instanceof RefusedError) {
        job.stage = "refused";
        metrics.bump("refused");
        log.warn(`refused: ${message}`, id);
      } else if (job.attempts >= (this.config.maxAttempts ?? 5)) {
        job.stage = "failed";
        metrics.bump("failed");
        log.error(`failed after ${job.attempts} attempt(s): ${message}`, id);
      } else {
        log.warn(`attempt ${job.attempts} stopped at ${job.stage}: ${message}; will resume`, id);
      }
      return jobs.put(job);
    }
  }

  /** Runs a stage, records its duration and moves the job to `next` on success. */
  private async timed(job: JobRecord, next: JobStage, fn: () => Promise<void>, onError?: () => void): Promise<void> {
    const t0 = performance.now();
    try {
      await fn();
    } catch (e) {
      onError?.();
      throw e;
    } finally {
      const ms = performance.now() - t0;
      job.timings[next] = (job.timings[next] ?? 0) + ms;
      this.stores.metrics.time(next, ms);
    }
    job.stage = next;
    this.stores.jobs.put(job);
  }
}

/** A one-line summary of a job for `prover-node status`. */
export function describeJob(job: JobRecord): string {
  const c = job.commitment;
  const segs = job.segments ? `${job.proved.length}/${job.segments.length} proved` : "not cut";
  const stages = Object.entries(job.timings).map(([k, v]) => `${k} ${(v / 1000).toFixed(1)}s`).join(", ");
  return `${c.commitmentId.slice(0, 14)}  ${job.stage.padEnd(12)} ${String(c.tics).padStart(6)} tics  ${segs.padEnd(16)} bounty ${c.bounty} FRI` +
    (job.chain?.fact ? `  fact ${job.chain.fact.slice(0, 12)}` : "") +
    (job.chain?.settled === false ? "  bounty unsettled" : "") +
    (job.error ? `  ! ${job.error.slice(0, 80)}` : "") +
    (stages ? `  [${stages}]` : "");
}

export type { RunCommitment };

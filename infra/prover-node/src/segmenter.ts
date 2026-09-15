// SPDX-License-Identifier: Apache-2.0
/**
 * Cutting a journal into provable segments — the node-side port of the browser pipeline's
 * `planNext` (`client/src/prove/pipeline.ts`), driving the **same** `SegmentPlanner`:
 *
 * ```text
 *   propose K ─► run_segment(state, words[tic..tic+K), tic, K) ─► resources ─► judge
 *        ▲                                                                   │
 *        └──────────── shrink (and halve past maxProbes) ◄───────────────────┘ accept
 *                                                                             ▼
 *                  check D14 output against the request and the D13 commitment,
 *                  advance the start state with step_tic, next segment
 * ```
 *
 * Nothing is proved that the runtime has not just executed and sized (D26). Where the runtime
 * only counts steps, the step ceiling alone decides and the record says `rowsChecked: false`.
 * The whole journal is known up front, so unlike the browser there is no "wait for more tics":
 * the last segment is cut short.
 */
import { checkState } from "../../../client/src/prove/doomPreparation.js";
import { verifyChain, type ChainResult } from "../../../client/src/prove/chain.js";
import { normalizeFelt } from "../../../client/src/prove/felt.js";
import { rawMaxComponentRows, SegmentPlanner, type PlannerConfig } from "../../../client/src/prove/planner.js";
import { SegmentStatus, type Felt, type SegmentOutput } from "../../../client/src/prove/types.js";
import { commitLog } from "./commitment.js";
import { stepsOnlySummary, type Executor } from "./executor.js";
import { segmentLog } from "./journal.js";

export interface PlannedSegment {
  index: number;
  ticStart: number;
  ticEnd: number;
  /** `run_segment` arguments — the prover's input. */
  args: Felt[];
  /** The ten public felts the execution produced — what the proof must reproduce. */
  outputFelts: Felt[];
  output: SegmentOutput;
  /** This segment's own packed log (its slice, re-packed): the replay the registration publishes. */
  packed: string[];
  nSteps: number;
  probes: number;
  resources: {
    maxComponent: string;
    /** Raw rows of the largest component over 2^maxComponentLogSize. */
    utilisation: number;
    stepUtilisation: number;
    fitsLeafRegistry: boolean;
    /** False when the runtime gave no AIR sizing and only the step ceiling was checked. */
    rowsChecked: boolean;
  };
  executeMs: number;
}

export interface CutOptions {
  /** The commitment's genesis: `h_in` of segment 0 — the runtime's own genesis must agree. */
  genesis: Felt;
  levelId: number;
  planner?: Partial<PlannerConfig>;
  /** Threads the prover will use; picks the D26 step ceiling (1.5 M threaded, 2.3 M mono). */
  threads?: number;
  /** Words per `step_tic` call while advancing the start state (the browser uses 32). */
  stepChunk?: number;
  log?: (message: string) => void;
  onSegment?: (segment: PlannedSegment) => void;
}

export interface CutResult {
  segments: PlannedSegment[];
  chain: ChainResult;
}

/** Cuts and executes the whole journal. Throws on any disagreement with the runtime. */
export async function cutJournal(
  executor: Executor,
  words: readonly number[],
  options: CutOptions,
): Promise<CutResult> {
  const planner = new SegmentPlanner(options.planner);
  const threads = options.threads ?? 1;
  const chunk = options.stepChunk ?? 32;
  const log = options.log ?? (() => {});

  const genesis = await executor.genesis(options.levelId);
  if (normalizeFelt(genesis.hash) !== normalizeFelt(options.genesis)) {
    throw new Error(
      `the runtime's genesis for level ${options.levelId} is ${genesis.hash}, the commitment says ${options.genesis}`,
    );
  }
  let state: readonly Felt[] = genesis.state;
  if (checkState(state) !== 0) throw new Error("genesis state is not at tic zero");

  const segments: PlannedSegment[] = [];
  let ticStart = 0;
  let hIn = normalizeFelt(options.genesis);
  let finished = false;

  while (ticStart < words.length && !finished) {
    const available = words.length - ticStart;
    const wanted = planner.propose(Number.MAX_SAFE_INTEGER, threads);
    let candidate = Math.min(wanted, available);
    const index = segments.length;
    let probes = 0;

    for (;;) {
      probes++;
      const slice = words.slice(ticStart, ticStart + candidate);
      const executed = await executor.segment(state, slice, ticStart, candidate);
      const summary = executed.resources ?? stepsOnlySummary(executed.nSteps);
      const verdict = planner.judge(candidate, summary, threads);

      if (verdict.verdict === "accept") {
        const out = executed.output;
        if (normalizeFelt(out.hIn) !== hIn) throw new Error(`segment ${index}: h_in ${out.hIn}, expected ${hIn}`);
        if (out.ticStart !== ticStart) throw new Error(`segment ${index}: tic_start ${out.ticStart}, expected ${ticStart}`);
        if (out.ticEnd > ticStart + candidate || out.ticEnd <= ticStart) {
          throw new Error(`segment ${index}: tic_end ${out.ticEnd} outside (${ticStart}, ${ticStart + candidate}]`);
        }
        if (out.status === SegmentStatus.ABORT) {
          throw new Error(`segment ${index}: the journal is invalid at tic ${out.ticEnd - 1} (ABORT, R4-A2)`);
        }
        const own = segmentLog(words, ticStart, out.ticEnd);
        if (own.commitment !== BigInt(out.inputsCommitment)) {
          throw new Error(
            `segment ${index}: the runtime committed ${out.inputsCommitment}, this node folds 0x${own.commitment.toString(16)} for tics [${ticStart}, ${out.ticEnd})`,
          );
        }
        const raw = rawMaxComponentRows(summary);
        const segment: PlannedSegment = {
          index,
          ticStart,
          ticEnd: out.ticEnd,
          args: executed.args,
          outputFelts: executed.outputFelts.map(normalizeFelt),
          output: out,
          packed: own.packed.map((p) => "0x" + p.toString(16)),
          nSteps: summary.n_steps,
          probes,
          resources: {
            maxComponent: summary.max_component,
            utilisation: raw.rows / planner.rowCeiling,
            stepUtilisation: summary.n_steps / planner.stepCeiling(threads),
            fitsLeafRegistry: summary.fits_leaf_registry,
            rowsChecked: executed.resources !== null,
          },
          executeMs: executed.ms,
        };
        segments.push(segment);
        log(
          `segment ${index}: tics [${ticStart}, ${out.ticEnd}), ${summary.n_steps} steps ` +
            `(${Math.round(segment.resources.stepUtilisation * 100)} % of the ceiling), ${probes} probe${probes > 1 ? "s" : ""}`,
        );
        options.onSegment?.(segment);

        if (out.status !== SegmentStatus.RUNNING) {
          finished = true;
        } else {
          state = await advance(executor, state, words, ticStart, out.ticEnd, chunk);
        }
        hIn = normalizeFelt(out.hOut);
        ticStart = out.ticEnd;
        break;
      }

      if (verdict.verdict === "impossible") {
        throw new Error(`segment ${index}: no length fits the leaf registry: ${verdict.reason}`);
      }
      log(`segment ${index}: ${candidate} tics rejected (${verdict.reason}); retrying with ${verdict.tics}`);
      candidate = verdict.tics;
      if (probes >= planner.config.maxProbes) {
        candidate = Math.max(planner.config.minTics, Math.floor(candidate / 2));
      }
    }
  }

  if (ticStart < words.length) {
    throw new Error(`the journal continues ${words.length - ticStart} tic(s) past the terminal state at tic ${ticStart}`);
  }
  const chain = checkSegmentChain(segments, words, options.genesis);
  if (!chain.ok) throw new Error(`segment chain: ${chain.reason} (segment ${chain.index})`);
  return { segments, chain };
}

/** Replays `[from, to)` through `step_tic` in chunks and returns the state at `to`. */
async function advance(
  executor: Executor,
  state: readonly Felt[],
  words: readonly number[],
  from: number,
  to: number,
  chunk: number,
): Promise<readonly Felt[]> {
  let tic = from;
  let current = state;
  while (tic < to) {
    const stop = Math.min(tic + chunk, to);
    const result = await executor.step(current, words.slice(tic, stop));
    const reached = checkState(result.state);
    if (reached !== stop || result.status !== SegmentStatus.RUNNING) {
      throw new Error(`step_tic reached tic ${reached} with status ${result.status} while replaying [${tic}, ${stop})`);
    }
    current = result.state;
    tic = stop;
  }
  return current;
}

/**
 * The whole run's chain: `verifyChain` (genesis, `h_out → h_in`, tic continuity, counters,
 * terminal status), plus what only this node can check — every `inputs_commitment` folds from
 * the segment's own slice of the words, and the segments cover the journal exactly.
 */
export function checkSegmentChain(
  segments: readonly PlannedSegment[],
  words: readonly number[],
  genesis: Felt,
): ChainResult {
  const chain = verifyChain(segments.map((s) => s.output), { genesis, requireFinished: true });
  if (!chain.ok) return chain;
  for (const s of segments) {
    if (s.output.ticStart !== s.ticStart || s.output.ticEnd !== s.ticEnd) {
      return { ok: false, index: s.index, reason: "the record's tic span differs from its output" };
    }
    const own = segmentLog(words, s.ticStart, s.ticEnd);
    if (own.commitment !== BigInt(s.output.inputsCommitment)) {
      return { ok: false, index: s.index, reason: `inputs_commitment does not fold from tics [${s.ticStart}, ${s.ticEnd})` };
    }
    if (commitLog(s.packed.map(BigInt)) !== own.commitment) {
      return { ok: false, index: s.index, reason: "the stored packed log is not the segment's slice" };
    }
  }
  const last = segments[segments.length - 1]!;
  if (last.ticEnd !== words.length) {
    return { ok: false, index: last.index, reason: `segments cover ${last.ticEnd} of ${words.length} tics` };
  }
  return chain;
}

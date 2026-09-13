// SPDX-License-Identifier: Apache-2.0
/**
 * The submission sequence: 5–6 router transactions that register one fact, then one
 * `DoomRuns.submit_batch` that records the games of that batch.
 *
 * Two properties drive the whole design.
 *
 * **One phase = one transaction.** The router returns the checkpoint echo after each phase;
 * this plan keeps those transaction boundaries with the optimized P4.1 classes (D28).
 * The transactions are therefore *dependent* — each one echoes the checkpoint state the previous
 * one returned — which is also why they must be estimated as an ordered array (S5 §3).
 *
 * **The sequence is resumable by `proof_id`.** The router keeps `{tag, poseidon(state)}` per
 * `(caller, proof_id)` and emits a `Step` event at every write. So after a crash, a closed tab or
 * an out-of-gas revert, `resumePoint()` asks the chain where the sequence stopped and continues
 * from there — nothing is re-paid. The checkpoint stores a *hash*, not the state, so the echo
 * itself comes from a local store when there is one, and otherwise from the retdata of the last
 * `Step` transaction's trace.
 */

import { phaseCalldata, planPhases, type PhasePlan } from "./calldata.js";
import type { ProofSections } from "./proof.js";
import { getSelectorFromName } from "./selector.js";
import type { Signer } from "./signer.js";
import type { Call, ResourceBounds, RpcClient } from "./rpc.js";

/** Checkpoint tags of `StwoCircuitRouter`. */
export const TAG = { FREE: 0, MERKLE: 1, FRI: 2, DONE: 3 } as const;

export interface ConsumerStep {
  label: "submit_batch";
  call: Call;
  /** Run ids this call would record, when the client asked the contract for them. */
  runIds?: string[];
}

export interface SubmissionSequence {
  proofId: bigint;
  router: string;
  doomRuns: string;
  phases: PhasePlan[];
  /** An explicit cut may resume an old sequence whose local plan was never recorded. */
  explicitFriSplit?: boolean;
  /** Offline sections allow an automatic client to restore its saved cut before estimation. */
  friPlan?: { sections: ProofSections; maxCalldata?: number };
  consumer: ConsumerStep;
}

export interface SequenceStep {
  index: number;
  label: string;
  /** `verifier` for the router phases, `consumer` for `submit_batch`. */
  phase: "verifier" | "consumer";
  call: Call;
  /** The checkpoint echo this step needs, `null` for `begin` and for the consumer. */
  needsEcho: boolean;
}

/** Builds the whole ordered sequence. `echo` is resolved step by step while running. */
export function buildSequence(args: {
  proofId: bigint;
  router: string;
  doomRuns: string;
  phases: PhasePlan[];
  submitCalldata: string[];
  explicitFriSplit?: boolean;
}): SubmissionSequence {
  return {
    proofId: args.proofId,
    router: args.router,
    doomRuns: args.doomRuns,
    phases: args.phases,
    // Callers supplying phases directly chose their plan; prepareSubmission marks auto plans.
    explicitFriSplit: args.explicitFriSplit ?? true,
    consumer: {
      label: "submit_batch",
      call: {
        contractAddress: args.doomRuns,
        entrypoint: "submit_batch",
        calldata: args.submitCalldata,
      },
    },
  };
}

/**
 * The sequence as calls, with a placeholder echo for the phases that need one. Used for
 * *estimation*: a simulated array is applied in order, so tx i sees the state tx i-1 left, and
 * the placeholder is replaced by the real echo the same way the driver does it.
 *
 * `echoes[i]` must be supplied for every phase after `begin`. For a first estimate before
 * anything is on chain, `simulateSequence` walks the array and reads each echo back out of the
 * simulation's own retdata.
 */
export function sequenceSteps(seq: SubmissionSequence, echoes: (string[] | null)[]): SequenceStep[] {
  const steps: SequenceStep[] = seq.phases.map((p, i) => ({
    index: i,
    label: p.label,
    phase: "verifier" as const,
    call: {
      contractAddress: seq.router,
      entrypoint: p.entrypoint,
      calldata: phaseCalldata(p, echoes[i] ?? null),
    },
    needsEcho: p.echo !== null,
  }));
  steps.push({
    index: seq.phases.length,
    label: seq.consumer.label,
    phase: "consumer",
    call: seq.consumer.call,
    needsEcho: false,
  });
  return steps;
}

export interface Checkpoint {
  tag: number;
  stateHash: string;
}

export async function readCheckpoint(
  rpc: RpcClient,
  router: string,
  caller: string,
  proofId: bigint,
): Promise<Checkpoint> {
  const out = await rpc.call({
    contractAddress: router,
    entrypoint: "checkpoint",
    calldata: [caller, "0x" + proofId.toString(16)],
  });
  return { tag: Number(BigInt(out[0] ?? "0x0")), stateHash: out[1] ?? "0x0" };
}

/** The retdata of a router transaction: the checkpoint state it returned, as 0x felts. */
export async function echoFromTrace(rpc: RpcClient, txHash: string): Promise<string[] | null> {
  const tr = await rpc.trace(txHash);
  const result: string[] | undefined = tr?.execute_invocation?.calls?.[0]?.result;
  if (!result || result.length === 0) return null;
  const n = Number(BigInt(result[0]!));
  return result.slice(1, 1 + n);
}

/** `Step` events of one `(caller, proof_id)`, oldest first — one per completed phase. */
export async function stepEvents(
  rpc: RpcClient,
  router: string,
  caller: string,
  proofId: bigint,
  fromBlock: number | "0" = 0,
): Promise<{ transactionHash: string; tag: number; stateHash: string }[]> {
  const events: { transactionHash: string; tag: number; stateHash: string }[] = [];
  let token: string | undefined;
  do {
    const page: any = await rpc.request("starknet_getEvents", [
      {
        from_block: { block_number: Number(fromBlock) },
        to_block: "latest",
        address: router,
        keys: [[getSelectorFromName("Step")], [caller], ["0x" + proofId.toString(16)]],
        chunk_size: 100,
        ...(token ? { continuation_token: token } : {}),
      },
    ]);
    for (const ev of page.events ?? []) {
      events.push({
        transactionHash: ev.transaction_hash,
        tag: Number(BigInt(ev.data?.[0] ?? "0x0")),
        stateHash: ev.data?.[1] ?? "0x0",
      });
    }
    token = page.continuation_token;
  } while (token);
  return events;
}

export interface ResumePoint {
  /** Index into `phases` of the next router transaction; `phases.length` = the fact is done. */
  nextPhase: number;
  /** The echo the next transaction must carry, `null` when it is `begin` or the fact is done. */
  echo: string[] | null;
  checkpoint: Checkpoint;
  /** True when the router already registered the fact for this `proof_id`. */
  factRegistered: boolean;
  /** Where the echo came from, for the UI and the logs. */
  echoSource: "none" | "store" | "trace";
}

/** Persistence of the checkpoint echoes, so a resume does not need trace support (C6). */
export interface EchoStore {
  get(proofId: bigint, phaseIndex: number): string[] | null;
  set(proofId: bigint, phaseIndex: number, echo: string[]): void;
}

/**
 * Reserved EchoStore slot for a versioned FRI plan, never a checkpoint echo. Existing file
 * and browser stores already preserve string arrays at this key, so their old echoes survive.
 * Bind the metadata to the router and caller, since proof ids are local to that pair.
 */
const PLAN_SLOT = -1;
const PLAN_VERSION = "hellproof.fri-plan.v1";
const canonicalFelt = (value: string): string => "0x" + BigInt(value).toString(16);

export function storedFriSplit(
  store: EchoStore | undefined,
  proofId: bigint,
  router: string,
  caller: string,
): number[] | null {
  const data = store?.get(proofId, PLAN_SLOT);
  if (
    !Array.isArray(data) || data[0] !== PLAN_VERSION ||
    data[1] !== canonicalFelt(router) || data[2] !== canonicalFelt(caller)
  ) return null;
  const cuts = data.slice(3).map(Number);
  if (cuts.some((c, i) => !Number.isSafeInteger(c) || c <= 0 || (i > 0 && c <= cuts[i - 1]!))) {
    return null;
  }
  return cuts;
}

function friSplitOf(seq: SubmissionSequence): number[] | null {
  const fri = seq.phases.filter((p) => p.entrypoint === "fri");
  if (!fri.length || fri.some((p) => !p.meta.layers?.length)) return null;
  return fri.slice(1).map((p) => p.meta.layers![0]!);
}

function checkResumePlan(seq: SubmissionSequence, caller: string, store?: EchoStore): void {
  const saved = storedFriSplit(store, seq.proofId, seq.router, caller);
  if (saved) {
    if (JSON.stringify(saved) !== JSON.stringify(friSplitOf(seq))) {
      if (!seq.explicitFriSplit && seq.friPlan) {
        const phases = planPhases(seq.friPlan.sections, {
          proofId: seq.proofId,
          friSplit: saved,
          maxCalldata: seq.friPlan.maxCalldata,
        });
        // Preserve the array shared with PreparedSubmission; both views must use this plan.
        seq.phases.splice(0, seq.phases.length, ...phases);
      } else {
        throw new Error(
          `proof id ${seq.proofId}: stored FRI plan differs; resume with --fri-split ${saved.join(",")}`,
        );
      }
    }
  } else if (!seq.explicitFriSplit) {
    throw new Error(
      `proof id ${seq.proofId}: original FRI split is unknown; resume with --fri-split <original cut> ` +
        `(use --fri-split 1,3 for the former six-transaction default), or use a fresh proof id`,
    );
  }
}

/** In-memory `EchoStore`; the UI backs it with `localStorage`, the CLI with a JSON file. */
export class MemoryEchoStore implements EchoStore {
  private readonly map = new Map<string, string[]>();
  get(proofId: bigint, phaseIndex: number): string[] | null {
    return this.map.get(`${proofId}:${phaseIndex}`) ?? null;
  }
  set(proofId: bigint, phaseIndex: number, echo: string[]): void {
    this.map.set(`${proofId}:${phaseIndex}`, echo);
  }
}

/**
 * Where to restart the sequence for this `(caller, proof_id)`.
 *
 * The tag alone does not say which phase is next — `begin` and `merkle` both leave `MERKLE`, and
 * every FRI chunk but the last leaves `FRI` — so the *number of `Step` events* is what counts
 * the completed phases. The tag is then used as a consistency check against the plan, which
 * catches obvious disagreement. It cannot distinguish cuts while both plans are inside FRI:
 * restore the saved plan first, or require an explicit original cut for a legacy sequence.
 * An automatic five-tx default must never silently replace an unknown six-tx resume plan.
 */
export async function resumePoint(
  rpc: RpcClient,
  seq: SubmissionSequence,
  caller: string,
  store?: EchoStore,
  /**
   * Block to scan `Step` events from. Zero is right on a devnet and wasteful on a long chain:
   * a client that knows when it started the sequence should say so.
   */
  fromBlock = 0,
): Promise<ResumePoint> {
  const checkpoint = await readCheckpoint(rpc, seq.router, caller, seq.proofId);
  if (checkpoint.tag === TAG.FREE) {
    return { nextPhase: 0, echo: null, checkpoint, factRegistered: false, echoSource: "none" };
  }
  if (checkpoint.tag === TAG.DONE) {
    return {
      nextPhase: seq.phases.length,
      echo: null,
      checkpoint,
      factRegistered: true,
      echoSource: "none",
    };
  }

  checkResumePlan(seq, caller, store);
  const steps = await stepEvents(rpc, seq.router, caller, seq.proofId, fromBlock);
  const nextPhase = steps.length;
  if (nextPhase >= seq.phases.length) {
    throw new Error(
      `proof id ${seq.proofId}: ${nextPhase} phases already ran but the plan has ` +
        `${seq.phases.length} — the sequence was started with a different FRI split`,
    );
  }
  const expected = seq.phases[nextPhase]!.echo === "fri_state" ? TAG.FRI : TAG.MERKLE;
  if (checkpoint.tag !== expected) {
    throw new Error(
      `proof id ${seq.proofId}: the router is at tag ${checkpoint.tag} but the plan expects ` +
        `${expected} for '${seq.phases[nextPhase]!.label}' — plans disagree, use a fresh proof id`,
    );
  }

  const stored = store?.get(seq.proofId, nextPhase - 1) ?? null;
  if (stored) {
    return { nextPhase, echo: stored, checkpoint, factRegistered: false, echoSource: "store" };
  }
  const last = steps[steps.length - 1]!;
  const echo = await echoFromTrace(rpc, last.transactionHash);
  if (!echo) {
    throw new Error(
      `proof id ${seq.proofId}: phase ${nextPhase} needs the checkpoint state of ` +
        `${last.transactionHash}, which is neither stored locally nor readable from the node's ` +
        `trace — restart under a fresh proof id`,
    );
  }
  return { nextPhase, echo, checkpoint, factRegistered: false, echoSource: "trace" };
}

export interface StepProgress {
  index: number;
  label: string;
  phase: "verifier" | "consumer";
  state: "sending" | "accepted" | "skipped" | "failed";
  transactionHash?: string;
  /** Measured from the receipt once accepted. */
  l2Gas?: bigint;
  l1DataGas?: bigint;
  feeFri?: bigint;
  error?: string;
}

export interface RunOptions {
  signer: Signer;
  /** Per-step resource bounds, in sequence order (`bounds[i]` for step i). */
  bounds: ResourceBounds[];
  store?: EchoStore;
  onProgress?: (p: StepProgress) => void;
  /** Skip the consumer transaction (verify the fact only). */
  verifierOnly?: boolean;
}

export interface RunResult {
  steps: StepProgress[];
  /** The fact the router registered, when the run reached the end of the FRI walk. */
  fact?: string;
  resumedAt: number;
}

/**
 * Plays the sequence from wherever the chain says it stopped.
 *
 * Every step is awaited to its receipt before the next one is built: the echo of step i is the
 * retdata of step i, so there is nothing to pipeline. A failure stops the run and leaves the
 * checkpoint where it is — calling this again resumes at the same place.
 */
export async function runSequence(
  rpc: RpcClient,
  seq: SubmissionSequence,
  options: RunOptions,
): Promise<RunResult> {
  const { signer, bounds, store, onProgress } = options;
  const resume = await resumePoint(rpc, seq, signer.address, store);
  // Persist before sending, including an explicit legacy resume or a lost receipt/echo.
  const split = friSplitOf(seq);
  if (!resume.factRegistered && store && split) {
    store.set(seq.proofId, PLAN_SLOT, [
      PLAN_VERSION,
      canonicalFelt(seq.router),
      canonicalFelt(signer.address),
      ...split.map(String),
    ]);
  }
  const progress: StepProgress[] = [];
  let echo = resume.echo;
  let fact: string | undefined;

  const emit = (p: StepProgress) => {
    progress.push(p);
    onProgress?.(p);
  };

  for (let i = 0; i < seq.phases.length; i++) {
    const phase = seq.phases[i]!;
    if (i < resume.nextPhase) {
      emit({ index: i, label: phase.label, phase: "verifier", state: "skipped" });
      continue;
    }
    const call: Call = {
      contractAddress: seq.router,
      entrypoint: phase.entrypoint,
      calldata: phaseCalldata(phase, echo),
    };
    emit({ index: i, label: phase.label, phase: "verifier", state: "sending" });
    const bound = bounds[i];
    if (!bound) throw new Error(`no resource bounds for step ${i} (${phase.label})`);
    const { transactionHash } = await signer.execute([call], { bounds: bound });
    const receipt = await rpc.waitForReceipt(transactionHash);
    const er = receipt.execution_resources ?? {};
    emit({
      index: i,
      label: phase.label,
      phase: "verifier",
      state: "accepted",
      transactionHash,
      l2Gas: BigInt(er.l2_gas ?? 0),
      l1DataGas: BigInt(er.l1_data_gas ?? 0),
      feeFri: BigInt(receipt.actual_fee?.amount ?? "0x0"),
    });
    for (const ev of receipt.events ?? []) {
      if (ev.keys?.length === 2 && ev.data?.length === 2) fact = ev.keys[1];
    }
    echo = await echoFromTrace(rpc, transactionHash);
    if (echo && store) store.set(seq.proofId, i, echo);
  }

  if (!options.verifierOnly) {
    const i = seq.phases.length;
    emit({ index: i, label: seq.consumer.label, phase: "consumer", state: "sending" });
    const bound = bounds[i];
    if (!bound) throw new Error(`no resource bounds for the consumer transaction`);
    const { transactionHash } = await signer.execute([seq.consumer.call], { bounds: bound });
    const receipt = await rpc.waitForReceipt(transactionHash);
    const er = receipt.execution_resources ?? {};
    emit({
      index: i,
      label: seq.consumer.label,
      phase: "consumer",
      state: "accepted",
      transactionHash,
      l2Gas: BigInt(er.l2_gas ?? 0),
      l1DataGas: BigInt(er.l1_data_gas ?? 0),
      feeFri: BigInt(receipt.actual_fee?.amount ?? "0x0"),
    });
  }

  return { steps: progress, ...(fact ? { fact } : {}), resumedAt: resume.nextPhase };
}

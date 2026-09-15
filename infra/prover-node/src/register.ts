// SPDX-License-Identifier: Apache-2.0
/**
 * Registration: the D28 sequence — five verifier transactions, then `register_member` for this
 * run **with its replay logs** — which is also what settles the commitment: `DoomRuns` pays the
 * bounty to the caller of the member submission when version, level, player, tics and genesis
 * match and the game-level commitment can be recomputed (one segment: the leaf's
 * `inputs_commitment`; several: the fold of the concatenated replay logs, see `commitments.ts`).
 * There is no separate claim; the `CommitmentProved` event in the consumer's receipt is the
 * proof of payment, and its absence is reported.
 *
 * It is `client/src/chain` end to end — `prepareSubmission`, `resumePoint`, `runSequence` —
 * exactly what `infra/submit` and the browser run, with this node's signer. D20: `Member.player`
 * is the committing player, not the caller. The router's proof id is the commitment id, so a
 * relaunch resumes the same sequence from the router's checkpoint and the echoes persisted on
 * disk (`FileEchoStore`).
 */
import { checkBatch, membersFromPlacements, type Member, type WrapperBatch } from "../../../client/src/chain/batch.js";
import {
  boundsFor,
  INVOKE_L2_GAS_CAP,
  priceEstimate,
  simulateSequence,
  simulationBounds,
  withPrices,
} from "../../../client/src/chain/estimate.js";
import { feeEstimateOf, invokeV3, type Call, type ResourceBounds, type RpcClient } from "../../../client/src/chain/rpc.js";
import { resumePoint, runSequence, storedFriSplit, type EchoStore, type ResumePoint, type StepProgress } from "../../../client/src/chain/sequence.js";
import type { Signer } from "../../../client/src/chain/signer.js";
import { isRunRegistered, prepareSubmission, runIdOf, type PrepareArgs, type PreparedSubmission } from "../../../client/src/chain/submission.js";
import { submissionPlans } from "../../submit/src/planning.js";
import { COMMITMENT_STATUS, getCommitment, settlementIn, type CommitmentProvedEvent } from "./commitments.js";
import type { JobRecord } from "./store.js";

export interface Estimate {
  prepared: PreparedSubmission;
  /** One per sequence step from the resume point (`runSequence` indexes from step 0). */
  bounds: ResourceBounds[];
  totalStrk?: number;
}

export interface RegisterOptions {
  rpc: RpcClient;
  signer: Signer;
  batch: WrapperBatch;
  job: JobRecord;
  /** The wrapper run id this node's leaves carry in `batch.placements`. */
  runId: string;
  router: string;
  doomRuns: string;
  echoStore: EchoStore;
  versionId?: number;
  proofId?: bigint;
  /**
   * Publish the packed logs (R10-A3). On by default — the commitment already made them public —
   * and **forced on for a multi-segment run**, without which the run is recorded but the bounty
   * is not paid.
   */
  replay?: boolean;
  /** Check `get_commitment` before paying (off only for a node whose contract lacks the view). */
  preflightCommitment?: boolean;
  /** Bounds for the sequence; defaults to the D28 simulate-before-send loop over the RPC. */
  estimate?: (args: PrepareArgs, prepared: PreparedSubmission, resume: ResumePoint, verifierOnly: boolean) => Promise<Estimate>;
  /** Bounds for one standalone call (the claim); defaults to a simulation from the signer. */
  estimateCall?: (call: Call) => Promise<ResourceBounds>;
  log?: (message: string) => void;
  onProgress?: (p: StepProgress) => void;
}

export interface RegisterResult {
  member: Member;
  onChainRunId: string;
  alreadyRegistered: boolean;
  fact?: string;
  transactions: { label: string; hash: string }[];
  /** The bounty payment found in the consumer's receipt (or on chain, when resuming). */
  settlement: CommitmentProvedEvent | { runId: string; prover: string } | null;
  resumedAt: number;
}

export async function registerRun(options: RegisterOptions): Promise<RegisterResult> {
  const { rpc, signer, batch, job, runId, router, doomRuns } = options;
  const log = options.log ?? (() => {});
  const c = job.commitment;
  const versionId = options.versionId ?? c.versionId;
  const proofId = options.proofId ?? BigInt(c.commitmentId);

  const members = membersFromPlacements(batch.placements, { players: { [runId]: c.player }, levelIds: { [runId]: c.levelId } });
  const member = members.find((m) => m.runId === runId);
  if (!member) throw new Error(`the batch carries no leaves for run ${runId}`);
  const problems = checkBatch(batch, [member], BigInt(c.genesis));
  if (problems.length) throw new Error(`the batch would be rejected on chain: ${problems.join("; ")}`);
  const replay = (options.replay ?? true) || member.leafLen > 1;
  if (!replay) log("single segment: the leaf's inputs_commitment settles the commitment, no replay published");
  else if (options.replay === false) log(`replay forced on: ${member.leafLen} segments need their logs on chain for the bounty`);

  if (options.preflightCommitment ?? true) {
    const view = await getCommitment(rpc, doomRuns, c.commitmentId);
    if (view.status === COMMITMENT_STATUS.PROVED && BigInt(view.prover) !== BigInt(signer.address)) {
      throw new Error(`commitment ${c.commitmentId} was already proved by ${view.prover} (run ${view.runId})`);
    }
    if (view.status === COMMITMENT_STATUS.RECLAIMED) throw new Error(`commitment ${c.commitmentId} was reclaimed by its player`);
    if (view.status === COMMITMENT_STATUS.NONE) throw new Error(`commitment ${c.commitmentId} does not exist on ${doomRuns}`);
    if (view.tics !== c.tics || BigInt(view.player) !== BigInt(c.player) || BigInt(view.genesis) !== BigInt(c.genesis)) {
      throw new Error(`commitment ${c.commitmentId} on chain differs from the one discovered (tics ${view.tics}, player ${view.player})`);
    }
  }

  const savedSplit = storedFriSplit(options.echoStore, proofId, router, signer.address);
  const args: PrepareArgs = {
    batch,
    router,
    doomRuns,
    versionId,
    proofId,
    players: { [runId]: c.player },
    levelIds: { [runId]: c.levelId },
    replay,
    singleMember: member,
    ...(savedSplit ? { plan: { friSplit: savedSplit } } : {}),
  };
  let prepared = prepareSubmission(args);
  log(`sequence: ${prepared.phases.length} verifier transactions + register_member (${prepared.consumerCalldataFelts} felts), proof id 0x${proofId.toString(16)}`);

  // Free checks first (R10-A1): is this run already recorded? Then the consumer is skipped.
  const onChainRunId = await runIdOf(rpc, doomRuns, versionId, member, batch);
  const alreadyRegistered = await isRunRegistered(rpc, doomRuns, onChainRunId);
  if (alreadyRegistered) log(`run ${onChainRunId} is already recorded on chain; only the fact and the claim remain`);

  const resume = await resumePoint(rpc, prepared.sequence, signer.address, options.echoStore);
  if (resume.nextPhase > 0) log(`resuming at phase ${resume.nextPhase} (checkpoint tag ${resume.checkpoint.tag}, echo from ${resume.echoSource})`);

  const estimate = await (options.estimate ?? makeEstimator(rpc, signer.address))(args, prepared, resume, alreadyRegistered);
  prepared = estimate.prepared;
  if (estimate.totalStrk !== undefined) log(`estimated ${estimate.totalStrk.toFixed(4)} STRK for ${estimate.bounds.length} transaction(s)`);

  job.chain = { ...(job.chain ?? { transactions: [] }), proofId: "0x" + proofId.toString(16) };
  const transactions: { label: string; hash: string }[] = [];
  let consumerTx: string | undefined;
  const result = await runSequence(rpc, prepared.sequence, {
    signer,
    bounds: [...new Array<ResourceBounds>(resume.nextPhase).fill(estimate.bounds[0]!), ...estimate.bounds],
    store: options.echoStore,
    verifierOnly: alreadyRegistered,
    onProgress: (p) => {
      if (p.state === "accepted" && p.transactionHash) {
        transactions.push({ label: p.label, hash: p.transactionHash });
        job.chain!.transactions = [...transactions];
        if (p.phase === "consumer") consumerTx = p.transactionHash;
      }
      options.onProgress?.(p);
    },
  });
  if (result.fact) job.chain.fact = result.fact;

  // Was the bounty paid? The consumer's receipt says so; on a resume, the contract does.
  let settlement: RegisterResult["settlement"] = null;
  if (consumerTx) {
    const receipt = (await rpc.waitForReceipt(consumerTx)) as { events?: { keys?: string[]; data?: string[] }[] };
    settlement = settlementIn(receipt.events, c.commitmentId);
    job.chain.settled = settlement !== null;
    if (settlement) log(`bounty settled: ${"bounty" in settlement ? settlement.bounty : "?"} FRI to ${settlement.prover} for run ${settlement.runId}`);
    else log("register_member was accepted but no CommitmentProved event followed: the run is recorded, the bounty is not paid");
  } else if (options.preflightCommitment ?? true) {
    const view = await getCommitment(rpc, doomRuns, c.commitmentId);
    if (view.status === COMMITMENT_STATUS.PROVED) settlement = { runId: view.runId, prover: view.prover };
    job.chain.settled = settlement !== null;
  }

  return {
    member,
    onChainRunId,
    alreadyRegistered,
    ...(result.fact ? { fact: result.fact } : {}),
    transactions,
    settlement,
    resumedAt: result.resumedAt,
  };
}

/**
 * The D28 simulate-before-send loop of `infra/submit/src/cli.ts`: the ordered sequence from the
 * signing account, ×1.15 / ×1.30 margins (R7-A1), finer FRI cuts if a bound is over the invoke
 * cap and nothing has been sent yet.
 */
export function makeEstimator(rpc: RpcClient, sender: string): NonNullable<RegisterOptions["estimate"]> {
  return async (args, initial, resume, verifierOnly) => {
    let last: Estimate | null = null;
    for (const candidate of submissionPlans(args, initial, resume.nextPhase)) {
      const est = await simulateSequence(rpc, candidate.sequence, {
        sender,
        verifierOnly,
        fromPhase: resume.nextPhase,
        ...(resume.echo ? { echoes: [...new Array<null>(resume.nextPhase).fill(null), resume.echo] } : {}),
      });
      const bounds = withPrices(est.bounds, est.prices);
      last = { prepared: candidate, bounds: bounds.map((b) => b.bounds), totalStrk: priceEstimate(est, null).totalStrk };
      if (!bounds.some((b) => b.overCap)) return last;
    }
    throw new Error(`a ×1.15 bound stays over the ${INVOKE_L2_GAS_CAP} invoke cap after every permitted FRI cut (S5 §6)`);
  };
}

/** R7-A1 bounds for one standalone call, as `infra/submit`'s `estimateBounds`. */
export async function estimateStandalone(rpc: RpcClient, sender: string, call: Call): Promise<ResourceBounds> {
  const prices = await rpc.gasPrices();
  const nonce = await rpc.nonce(sender);
  const [entry] = await rpc.estimateFee([invokeV3(sender, [call], nonce, simulationBounds(prices))]);
  const estimate = feeEstimateOf(entry);
  const step = { index: 0, label: call.entrypoint, phase: "consumer" as const, calldataFelts: call.calldata.length, estimate, pctOfCap: 0 };
  return withPrices([boundsFor(step, prices)], prices)[0]!.bounds;
}

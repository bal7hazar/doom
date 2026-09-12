// SPDX-License-Identifier: Apache-2.0
/**
 * One call that turns a wrapper batch into the submission sequence, and the queries that let a
 * client check — for free — what the paid transactions would do.
 *
 * D20: the sequence is caller-independent. The wrapper submits whole batches for everybody (one
 * `submit_batch` for M games, ~5× cheaper than one `register_member` per player, because every
 * call needs the leaves of the *whole* batch anyway); a player submitting their own run runs the
 * exact same code with `register_member`. Which of the two is used is a policy decision, not a
 * code path — `docs/design/submission.md` §2.
 */

import {
  membersFromPlacements,
  replayFor,
  submitBatchCalldata,
  registerMemberCalldata,
  type Member,
  type WrapperBatch,
} from "./batch.js";
import { planPhases, planPhasesAuto, type PhasePlan, type PlanOptions } from "./calldata.js";
import { parseProof } from "./proof.js";
import { buildSequence, type SubmissionSequence } from "./sequence.js";
import type { RpcClient } from "./rpc.js";

export interface PrepareArgs {
  batch: WrapperBatch;
  router: string;
  doomRuns: string;
  versionId: number;
  proofId: bigint;
  /** Address recorded as the player of each wrapper run (`run_id` → address). */
  players: Record<string, string>;
  /** `(version, level)` of each run — the wrapper returns it with the batch. */
  levelIds?: Record<string, number>;
  defaultLevelId?: number;
  /** Publish the packed input logs (R10-A3). +24 % consumer gas on a 25-segment batch. */
  replay?: boolean;
  /** Root proof felts, when not already on `batch`. */
  rootProofFelts?: bigint[];
  /** FRI cut; by default 5 transactions, falling back to 6 when a section is too big. */
  plan?: PlanOptions & { preferSafeMargin?: boolean };
  /** Submit one member instead of the whole batch (the per-player fallback). */
  singleMember?: Member;
}

export interface PreparedSubmission {
  sequence: SubmissionSequence;
  phases: PhasePlan[];
  members: Member[];
  /** Calldata felts of the consumer transaction — the cheap half of the bill. */
  consumerCalldataFelts: number;
  /** Total packed slots carried by the verifier transactions. */
  payloadSlots: number;
}

export function prepareSubmission(args: PrepareArgs): PreparedSubmission {
  const felts = args.rootProofFelts ?? args.batch.rootProofFelts;
  if (!felts) {
    throw new Error("no root proof felts: fetch the batch with `?include=proof`");
  }
  const sections = parseProof(felts);
  const phases = args.plan?.friSplit
    ? planPhases(sections, { ...args.plan, proofId: args.proofId })
    : planPhasesAuto(sections, { ...args.plan, proofId: args.proofId });

  const members = args.singleMember
    ? [args.singleMember]
    : membersFromPlacements(args.batch.placements, {
        players: args.players,
        levelIds: args.levelIds ?? {},
        ...(args.defaultLevelId === undefined ? {} : { defaultLevelId: args.defaultLevelId }),
      });

  const replay =
    args.replay && args.batch.logs ? replayFor(members, args.batch.logs) : [];
  const submitCalldata = args.singleMember
    ? registerMemberCalldata({
        versionId: args.versionId,
        leaves: args.batch.leaves,
        member: args.singleMember,
        replay,
      })
    : submitBatchCalldata({
        versionId: args.versionId,
        leaves: args.batch.leaves,
        members,
        replay,
      });

  const sequence = buildSequence({
    proofId: args.proofId,
    router: args.router,
    doomRuns: args.doomRuns,
    phases,
    submitCalldata,
  });
  if (args.singleMember) sequence.consumer.call.entrypoint = "register_member";

  return {
    sequence,
    phases,
    members,
    consumerCalldataFelts: sequence.consumer.call.calldata.length,
    payloadSlots: phases.reduce((a, p) => a + p.payloadSlots, 0),
  };
}

const leafCalldata = (batch: WrapperBatch): string[] => {
  const words: string[] = ["0x" + batch.leaves.length.toString(16)];
  for (const leaf of batch.leaves) {
    for (const v of [
      leaf.version,
      leaf.h_in,
      leaf.h_out,
      leaf.tic_start,
      leaf.tic_end,
      leaf.status,
      leaf.inputs_commitment,
      leaf.kills,
      leaf.items,
      leaf.secrets,
    ]) {
      words.push("0x" + v.toString(16));
    }
  }
  return words;
};

/**
 * `DoomRuns.batch_fact(version_id, leaves)` — "check before paying". Recomposes the fact the
 * batch would need and lets the client ask `is_valid` for it *before* the five verifier
 * transactions, which is the difference between resubmitting a batch for nothing and knowing it
 * is already proved.
 */
export async function batchFact(
  rpc: RpcClient,
  doomRuns: string,
  versionId: number,
  batch: WrapperBatch,
): Promise<string> {
  const out = await rpc.call({
    contractAddress: doomRuns,
    entrypoint: "batch_fact",
    calldata: ["0x" + versionId.toString(16), ...leafCalldata(batch)],
  });
  return out[0] ?? "0x0";
}

/** `StwoCircuitRouter.is_valid(fact)`. */
export async function isFactValid(
  rpc: RpcClient,
  router: string,
  fact: string,
): Promise<boolean> {
  const out = await rpc.call({ contractAddress: router, entrypoint: "is_valid", calldata: [fact] });
  return BigInt(out[0] ?? "0x0") === 1n;
}

/** `DoomRuns.run_id_of(version_id, level_id, leaves)` for one member's own leaves. */
export async function runIdOf(
  rpc: RpcClient,
  doomRuns: string,
  versionId: number,
  member: Member,
  batch: WrapperBatch,
): Promise<string> {
  const own: WrapperBatch = {
    ...batch,
    leaves: batch.leaves.slice(member.leafStart, member.leafStart + member.leafLen),
  };
  const out = await rpc.call({
    contractAddress: doomRuns,
    entrypoint: "run_id_of",
    calldata: [
      "0x" + versionId.toString(16),
      "0x" + member.levelId.toString(16),
      ...leafCalldata(own),
    ],
  });
  return out[0] ?? "0x0";
}

/** `DoomRuns.is_run_registered(run_id)` — R10-A1 replay protection, checked before paying. */
export async function isRunRegistered(
  rpc: RpcClient,
  doomRuns: string,
  runId: string,
): Promise<boolean> {
  const out = await rpc.call({
    contractAddress: doomRuns,
    entrypoint: "is_run_registered",
    calldata: [runId],
  });
  return BigInt(out[0] ?? "0x0") === 1n;
}

/**
 * The free pre-flight: is the fact already registered, and is any member already recorded?
 *
 * Both answers change what the client should pay for — a registered fact means the 5 verifier
 * transactions can be skipped entirely, and an already-recorded run means that member will be
 * skipped on chain with `already registered` (D18) whether or not it is in the call.
 */
export async function preflight(
  rpc: RpcClient,
  args: {
    router: string;
    doomRuns: string;
    versionId: number;
    batch: WrapperBatch;
    members: Member[];
  },
): Promise<{ fact: string; factRegistered: boolean; alreadyRegistered: Member[] }> {
  const fact = await batchFact(rpc, args.doomRuns, args.versionId, args.batch);
  const factRegistered = await isFactValid(rpc, args.router, fact);
  const alreadyRegistered: Member[] = [];
  for (const m of args.members) {
    const runId = await runIdOf(rpc, args.doomRuns, args.versionId, m, args.batch);
    if (await isRunRegistered(rpc, args.doomRuns, runId)) alreadyRegistered.push(m);
  }
  return { fact, factRegistered, alreadyRegistered };
}

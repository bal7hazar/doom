// SPDX-License-Identifier: Apache-2.0
/**
 * The `DoomRuns` **commitment** events of D35 — the shape this node assumes while the contract
 * extension is written in parallel. Everything ABI-dependent about commitments lives in this
 * one file so that aligning it on the final ABI is a local edit: the field order below, the
 * event names, and the `claim_bounty` entrypoint.
 *
 * Assumed Cairo declaration (`#[key]` fields first, then `data` in declaration order — the same
 * serialisation rule `infra/indexer/src/decode.ts` reads the existing seven events with):
 *
 * ```cairo
 * struct RunCommitted {
 *     #[key] commitment_id: felt252,   // poseidon('HP.COMMIT' ‖ player ‖ version ‖ level ‖ inputs_commitment ‖ nonce), by the contract
 *     #[key] player: ContractAddress,
 *     #[key] version_id: u32,
 *     level_id: u32,
 *     genesis: felt252,                // the pinned genesis of (version, level), echoed for indexers
 *     inputs_commitment: felt252,      // commit_log(journal) over the whole packed journal
 *     tics: u32,                       // journal length in tics; packed_len(tics) == journal.len()
 *     bounty: u256,                    // escrowed STRK, low then high limb
 *     journal: Span<felt252>,          // the packed journal, 7 tics per felt (~900 felts for 3 min)
 * }
 * struct CommitmentSettled {
 *     #[key] commitment_id: felt252,
 *     #[key] prover: ContractAddress,  // who was paid, or the player on a refund
 *     run_id: felt252,                 // 0 on a refund
 *     outcome: u8,                     // 0 = proved and paid, 1 = expired and refunded
 * }
 * ```
 *
 * `claim_bounty(commitment_id)` is assumed to be a separate call made after `register_member`
 * has recorded the run (the contract checks the recorded run's `inputs_commitment` chain folds
 * to the commitment's journal). If the final ABI binds the two in one call, `claimCall` and
 * `register.ts` are the only places to touch.
 */
import { hash } from "starknet";

import type { Call } from "../../../client/src/chain/rpc.js";
import { feltToNumber, normFelt } from "../../indexer/src/felt.js";
import type { RawEvent } from "../../indexer/src/types.js";
import { commitLog, packedLen } from "./commitment.js";

export interface RunCommitment {
  commitmentId: string;
  player: string;
  versionId: number;
  levelId: number;
  genesis: string;
  inputsCommitment: string;
  tics: number;
  /** Escrowed bounty in FRI (u256 recomposed). */
  bounty: bigint;
  /** The packed journal, one `0x…` felt per seven tics. */
  journal: string[];
  blockNumber: number;
  txHash: string;
}

export interface RunCommittedEvent extends RunCommitment {
  kind: "RunCommitted";
}

export interface CommitmentSettledEvent {
  kind: "CommitmentSettled";
  commitmentId: string;
  prover: string;
  runId: string;
  outcome: "proved" | "refunded";
  blockNumber: number;
  txHash: string;
}

export type CommitmentEvent = RunCommittedEvent | CommitmentSettledEvent;

export const COMMITMENT_EVENT_NAMES = ["RunCommitted", "CommitmentSettled"] as const;

/** Selector -> event name, computed once (`hash.getSelectorFromName`, as for entrypoints). */
export const COMMITMENT_SELECTORS: Record<string, (typeof COMMITMENT_EVENT_NAMES)[number]> =
  Object.fromEntries(COMMITMENT_EVENT_NAMES.map((n) => [normFelt(hash.getSelectorFromName(n)), n]));

/** Decodes one raw `starknet_getEvents` entry; `undefined` for any other `DoomRuns` event. */
export function decodeCommitmentEvent(raw: RawEvent): CommitmentEvent | undefined {
  const selector = raw.keys[0];
  if (selector === undefined) return undefined;
  const name = COMMITMENT_SELECTORS[normFelt(selector)];
  if (!name) return undefined;
  const keys = raw.keys.slice(1);
  const data = raw.data;
  const common = { blockNumber: raw.block_number, txHash: raw.transaction_hash };
  const need = (cond: boolean, what: string): void => {
    if (!cond) throw new Error(`${name} in ${raw.transaction_hash}: malformed ${what}`);
  };

  switch (name) {
    case "RunCommitted": {
      const [commitmentId, player, versionId] = keys;
      need(keys.length === 3, "keys");
      const [levelId, genesis, inputsCommitment, tics, bountyLow, bountyHigh, journalLen, ...rest] = data;
      need(data.length >= 7, "data");
      const n = feltToNumber(journalLen!);
      need(rest.length === n, `journal length (declared ${n}, got ${rest.length})`);
      return {
        kind: "RunCommitted",
        commitmentId: normFelt(commitmentId!),
        player: normFelt(player!),
        versionId: feltToNumber(versionId!),
        levelId: feltToNumber(levelId!),
        genesis: normFelt(genesis!),
        inputsCommitment: normFelt(inputsCommitment!),
        tics: feltToNumber(tics!),
        bounty: BigInt(bountyLow!) + (BigInt(bountyHigh!) << 128n),
        journal: rest.map((f) => normFelt(f)),
        ...common,
      };
    }
    case "CommitmentSettled": {
      const [commitmentId, prover] = keys;
      need(keys.length === 2, "keys");
      const [runId, outcome] = data;
      need(data.length === 2, "data");
      const code = feltToNumber(outcome!);
      need(code === 0 || code === 1, `outcome ${code}`);
      return {
        kind: "CommitmentSettled",
        commitmentId: normFelt(commitmentId!),
        prover: normFelt(prover!),
        runId: normFelt(runId!),
        outcome: code === 0 ? "proved" : "refunded",
        ...common,
      };
    }
  }
}

/**
 * The cheap integrity checks of a commitment, before any execution: the journal has exactly
 * `packed_len(tics)` felts, every felt fits its lanes, the fold reproduces `inputs_commitment`,
 * and the genesis is the one this node expects for `(version, level)` when it knows it.
 */
export function checkCommitment(
  c: RunCommitment,
  expected: { genesis?: string } = {},
): string[] {
  const problems: string[] = [];
  if (!Number.isSafeInteger(c.tics) || c.tics <= 0) problems.push(`tics ${c.tics} is not a positive count`);
  const want = packedLen(Math.max(0, c.tics));
  if (c.journal.length !== want) {
    problems.push(`journal has ${c.journal.length} felts, packed_len(${c.tics}) = ${want}`);
  }
  const last = c.journal[c.journal.length - 1];
  if (last !== undefined && c.tics > 0) {
    const lanes = c.tics - (c.journal.length - 1) * 7;
    if (BigInt(last) >= 1n << BigInt(32 * lanes)) {
      problems.push(`last felt carries more than the ${lanes} lane(s) the tic count allows`);
    }
  }
  if (c.journal.some((f) => BigInt(f) >= 1n << 224n)) problems.push("a felt exceeds seven 32-bit lanes");
  if (problems.length === 0) {
    const fold = commitLog(c.journal.map((f) => BigInt(f)));
    if (fold !== BigInt(c.inputsCommitment)) {
      problems.push(`commit_log(journal) = 0x${fold.toString(16)} differs from inputs_commitment ${c.inputsCommitment}`);
    }
  }
  if (expected.genesis !== undefined && BigInt(expected.genesis) !== BigInt(c.genesis)) {
    problems.push(`genesis ${c.genesis} is not the pinned ${expected.genesis} for version ${c.versionId} level ${c.levelId}`);
  }
  return problems;
}

/** `DoomRuns.claim_bounty(commitment_id)` — assumed entrypoint, see the file comment. */
export function claimCall(doomRuns: string, commitmentId: string): Call {
  return { contractAddress: doomRuns, entrypoint: "claim_bounty", calldata: [normFelt(commitmentId)] };
}

/**
 * A wrapper `run_id` for a commitment: client-chosen, `[A-Za-z0-9_-]{1,64}`, stable across
 * restarts so a resumed upload finds what the server already holds.
 */
export function wrapperRunId(commitmentId: string): string {
  return `hp-${BigInt(commitmentId).toString(36)}`;
}

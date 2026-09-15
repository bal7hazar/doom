// SPDX-License-Identifier: Apache-2.0
/**
 * The `DoomRuns` **commitment** ABI of D35 — everything ABI-dependent about commitments lives
 * in this one file: the four events, their decoders, the `Commitment` view struct, the id
 * derivation and the settlement rule the cut has to respect.
 *
 * Events (`#[key]` fields marked `*`, serialised as `keys[0] = selector(name)`, then the keys,
 * then every other field in `data` in declaration order — the rule `infra/indexer` reads the
 * older events with):
 *
 * ```text
 * RunCommitted        { commitment_id*, player*, version_id*, level_id, genesis, inputs_commitment,
 *                       tics: u32, bounty: u256, expires_at: u64, n_chunks: u32 }
 * RunLog              { commitment_id*, chunk: u32, offset: u32, packed: Span<felt252> }
 *                       — the packed journal is NOT stored on chain: it is emitted in `n_chunks`
 *                       events of ≤ 256 felts in the same transaction; `offset` is the position of
 *                       the chunk's first felt. Concatenated in chunk order they are the journal.
 * CommitmentProved    { commitment_id*, run_id*, prover*, player, bounty: u256 }
 * CommitmentReclaimed { commitment_id*, player*, bounty: u256 }
 * ```
 *
 * `commitment_id = poseidon('HP.COMMIT', version_id, level_id, player, commit_log(packed))`
 * (`poseidon_hash_span` over the five felts, as this port computes it — see `commitmentIdOf`).
 *
 * **Settlement rule** (what pays the bounty): a member submitted with `register_member` /
 * `submit_batch` settles the commitment only if version, level, player, `tics` and genesis are
 * equal and the contract can recompute the game-level commitment: with one segment it is the
 * leaf's `inputs_commitment`; with several, the contract folds the concatenation of the
 * `ReplayLog`s supplied with the submission — which is only the committed journal if **every
 * non-final segment covers a multiple of 7 tics** (a segment's log is its slice re-packed from
 * its first tic). Hence `segmenter.ts` aligns every non-final boundary on 7 tics and
 * `register.ts` always publishes the replay logs of a multi-segment run.
 */
import { hash } from "starknet";

import type { RpcClient } from "../../../client/src/chain/rpc.js";
import { feltToNumber, normFelt } from "../../indexer/src/felt.js";
import type { RawEvent } from "../../indexer/src/types.js";
import { commitLog, packedLen, shortString } from "./commitment.js";

/** `'HP.COMMIT'`, the domain of the commitment id. */
export const TAG_COMMIT = shortString("HP.COMMIT");

export const COMMITMENT_STATUS = { NONE: 0, PENDING: 1, PROVED: 2, RECLAIMED: 3 } as const;

/** A commitment with its journal assembled from the `RunLog` chunks. */
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
  /** Block after which the player may reclaim; 0 = never. */
  expiresAt: number;
  nChunks: number;
  /** The packed journal, one `0x…` felt per seven tics, concatenated from the chunks. */
  journal: string[];
  blockNumber: number;
  txHash: string;
}

export interface RunCommittedEvent extends Omit<RunCommitment, "journal"> {
  kind: "RunCommitted";
}

export interface RunLogEvent {
  kind: "RunLog";
  commitmentId: string;
  chunk: number;
  offset: number;
  packed: string[];
  blockNumber: number;
  txHash: string;
}

export interface CommitmentProvedEvent {
  kind: "CommitmentProved";
  commitmentId: string;
  runId: string;
  prover: string;
  player: string;
  bounty: bigint;
  blockNumber: number;
  txHash: string;
}

export interface CommitmentReclaimedEvent {
  kind: "CommitmentReclaimed";
  commitmentId: string;
  player: string;
  bounty: bigint;
  blockNumber: number;
  txHash: string;
}

export type CommitmentEvent = RunCommittedEvent | RunLogEvent | CommitmentProvedEvent | CommitmentReclaimedEvent;

export const COMMITMENT_EVENT_NAMES = ["RunCommitted", "RunLog", "CommitmentProved", "CommitmentReclaimed"] as const;

/** Selector -> event name (`hash.getSelectorFromName`). Pinned in `test/commitments.test.ts`. */
export const COMMITMENT_SELECTORS: Record<string, (typeof COMMITMENT_EVENT_NAMES)[number]> =
  Object.fromEntries(COMMITMENT_EVENT_NAMES.map((n) => [normFelt(hash.getSelectorFromName(n)), n]));

const u256 = (low: string, high: string): bigint => BigInt(low) + (BigInt(high) << 128n);

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
      need(keys.length === 3 && data.length === 8, "layout");
      const [commitmentId, player, versionId] = keys;
      const [levelId, genesis, inputsCommitment, tics, bountyLow, bountyHigh, expiresAt, nChunks] = data;
      return {
        kind: "RunCommitted",
        commitmentId: normFelt(commitmentId!),
        player: normFelt(player!),
        versionId: feltToNumber(versionId!),
        levelId: feltToNumber(levelId!),
        genesis: normFelt(genesis!),
        inputsCommitment: normFelt(inputsCommitment!),
        tics: feltToNumber(tics!),
        bounty: u256(bountyLow!, bountyHigh!),
        expiresAt: feltToNumber(expiresAt!),
        nChunks: feltToNumber(nChunks!),
        ...common,
      };
    }
    case "RunLog": {
      need(keys.length === 1 && data.length >= 3, "layout");
      const [chunk, offset, len, ...rest] = data;
      const n = feltToNumber(len!);
      need(rest.length === n, `packed length (declared ${n}, got ${rest.length})`);
      return {
        kind: "RunLog",
        commitmentId: normFelt(keys[0]!),
        chunk: feltToNumber(chunk!),
        offset: feltToNumber(offset!),
        packed: rest.map((f) => normFelt(f)),
        ...common,
      };
    }
    case "CommitmentProved": {
      need(keys.length === 3 && data.length === 3, "layout");
      const [commitmentId, runId, prover] = keys;
      const [player, low, high] = data;
      return {
        kind: "CommitmentProved",
        commitmentId: normFelt(commitmentId!),
        runId: normFelt(runId!),
        prover: normFelt(prover!),
        player: normFelt(player!),
        bounty: u256(low!, high!),
        ...common,
      };
    }
    case "CommitmentReclaimed": {
      need(keys.length === 2 && data.length === 2, "layout");
      const [commitmentId, player] = keys;
      const [low, high] = data;
      return { kind: "CommitmentReclaimed", commitmentId: normFelt(commitmentId!), player: normFelt(player!), bounty: u256(low!, high!), ...common };
    }
  }
}

/**
 * Concatenates the `RunLog` chunks of a commitment. `null` while chunks are missing; throws on
 * a chunk that contradicts the header (bad offset, wrong total length).
 */
export function assembleJournal(header: RunCommittedEvent, chunks: readonly RunLogEvent[]): string[] | null {
  const byChunk = new Map<number, RunLogEvent>();
  for (const c of chunks) {
    if (c.commitmentId !== header.commitmentId) continue;
    const prev = byChunk.get(c.chunk);
    if (prev && (prev.offset !== c.offset || prev.packed.join() !== c.packed.join())) {
      throw new Error(`commitment ${header.commitmentId}: chunk ${c.chunk} was emitted twice with different contents`);
    }
    byChunk.set(c.chunk, c);
  }
  if (byChunk.size < header.nChunks) return null;
  const journal: string[] = [];
  for (let i = 0; i < header.nChunks; i++) {
    const c = byChunk.get(i);
    if (!c) return null;
    if (c.offset !== journal.length) {
      throw new Error(`commitment ${header.commitmentId}: chunk ${i} starts at ${c.offset}, expected ${journal.length}`);
    }
    if (c.packed.length > 256) throw new Error(`commitment ${header.commitmentId}: chunk ${i} carries ${c.packed.length} felts (> 256)`);
    journal.push(...c.packed);
  }
  const want = packedLen(header.tics);
  if (journal.length !== want) {
    throw new Error(`commitment ${header.commitmentId}: ${journal.length} felts over ${header.nChunks} chunk(s), packed_len(${header.tics}) = ${want}`);
  }
  return journal;
}

/** `poseidon('HP.COMMIT', version_id, level_id, player, inputs_commitment)`. */
export function commitmentIdOf(versionId: number, levelId: number, player: string, inputsCommitment: bigint | string): string {
  return normFelt(
    hash.computePoseidonHashOnElements([TAG_COMMIT, BigInt(versionId), BigInt(levelId), BigInt(player), BigInt(inputsCommitment)]),
  );
}

/**
 * The cheap integrity checks of a commitment, before any execution: the journal has exactly
 * `packed_len(tics)` felts, every felt fits its lanes, the fold reproduces `inputs_commitment`,
 * the id is the one the contract derives, and the genesis is the pinned one when known.
 */
export function checkCommitment(c: RunCommitment, expected: { genesis?: string; head?: number } = {}): string[] {
  const problems: string[] = [];
  if (!Number.isSafeInteger(c.tics) || c.tics <= 0) problems.push(`tics ${c.tics} is not a positive count`);
  const want = packedLen(Math.max(0, c.tics));
  if (c.journal.length !== want) problems.push(`journal has ${c.journal.length} felts, packed_len(${c.tics}) = ${want}`);
  const last = c.journal[c.journal.length - 1];
  if (last !== undefined && c.tics > 0) {
    const lanes = c.tics - (c.journal.length - 1) * 7;
    if (BigInt(last) >= 1n << BigInt(32 * lanes)) problems.push(`last felt carries more than the ${lanes} lane(s) the tic count allows`);
  }
  if (c.journal.some((f) => BigInt(f) >= 1n << 224n)) problems.push("a felt exceeds seven 32-bit lanes");
  if (problems.length === 0) {
    const fold = commitLog(c.journal.map((f) => BigInt(f)));
    if (fold !== BigInt(c.inputsCommitment)) {
      problems.push(`commit_log(journal) = 0x${fold.toString(16)} differs from inputs_commitment ${c.inputsCommitment}`);
    }
  }
  const id = commitmentIdOf(c.versionId, c.levelId, c.player, c.inputsCommitment);
  if (BigInt(id) !== BigInt(c.commitmentId)) problems.push(`commitment_id ${c.commitmentId} is not poseidon('HP.COMMIT', …) = ${id}`);
  if (expected.genesis !== undefined && BigInt(expected.genesis) !== BigInt(c.genesis)) {
    problems.push(`genesis ${c.genesis} is not the pinned ${expected.genesis} for version ${c.versionId} level ${c.levelId}`);
  }
  if (expected.head !== undefined && c.expiresAt > 0 && expected.head >= c.expiresAt) {
    problems.push(`expired at block ${c.expiresAt} (head ${expected.head})`);
  }
  return problems;
}

/** `DoomRuns.get_commitment(commitment_id)` — the `Commitment` struct, 13 felts. */
export interface CommitmentView {
  player: string;
  versionId: number;
  levelId: number;
  genesis: string;
  inputsCommitment: string;
  tics: number;
  bounty: bigint;
  createdBlock: number;
  expiresAt: number;
  status: number;
  runId: string;
  prover: string;
}

export function decodeCommitmentView(out: readonly string[]): CommitmentView {
  if (out.length < 13) throw new Error(`get_commitment returned ${out.length} felts, expected 13`);
  const [player, versionId, levelId, genesis, inputsCommitment, tics, low, high, createdBlock, expiresAt, status, runId, prover] = out;
  return {
    player: normFelt(player!),
    versionId: feltToNumber(versionId!),
    levelId: feltToNumber(levelId!),
    genesis: normFelt(genesis!),
    inputsCommitment: normFelt(inputsCommitment!),
    tics: feltToNumber(tics!),
    bounty: u256(low!, high!),
    createdBlock: feltToNumber(createdBlock!),
    expiresAt: feltToNumber(expiresAt!),
    status: feltToNumber(status!),
    runId: normFelt(runId!),
    prover: normFelt(prover!),
  };
}

export async function getCommitment(rpc: RpcClient, doomRuns: string, commitmentId: string): Promise<CommitmentView> {
  const out = await rpc.call({ contractAddress: doomRuns, entrypoint: "get_commitment", calldata: [normFelt(commitmentId)] });
  return decodeCommitmentView(out);
}

/** Finds the settlement of `commitmentId` among a receipt's events, if the transaction paid it. */
export function settlementIn(events: readonly { keys?: string[]; data?: string[] }[] | undefined, commitmentId: string): CommitmentProvedEvent | null {
  const selector = normFelt(hash.getSelectorFromName("CommitmentProved"));
  for (const ev of events ?? []) {
    const keys = ev.keys ?? [];
    if (keys.length === 4 && normFelt(keys[0]!) === selector && BigInt(keys[1]!) === BigInt(commitmentId) && (ev.data?.length ?? 0) === 3) {
      const decoded = decodeCommitmentEvent({ from_address: "0x0", keys, data: ev.data!, block_number: 0, block_hash: "0x0", transaction_hash: "0x0" });
      if (decoded?.kind === "CommitmentProved") return decoded;
    }
  }
  return null;
}

/**
 * A wrapper `run_id` for a commitment: client-chosen, `[A-Za-z0-9_-]{1,64}`, stable across
 * restarts so a resumed upload finds what the server already holds.
 */
export function wrapperRunId(commitmentId: string): string {
  return `hp-${BigInt(commitmentId).toString(36)}`;
}

// SPDX-License-Identifier: Apache-2.0
/**
 * Event and row shapes of the `DoomRuns` indexer (P4.4).
 *
 * Field layouts mirror `cairo/doom_contracts/crates/doom_runs/src/doom_runs.cairo`'s `Event`
 * enum exactly (`docs/design/doomruns.md` §2 lists the same events). Every event carries the
 * block it was emitted in — that is the join key `purgeFromBlock` uses to make a re-scan of the
 * last N blocks (a possible reorg) idempotent.
 */

/** One `starknet_getEvents` entry, the shape the RPC returns before decoding. */
export interface RawEvent {
  from_address: string;
  keys: string[];
  data: string[];
  block_number: number;
  block_hash: string;
  transaction_hash: string;
}

export interface RunSubmittedEvent {
  kind: "RunSubmitted";
  runId: string;
  player: string;
  versionId: number;
  levelId: number;
  tics: number;
  kills: number;
  items: number;
  secrets: number;
  score: number;
  nSegments: number;
  fact: string;
  blockNumber: number;
  txHash: string;
}

export interface AttemptRecordedEvent {
  kind: "AttemptRecorded";
  runId: string;
  player: string;
  versionId: number;
  levelId: number;
  tics: number;
  score: number;
  fact: string;
  blockNumber: number;
  txHash: string;
}

export interface MemberRejectedEvent {
  kind: "MemberRejected";
  memberIndex: number;
  player: string;
  reason: string;
  reasonText: string;
  leafStart: number;
  leafLen: number;
  blockNumber: number;
  txHash: string;
}

export interface ReplayEvent {
  kind: "Replay";
  runId: string;
  leafIndex: number;
  ticStart: number;
  ticEnd: number;
  packed: string[];
  blockNumber: number;
  txHash: string;
}

export interface VersionAddedEvent {
  kind: "VersionAdded";
  versionId: number;
  programHash: string;
  registryName: string;
  registryNameText: string;
  verifierRouter: string;
  blockNumber: number;
  txHash: string;
}

export interface GenesisSetEvent {
  kind: "GenesisSet";
  versionId: number;
  levelId: number;
  genesis: string;
  blockNumber: number;
  txHash: string;
}

export interface FrozenEvent {
  kind: "Frozen";
  by: string;
  blockNumber: number;
  txHash: string;
}

/** D35: a game committed to the open prover (`commit_run`); the log follows in `RunLog` events. */
export interface RunCommittedEvent {
  kind: "RunCommitted";
  commitmentId: string;
  player: string;
  versionId: number;
  levelId: number;
  genesis: string;
  inputsCommitment: string;
  tics: number;
  /** `u256`, kept as a decimal string — larger than a JS number can hold exactly. */
  bounty: string;
  expiresAt: number;
  nChunks: number;
  blockNumber: number;
  txHash: string;
}

/**
 * One chunk of a committed log. The felts themselves are *not* kept (~900 felts per game, the
 * events being their only copy is a prover node's concern, not the leaderboard's): the indexer
 * only counts the chunks so a page can say whether the whole log was published.
 */
export interface RunLogEvent {
  kind: "RunLog";
  commitmentId: string;
  chunk: number;
  offset: number;
  packedLen: number;
  blockNumber: number;
  txHash: string;
}

export interface CommitmentProvedEvent {
  kind: "CommitmentProved";
  commitmentId: string;
  runId: string;
  prover: string;
  player: string;
  bounty: string;
  blockNumber: number;
  txHash: string;
}

export interface CommitmentReclaimedEvent {
  kind: "CommitmentReclaimed";
  commitmentId: string;
  player: string;
  bounty: string;
  blockNumber: number;
  txHash: string;
}

export type DoomRunsEvent =
  | RunSubmittedEvent
  | AttemptRecordedEvent
  | MemberRejectedEvent
  | ReplayEvent
  | VersionAddedEvent
  | GenesisSetEvent
  | FrozenEvent
  | RunCommittedEvent
  | RunLogEvent
  | CommitmentProvedEvent
  | CommitmentReclaimedEvent;

/** The slice of `starknet_getEvents` this package needs. Implemented once over starknet.js's
 * `RpcProvider` (`rpcSource.ts`) and once over a fixed page list (tests). */
export interface EventSource {
  blockNumber(): Promise<number>;
  getEvents(args: {
    address: string;
    fromBlock: number;
    toBlock: number;
    chunkSize: number;
    continuationToken?: string;
  }): Promise<{ events: RawEvent[]; continuationToken?: string }>;
}

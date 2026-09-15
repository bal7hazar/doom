// SPDX-License-Identifier: Apache-2.0
/**
 * Discovery: the commitments `DoomRuns` has emitted and not settled yet.
 *
 * Reads `RunCommitted` / `CommitmentSettled` through the indexer's {@link EventSource} (the same
 * `starknet_getEvents` pager, `infra/indexer/src/rpcSource.ts` for a real node, a fixed list in
 * tests), with the indexer's reorg rule: the last `reorgDepth` blocks are re-scanned on every
 * poll. Commitments are immutable and keyed by id, so a re-scan is idempotent; a commitment
 * that vanished in a reorg is dropped from the open set and picked up again if it comes back.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

import type { EventSource } from "../../indexer/src/types.js";
import { decodeCommitmentEvent, type CommitmentSettledEvent, type RunCommitment } from "./commitments.js";

export interface DiscoveryState {
  /** Head of the last successful poll, the next poll resumes `reorgDepth` blocks below it. */
  lastBlock: number | null;
  committed: Record<string, RunCommitment>;
  settled: Record<string, CommitmentSettledEvent>;
}

export function emptyDiscoveryState(): DiscoveryState {
  return { lastBlock: null, committed: {}, settled: {} };
}

export interface DiscoveryOptions {
  address: string;
  startBlock: number;
  reorgDepth?: number;
  chunkSize?: number;
}

export interface DiscoveryResult {
  fromBlock: number;
  head: number;
  seen: number;
  /** Open = committed and not settled, oldest block first. */
  open: RunCommitment[];
}

/**
 * One poll. Rows learned from `[fromBlock, head]` are purged and re-derived, everything below is
 * kept — same shape as `infra/indexer/src/indexer.ts::pollOnce`, over two maps instead of SQLite.
 */
export async function discoverOnce(
  source: EventSource,
  state: DiscoveryState,
  options: DiscoveryOptions,
): Promise<DiscoveryResult> {
  const reorgDepth = options.reorgDepth ?? 10;
  const head = await source.blockNumber();
  const fromBlock =
    state.lastBlock === null ? options.startBlock : Math.max(options.startBlock, state.lastBlock - reorgDepth + 1);
  if (fromBlock > head) return { fromBlock, head, seen: 0, open: openCommitments(state) };

  for (const [id, c] of Object.entries(state.committed)) if (c.blockNumber >= fromBlock) delete state.committed[id];
  for (const [id, s] of Object.entries(state.settled)) if (s.blockNumber >= fromBlock) delete state.settled[id];

  let seen = 0;
  let continuationToken: string | undefined;
  do {
    const page = await source.getEvents({
      address: options.address,
      fromBlock,
      toBlock: head,
      chunkSize: options.chunkSize ?? 1000,
      ...(continuationToken ? { continuationToken } : {}),
    });
    for (const raw of page.events) {
      let decoded;
      try {
        decoded = decodeCommitmentEvent(raw);
      } catch {
        continue; // a malformed commitment is not provable; it is skipped, not fatal
      }
      if (!decoded) continue;
      seen++;
      if (decoded.kind === "RunCommitted") {
        const { kind: _kind, ...commitment } = decoded;
        state.committed[commitment.commitmentId] = commitment;
      } else {
        state.settled[decoded.commitmentId] = decoded;
      }
    }
    continuationToken = page.continuationToken;
  } while (continuationToken);

  state.lastBlock = head;
  return { fromBlock, head, seen, open: openCommitments(state) };
}

export function openCommitments(state: DiscoveryState): RunCommitment[] {
  return Object.values(state.committed)
    .filter((c) => !(c.commitmentId in state.settled))
    .sort((a, b) => a.blockNumber - b.blockNumber || a.commitmentId.localeCompare(b.commitmentId));
}

/** JSON file persistence of the discovery state (bigints as decimal strings). */
export class FileDiscoveryStore {
  constructor(private readonly path: string) {}

  load(): DiscoveryState {
    if (!existsSync(this.path)) return emptyDiscoveryState();
    try {
      const raw = JSON.parse(readFileSync(this.path, "utf8")) as DiscoveryState;
      for (const c of Object.values(raw.committed)) c.bounty = BigInt(c.bounty as unknown as string);
      return raw;
    } catch {
      return emptyDiscoveryState();
    }
  }

  save(state: DiscoveryState): void {
    mkdirSync(dirname(this.path), { recursive: true });
    writeFileSync(
      this.path,
      JSON.stringify(state, (_k, v: unknown) => (typeof v === "bigint" ? v.toString() : v), 1),
    );
  }
}

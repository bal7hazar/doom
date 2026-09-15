// SPDX-License-Identifier: Apache-2.0
/**
 * Discovery: the commitments `DoomRuns` has emitted, with their journals assembled from the
 * `RunLog` chunks, minus the ones proved, reclaimed or expired.
 *
 * Reads through the indexer's {@link EventSource} (the same `starknet_getEvents` pager,
 * `rpcSource.ts` for a real node, a fixed list in tests) with the indexer's reorg rule: the last
 * `reorgDepth` blocks are re-scanned on every poll. Everything is keyed by commitment id and
 * immutable, so a re-scan is idempotent; a commitment that vanished in a reorg is dropped from
 * the open set and picked up again if it comes back.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

import type { EventSource } from "../../indexer/src/types.js";
import {
  assembleJournal,
  decodeCommitmentEvent,
  type CommitmentProvedEvent,
  type CommitmentReclaimedEvent,
  type RunCommittedEvent,
  type RunCommitment,
  type RunLogEvent,
} from "./commitments.js";

export type Settlement = CommitmentProvedEvent | CommitmentReclaimedEvent;

export interface DiscoveryState {
  /** Head of the last successful poll, the next poll resumes `reorgDepth` blocks below it. */
  lastBlock: number | null;
  headers: Record<string, RunCommittedEvent>;
  chunks: Record<string, RunLogEvent[]>;
  settled: Record<string, Settlement>;
}

export function emptyDiscoveryState(): DiscoveryState {
  return { lastBlock: null, headers: {}, chunks: {}, settled: {} };
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
  /** Open = committed with a complete journal, not settled, not expired; oldest block first. */
  open: RunCommitment[];
  /** Commitments whose journal chunks are missing or inconsistent (never provable as seen). */
  incomplete: { commitmentId: string; reason: string }[];
}

/** One poll: purge-and-rescan `[fromBlock, head]`, page, apply, advance the cursor. */
export async function discoverOnce(source: EventSource, state: DiscoveryState, options: DiscoveryOptions): Promise<DiscoveryResult> {
  const reorgDepth = options.reorgDepth ?? 10;
  const head = await source.blockNumber();
  const fromBlock = state.lastBlock === null ? options.startBlock : Math.max(options.startBlock, state.lastBlock - reorgDepth + 1);
  if (fromBlock > head) return { fromBlock, head, seen: 0, ...openCommitments(state, head) };

  for (const [id, h] of Object.entries(state.headers)) if (h.blockNumber >= fromBlock) delete state.headers[id];
  for (const [id, s] of Object.entries(state.settled)) if (s.blockNumber >= fromBlock) delete state.settled[id];
  for (const [id, list] of Object.entries(state.chunks)) {
    const kept = list.filter((c) => c.blockNumber < fromBlock);
    if (kept.length) state.chunks[id] = kept;
    else delete state.chunks[id];
  }

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
        continue; // a malformed event is not provable; it is skipped, not fatal
      }
      if (!decoded) continue;
      seen++;
      switch (decoded.kind) {
        case "RunCommitted":
          state.headers[decoded.commitmentId] = decoded;
          break;
        case "RunLog":
          (state.chunks[decoded.commitmentId] ??= []).push(decoded);
          break;
        default:
          state.settled[decoded.commitmentId] = decoded;
      }
    }
    continuationToken = page.continuationToken;
  } while (continuationToken);

  state.lastBlock = head;
  return { fromBlock, head, seen, ...openCommitments(state, head) };
}

export function openCommitments(state: DiscoveryState, head: number): { open: RunCommitment[]; incomplete: DiscoveryResult["incomplete"] } {
  const open: RunCommitment[] = [];
  const incomplete: DiscoveryResult["incomplete"] = [];
  for (const header of Object.values(state.headers)) {
    const id = header.commitmentId;
    if (id in state.settled) continue;
    if (header.expiresAt > 0 && head >= header.expiresAt) continue;
    let journal: string[] | null;
    try {
      journal = assembleJournal(header, state.chunks[id] ?? []);
    } catch (e) {
      incomplete.push({ commitmentId: id, reason: (e as Error).message });
      continue;
    }
    if (!journal) {
      incomplete.push({ commitmentId: id, reason: `${(state.chunks[id] ?? []).length} of ${header.nChunks} journal chunk(s) seen` });
      continue;
    }
    const { kind: _kind, ...fields } = header;
    open.push({ ...fields, journal });
  }
  open.sort((a, b) => a.blockNumber - b.blockNumber || a.commitmentId.localeCompare(b.commitmentId));
  return { open, incomplete };
}

/** JSON file persistence of the discovery state (bigints as decimal strings). */
export class FileDiscoveryStore {
  constructor(private readonly path: string) {}

  load(): DiscoveryState {
    if (!existsSync(this.path)) return emptyDiscoveryState();
    try {
      const raw = JSON.parse(readFileSync(this.path, "utf8")) as DiscoveryState;
      for (const h of Object.values(raw.headers)) h.bounty = BigInt(h.bounty as unknown as string);
      for (const s of Object.values(raw.settled)) s.bounty = BigInt(s.bounty as unknown as string);
      return { ...emptyDiscoveryState(), ...raw };
    } catch {
      return emptyDiscoveryState();
    }
  }

  save(state: DiscoveryState): void {
    mkdirSync(dirname(this.path), { recursive: true });
    writeFileSync(this.path, JSON.stringify(state, (_k, v: unknown) => (typeof v === "bigint" ? v.toString() : v), 1));
  }
}

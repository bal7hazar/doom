// SPDX-License-Identifier: Apache-2.0
/**
 * The follow loop: pages `DoomRuns` events from a start block, applies them to {@link IndexerDb},
 * and is reorg-safe by re-scanning (and purging) the last `reorgDepth` blocks on every poll.
 *
 * Reorg handling, precisely: on every poll the window `[fromBlock, head]` is treated as *not yet
 * trustworthy*, where `fromBlock = max(startBlock, cursor.lastBlock - reorgDepth + 1)`. Before
 * fetching anything, every row this indexer has ever derived from a block `>= fromBlock` is
 * deleted (`IndexerDb.purgeFromBlock`); the poll then repopulates that window from what the RPC
 * returns *now*. A chain that never reorgs just re-derives the same rows every time (idempotent,
 * cheap at `reorgDepth` ~10-20 blocks); a chain that reorged within that window ends up with
 * exactly the new canonical events, because nothing from the old fork survives the purge. Only a
 * reorg deeper than `reorgDepth` blocks would leave stale rows below `fromBlock` — the standard
 * indexer trade-off, and why `reorgDepth` should exceed the chain's practical finality window.
 *
 * Resumability: `cursor.last_block` is written after every successful poll (`db.ts`), so
 * restarting the process resumes at `cursor.lastBlock - reorgDepth + 1` instead of `startBlock`.
 */
import type { IndexerDb } from "./db.js";
import { decodeEvent } from "./decode.js";
import type { EventSource } from "./types.js";

export interface FollowOptions {
  address: string;
  startBlock: number;
  reorgDepth?: number;
  chunkSize?: number;
  onPoll?: (result: PollResult) => void;
}

export interface PollResult {
  fromBlock: number;
  head: number;
  eventsApplied: number;
}

const DEFAULT_REORG_DEPTH = 10;
const DEFAULT_CHUNK_SIZE = 1000;

/** One poll: purge-and-rescan `[fromBlock, head]`, page through `getEvents`, apply, advance the
 * cursor. Pure with respect to time (no sleeping) so it is directly unit-testable. */
export async function pollOnce(db: IndexerDb, source: EventSource, options: FollowOptions): Promise<PollResult> {
  const reorgDepth = options.reorgDepth ?? DEFAULT_REORG_DEPTH;
  const chunkSize = options.chunkSize ?? DEFAULT_CHUNK_SIZE;
  const head = await source.blockNumber();
  const cursor = db.getCursor();
  const fromBlock = cursor ? Math.max(options.startBlock, cursor.lastBlock - reorgDepth + 1) : options.startBlock;

  if (fromBlock > head) {
    return { fromBlock, head, eventsApplied: 0 };
  }

  db.purgeFromBlock(fromBlock);

  let applied = 0;
  let continuationToken: string | undefined;
  do {
    const page = await source.getEvents({
      address: options.address,
      fromBlock,
      toBlock: head,
      chunkSize,
      ...(continuationToken ? { continuationToken } : {}),
    });
    for (const raw of page.events) {
      const decoded = decodeEvent(raw);
      if (decoded) {
        db.apply(decoded);
        applied++;
      }
    }
    continuationToken = page.continuationToken;
  } while (continuationToken);

  db.setCursor(head);
  const result: PollResult = { fromBlock, head, eventsApplied: applied };
  options.onPoll?.(result);
  return result;
}

/** Runs {@link pollOnce} forever, `intervalMs` apart, until `signal` aborts. Errors are logged and
 * do not stop the loop — the next poll re-scans from the same cursor. */
export async function follow(
  db: IndexerDb,
  source: EventSource,
  options: FollowOptions & { intervalMs?: number; signal?: AbortSignal; onError?: (e: unknown) => void },
): Promise<void> {
  const intervalMs = options.intervalMs ?? 5000;
  while (!options.signal?.aborted) {
    try {
      await pollOnce(db, source, options);
    } catch (e) {
      options.onError?.(e);
    }
    if (options.signal?.aborted) break;
    await sleep(intervalMs, options.signal);
  }
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const t = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => {
      clearTimeout(t);
      resolve();
    });
  });
}

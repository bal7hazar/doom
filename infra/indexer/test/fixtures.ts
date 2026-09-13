import { hash } from "starknet";

import type { EventSource, RawEvent } from "../src/types.js";

export const sel = (name: string): string => hash.getSelectorFromName(name);

export function runSubmitted(args: {
  runId: string;
  player?: string;
  versionId?: number;
  block: number;
  tx?: string;
  score?: number;
  tics?: number;
}): RawEvent {
  return {
    from_address: "0xd00d",
    keys: [sel("RunSubmitted"), args.runId, args.player ?? "0xf1", "0x" + (args.versionId ?? 1).toString(16)],
    data: [
      "0x1", // level_id
      "0x" + (args.tics ?? 100).toString(16),
      "0x5", // kills
      "0x1", // items
      "0x0", // secrets
      "0x" + (args.score ?? 525).toString(16),
      "0x1", // n_segments
      "0xfac7",
    ],
    block_number: args.block,
    block_hash: "0xb" + args.block.toString(16),
    transaction_hash: args.tx ?? "0xed" + args.block.toString(16),
  };
}

/** A fixed, in-memory {@link EventSource}: pages a canned event list and lets a test swap the
 * list mid-run to simulate a reorg. No network, no starknet.js `RpcProvider` involved. */
export class FakeEventSource implements EventSource {
  head: number;
  events: RawEvent[];
  /** How many events `getEvents` hands back per page, to exercise continuation tokens. */
  pageSize: number;
  calls: { fromBlock: number; toBlock: number; continuationToken?: string }[] = [];

  constructor(events: RawEvent[], head: number, pageSize = 100) {
    this.events = events;
    this.head = head;
    this.pageSize = pageSize;
  }

  async blockNumber(): Promise<number> {
    return this.head;
  }

  async getEvents(args: {
    address: string;
    fromBlock: number;
    toBlock: number;
    chunkSize: number;
    continuationToken?: string;
  }): Promise<{ events: RawEvent[]; continuationToken?: string }> {
    this.calls.push({
      fromBlock: args.fromBlock,
      toBlock: args.toBlock,
      ...(args.continuationToken ? { continuationToken: args.continuationToken } : {}),
    });
    const inRange = this.events.filter((e) => e.block_number >= args.fromBlock && e.block_number <= args.toBlock);
    const start = args.continuationToken ? Number(args.continuationToken) : 0;
    const page = inRange.slice(start, start + this.pageSize);
    const next = start + this.pageSize;
    return {
      events: page,
      ...(next < inRange.length ? { continuationToken: String(next) } : {}),
    };
  }
}

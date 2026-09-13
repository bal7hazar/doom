// SPDX-License-Identifier: Apache-2.0
/** {@link EventSource} over starknet.js's `RpcProvider` — the only place this package talks to a
 * real node. `indexer.ts` never imports `RpcProvider` directly, so the follow loop and its reorg
 * handling are exercised in `test/indexer.test.ts` against a fixed, in-memory {@link EventSource}
 * with no network and no starknet.js involved. */
import { RpcProvider } from "starknet";

import type { EventSource, RawEvent } from "./types.js";

export class StarknetRpcEventSource implements EventSource {
  private readonly provider: RpcProvider;

  constructor(nodeUrl: string) {
    this.provider = new RpcProvider({ nodeUrl });
  }

  async blockNumber(): Promise<number> {
    return this.provider.getBlockNumber();
  }

  async getEvents(args: {
    address: string;
    fromBlock: number;
    toBlock: number;
    chunkSize: number;
    continuationToken?: string;
  }): Promise<{ events: RawEvent[]; continuationToken?: string }> {
    const res = await this.provider.getEvents({
      address: args.address,
      from_block: { block_number: args.fromBlock },
      to_block: { block_number: args.toBlock },
      keys: [],
      chunk_size: args.chunkSize,
      ...(args.continuationToken ? { continuation_token: args.continuationToken } : {}),
    });
    const events = res.events.map(
      (e): RawEvent => ({
        from_address: e.from_address,
        keys: e.keys,
        data: e.data,
        block_number: e.block_number ?? 0,
        block_hash: e.block_hash ?? "0x0",
        transaction_hash: e.transaction_hash,
      }),
    );
    return { events, ...(res.continuation_token ? { continuationToken: res.continuation_token } : {}) };
  }
}

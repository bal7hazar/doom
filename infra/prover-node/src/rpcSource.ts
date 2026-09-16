// SPDX-License-Identifier: Apache-2.0
/**
 * The indexer's {@link EventSource} over starknet.js — the only place this package reads events
 * from a real node. Same shape as `infra/indexer/src/rpcSource.ts`; it lives here rather than
 * being imported because that file resolves `starknet` from the indexer's own `node_modules`.
 * `discovery.ts` never imports `RpcProvider`, so discovery is tested against a fixed list.
 */
import { RpcProvider } from "starknet";

import type { EventSource, RawEvent } from "../../indexer/src/types.js";

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

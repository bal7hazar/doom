// SPDX-License-Identifier: Apache-2.0
/**
 * The slice of Starknet JSON-RPC 0.10 this package needs, over `fetch`.
 *
 * Why not starknet.js here: `Account.simulateTransaction` returns only `resourceBounds` (already
 * inflated by its own margin) and `overall_fee` — its parser *drops* the `*_gas_consumed` fields,
 * which are the only ones useful for sizing (S5 §3). The spike already had to build raw
 * `INVOKE_TXN_V3` payloads and call the RPC directly; doing the same here also keeps the browser
 * bundle free of a signing library it does not need (the wallet signs).
 */

import { getSelectorFromName } from "./selector.js";

export interface GasPrices {
  l1GasPriceFri: bigint;
  l1DataGasPriceFri: bigint;
  l2GasPriceFri: bigint;
  blockNumber: number;
  /** Block timestamp, seconds since the epoch — the sample time of the median tracker. */
  timestamp: number;
  starknetVersion: string;
}

export interface Call {
  contractAddress: string;
  entrypoint: string;
  calldata: string[];
}

export interface ResourceBound {
  max_amount: string;
  max_price_per_unit: string;
}

export interface ResourceBounds {
  l1_gas: ResourceBound;
  l1_data_gas: ResourceBound;
  l2_gas: ResourceBound;
}

export interface FeeEstimate {
  l1GasConsumed: bigint;
  l2GasConsumed: bigint;
  l1DataGasConsumed: bigint;
  overallFee: bigint;
}

export class RpcError extends Error {
  constructor(
    message: string,
    readonly method: string,
    readonly data?: unknown,
  ) {
    super(message);
    this.name = "RpcError";
  }
}

export class RpcClient {
  private id = 0;

  constructor(
    readonly url: string,
    private readonly options: { timeoutMs?: number; fetch?: typeof fetch } = {},
  ) {}

  async request<T = any>(method: string, params: unknown): Promise<T> {
    const doFetch = this.options.fetch ?? fetch;
    const res = await doFetch(this.url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++this.id, method, params }),
      signal: AbortSignal.timeout(this.options.timeoutMs ?? 180_000),
    });
    const body = (await res.json()) as { result?: T; error?: { message?: string } };
    if (body.error) {
      throw new RpcError(
        `${method}: ${JSON.stringify(body.error).slice(0, 600)}`,
        method,
        body.error,
      );
    }
    return body.result as T;
  }

  async specVersion(): Promise<string> {
    return this.request<string>("starknet_specVersion", []);
  }

  async chainId(): Promise<string> {
    return this.request<string>("starknet_chainId", []);
  }

  async nonce(address: string, block: string = "latest"): Promise<bigint> {
    return BigInt(await this.request<string>("starknet_getNonce", [block, address]));
  }

  /** Gas prices of the latest block — the only prices a fee estimate may be read against. */
  async gasPrices(block: string = "latest"): Promise<GasPrices> {
    const b = await this.request<any>("starknet_getBlockWithTxHashes", [block]);
    return {
      l1GasPriceFri: BigInt(b.l1_gas_price.price_in_fri),
      l1DataGasPriceFri: BigInt(b.l1_data_gas_price.price_in_fri),
      l2GasPriceFri: BigInt(b.l2_gas_price.price_in_fri),
      blockNumber: b.block_number ?? 0,
      timestamp: b.timestamp ?? Math.floor(Date.now() / 1000),
      starknetVersion: b.starknet_version ?? "",
    };
  }

  async call(call: Call, block: string = "latest"): Promise<string[]> {
    return this.request<string[]>("starknet_call", [
      {
        contract_address: call.contractAddress,
        entry_point_selector: getSelectorFromName(call.entrypoint),
        calldata: call.calldata,
      },
      block,
    ]);
  }

  async receipt(txHash: string): Promise<any> {
    return this.request<any>("starknet_getTransactionReceipt", [txHash]);
  }

  async trace(txHash: string): Promise<any> {
    return this.request<any>("starknet_traceTransaction", [txHash]);
  }

  async simulate(txs: unknown[], flags: string[] = ["SKIP_VALIDATE"], block = "latest"): Promise<any[]> {
    return this.request<any[]>("starknet_simulateTransactions", [block, txs, flags]);
  }

  async estimateFee(txs: unknown[], flags: string[] = ["SKIP_VALIDATE"], block = "latest"): Promise<any[]> {
    return this.request<any[]>("starknet_estimateFee", [txs, flags, block]);
  }

  /** Polls until the transaction has a receipt; throws on `REVERTED`. */
  async waitForReceipt(txHash: string, timeoutMs = 900_000, pollMs = 500): Promise<any> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      try {
        const rec = await this.receipt(txHash);
        const status = rec.execution_status;
        if (status === "REVERTED") {
          throw new Error(`tx ${txHash} REVERTED: ${rec.revert_reason ?? "(no reason)"}`);
        }
        if (status === "SUCCEEDED") return rec;
      } catch (e) {
        if (e instanceof Error && e.message.includes("REVERTED")) throw e;
      }
      if (Date.now() > deadline) throw new Error(`tx ${txHash}: no receipt after ${timeoutMs} ms`);
      await new Promise((r) => setTimeout(r, pollMs));
    }
  }
}

/** `fee_estimation` (simulate) and the bare estimate (estimateFee) carry the same fields. */
export function feeEstimateOf(entry: any): FeeEstimate {
  const src = entry?.fee_estimation ?? entry;
  const big = (x: unknown): bigint => (x === undefined || x === null ? 0n : BigInt(x as string));
  return {
    l1GasConsumed: big(src.l1_gas_consumed),
    l2GasConsumed: big(src.l2_gas_consumed),
    l1DataGasConsumed: big(src.l1_data_gas_consumed),
    overallFee: big(src.overall_fee),
  };
}

export const toHex = (v: bigint | number): string =>
  "0x" + (typeof v === "bigint" ? v : BigInt(v)).toString(16);

/**
 * `__execute__` calldata of a Cairo 1 account: `[n_calls, (to, selector, len, …calldata) × n]`.
 * Equivalent to starknet.js's `transaction.getExecuteCalldata(calls, '1')`, minus the decimal
 * strings its version returns (the RPC rejects those — S5 §3, implementation note 2).
 */
export function executeCalldata(calls: Call[]): string[] {
  const out: string[] = [toHex(calls.length)];
  for (const c of calls) {
    out.push(c.contractAddress, getSelectorFromName(c.entrypoint), toHex(c.calldata.length));
    out.push(...c.calldata);
  }
  return out;
}

/** An unsigned `INVOKE_TXN_V3` — only ever valid under `SKIP_VALIDATE`, never broadcastable. */
export function invokeV3(
  sender: string,
  calls: Call[],
  nonce: bigint,
  bounds: ResourceBounds,
  tip: bigint = 0n,
): Record<string, unknown> {
  return {
    type: "INVOKE",
    version: "0x3",
    sender_address: sender,
    calldata: executeCalldata(calls),
    signature: [],
    nonce: toHex(nonce),
    resource_bounds: bounds,
    tip: toHex(tip),
    paymaster_data: [],
    account_deployment_data: [],
    nonce_data_availability_mode: "L1",
    fee_data_availability_mode: "L1",
  };
}

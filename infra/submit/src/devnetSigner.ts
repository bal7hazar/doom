// SPDX-License-Identifier: Apache-2.0
/**
 * The devnet `Signer`: a local key, a local node, nothing else.
 *
 * This is the only file in the P4.3 lane that holds a private key, and it refuses to work
 * against anything but a localhost RPC — the same guard the Python drives carry
 * (`tools/devnet_drive.py`: "refusing to drive anything but a local devnet"). Sepolia and
 * mainnet submissions are a later decision with a different key custody story; nothing here
 * should make them one flag away.
 *
 * Bounds are passed through verbatim: starknet.js would otherwise re-estimate and apply its own
 * margin, which S5 §6 measured putting the two heaviest phases over the invoke cap.
 */

import { Account, RpcProvider } from "starknet";

import type { Call, ResourceBounds } from "../../../client/src/chain/rpc.js";
import type { ExecuteOptions, Signer } from "../../../client/src/chain/signer.js";

const LOCAL_HOSTS = ["127.0.0.1", "localhost", "[::1]", "0.0.0.0"];

const toBigIntBounds = (b: ResourceBounds) => ({
  l1_gas: {
    max_amount: BigInt(b.l1_gas.max_amount),
    max_price_per_unit: BigInt(b.l1_gas.max_price_per_unit),
  },
  l1_data_gas: {
    max_amount: BigInt(b.l1_data_gas.max_amount),
    max_price_per_unit: BigInt(b.l1_data_gas.max_price_per_unit),
  },
  l2_gas: {
    max_amount: BigInt(b.l2_gas.max_amount),
    max_price_per_unit: BigInt(b.l2_gas.max_price_per_unit),
  },
});

export function assertLocalRpc(url: string): void {
  const host = (() => {
    try {
      return new URL(url).hostname;
    } catch {
      return "";
    }
  })();
  if (!LOCAL_HOSTS.includes(host)) {
    throw new Error(
      `refusing to drive anything but a local devnet (got host '${host}' from ${url}). ` +
        `P4.3 is devnet-only: no key of this package may ever touch Sepolia or mainnet.`,
    );
  }
}

export class DevnetSigner implements Signer {
  readonly kind = "devnet";
  readonly sponsored = false;
  private readonly account: Account;
  private readonly provider: RpcProvider;

  constructor(
    rpcUrl: string,
    readonly address: string,
    privateKey: string,
  ) {
    assertLocalRpc(rpcUrl);
    this.provider = new RpcProvider({ nodeUrl: rpcUrl });
    this.account = new Account({ provider: this.provider, address, signer: privateKey });
  }

  /** S5 §4.1 measured +19 % L2 gas on a calldata-dense call between two account classes. */
  async classHash(): Promise<string | undefined> {
    try {
      return await this.provider.getClassHashAt(this.address);
    } catch {
      return undefined;
    }
  }

  async execute(calls: Call[], options: ExecuteOptions): Promise<{ transactionHash: string }> {
    const res = await this.account.execute(
      calls.map((c) => ({
        contractAddress: c.contractAddress,
        entrypoint: c.entrypoint,
        calldata: c.calldata,
      })),
      // starknet.js hashes the bounds arithmetically and therefore wants **bigints**, while the
      // RPC (and `client/src/chain`) speaks 0x felts. Converting here rather than in the shared
      // package keeps the hex form, which is what a wallet's `execute` and the RPC both accept.
      { version: 3, resourceBounds: toBigIntBounds(options.bounds), tip: options.tip ?? 0n } as never,
    );
    return { transactionHash: res.transaction_hash };
  }
}

/** The devnet's own predeployed accounts — the players of the recorded games in a drive. */
export async function predeployedAccounts(
  rpcUrl: string,
): Promise<{ address: string; privateKey: string }[]> {
  assertLocalRpc(rpcUrl);
  const res = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "devnet_getPredeployedAccounts",
      params: { with_balance: false },
    }),
  });
  const body = (await res.json()) as { result?: { address: string; private_key: string }[] };
  return (body.result ?? []).map((a) => ({ address: a.address, privateKey: a.private_key }));
}

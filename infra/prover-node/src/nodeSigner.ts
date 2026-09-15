// SPDX-License-Identifier: Apache-2.0
/**
 * The node's `Signer`: a Starknet account whose key comes from the environment and nowhere else.
 *
 * - `PROVER_NODE_ADDRESS` and `PROVER_NODE_PRIVATE_KEY` are read once; the key is never logged,
 *   printed, serialised or echoed in an error. `~/.hellproof/sepolia.env` is the documented
 *   place to keep them (`set -a; . ~/.hellproof/sepolia.env; set +a`), and this package does not
 *   read that file itself: what reaches the process is the operator's decision.
 * - Devnet and Sepolia are accepted; **mainnet is refused** by chain id. The open prover of D35
 *   is a Sepolia-season role today; a mainnet key custody story is a later decision.
 * - Bounds are passed through verbatim (R7-A1), as in `infra/submit`'s `DevnetSigner`.
 */
import { Account, RpcProvider } from "starknet";

import type { Call, ResourceBounds } from "../../../client/src/chain/rpc.js";
import type { ExecuteOptions, Signer } from "../../../client/src/chain/signer.js";

export const ENV_ADDRESS = "PROVER_NODE_ADDRESS";
export const ENV_PRIVATE_KEY = "PROVER_NODE_PRIVATE_KEY";
/** `SN_MAIN` as a felt. */
export const MAINNET_CHAIN_ID = "0x534e5f4d41494e";

const toBigIntBounds = (b: ResourceBounds) => ({
  l1_gas: { max_amount: BigInt(b.l1_gas.max_amount), max_price_per_unit: BigInt(b.l1_gas.max_price_per_unit) },
  l1_data_gas: { max_amount: BigInt(b.l1_data_gas.max_amount), max_price_per_unit: BigInt(b.l1_data_gas.max_price_per_unit) },
  l2_gas: { max_amount: BigInt(b.l2_gas.max_amount), max_price_per_unit: BigInt(b.l2_gas.max_price_per_unit) },
});

export interface AccountLike {
  execute(calls: { contractAddress: string; entrypoint: string; calldata: string[] }[], details?: unknown): Promise<{ transaction_hash: string }>;
}

export class NodeSigner implements Signer {
  readonly kind = "node";
  readonly sponsored = false;
  private readonly account: AccountLike;
  private readonly provider: RpcProvider | null;

  /** `account` is injected by tests; production builds a starknet.js `Account` from the key. */
  constructor(rpcUrl: string, readonly address: string, privateKey: string, account?: AccountLike) {
    if (!/^0x[0-9a-fA-F]{1,64}$/.test(privateKey)) throw new Error(`${ENV_PRIVATE_KEY} is not a hex felt`);
    if (account) {
      this.account = account;
      this.provider = null;
    } else {
      this.provider = new RpcProvider({ nodeUrl: rpcUrl });
      this.account = new Account({ provider: this.provider, address, signer: privateKey });
    }
  }

  /** Reads the two variables; the message on failure names them and nothing else. */
  static fromEnv(rpcUrl: string, env: NodeJS.ProcessEnv = process.env, account?: AccountLike): NodeSigner {
    const address = env[ENV_ADDRESS];
    const key = env[ENV_PRIVATE_KEY];
    if (!address || !key) {
      throw new Error(`the node signer needs ${ENV_ADDRESS} and ${ENV_PRIVATE_KEY} in the environment (see README: ~/.hellproof/sepolia.env)`);
    }
    return new NodeSigner(rpcUrl, address, key, account);
  }

  async classHash(): Promise<string | undefined> {
    try {
      return await this.provider?.getClassHashAt(this.address);
    } catch {
      return undefined;
    }
  }

  async execute(calls: Call[], options: ExecuteOptions): Promise<{ transactionHash: string }> {
    const res = await this.account.execute(
      calls.map((c) => ({ contractAddress: c.contractAddress, entrypoint: c.entrypoint, calldata: c.calldata })),
      { version: 3, resourceBounds: toBigIntBounds(options.bounds), tip: options.tip ?? 0n },
    );
    return { transactionHash: res.transaction_hash };
  }

  /** Nothing secret leaves through inspection, logging or JSON. */
  toJSON(): { kind: string; address: string } {
    return { kind: this.kind, address: this.address };
  }

  toString(): string {
    return `NodeSigner(${this.address})`;
  }
}

/** Refuses a mainnet chain id; devnet and Sepolia pass. */
export async function assertNotMainnet(rpc: { chainId(): Promise<string> }): Promise<string> {
  const id = await rpc.chainId();
  if (BigInt(id) === BigInt(MAINNET_CHAIN_ID)) {
    throw new Error("refusing to sign on mainnet (SN_MAIN): the prover node is a devnet/Sepolia role");
  }
  return id;
}

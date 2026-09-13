// SPDX-License-Identifier: Apache-2.0
/** Block-explorer links for the run detail view's "on-chain proof of validity" panel: Voyager on
 * a public network, nothing clickable on a devnet (there is no public explorer for it). */
import type { NetworkKind } from "./types.js";

const VOYAGER_HOST: Record<Exclude<NetworkKind, "devnet">, string> = {
  mainnet: "voyager.online",
  sepolia: "sepolia.voyager.online",
};

export function txLink(network: NetworkKind, txHash: string): string | undefined {
  if (network === "devnet") return undefined;
  return `https://${VOYAGER_HOST[network]}/tx/${txHash}`;
}

export function contractLink(network: NetworkKind, address: string): string | undefined {
  if (network === "devnet") return undefined;
  return `https://${VOYAGER_HOST[network]}/contract/${address}`;
}

/** `?network=` accepts the two public names; anything else (including no param) is a devnet. */
export function parseNetwork(value: string | null): NetworkKind {
  return value === "mainnet" || value === "sepolia" ? value : "devnet";
}

#!/usr/bin/env -S npx tsx
// SPDX-License-Identifier: Apache-2.0
/**
 * The account-class sensitivity probe (R7-A1, S5 §4.1).
 *
 * S5 measured **+19.1 %** L2 gas on the same calldata-dense transaction sent from two different
 * account classes, and could not attribute the surcharge: in `stage_proof` a slot was both a
 * calldata felt and a storage write. The P4.0 router settles that ambiguity, because
 * `probe_noop(payload)` reads the calldata and writes **nothing** — so the slope of gas against
 * calldata length is the account class's cost of carrying calldata, full stop.
 *
 * Two lengths, one line: `gas(n) = envelope + slope × n`. Run it from each account class and
 * compare the slopes; `slope × 4 627` is what the class adds to the worst transaction of a
 * submission, which is the number that decides whether a class fits under the invoke cap.
 *
 *   scripts/account_class_probe.ts --rpc http://127.0.0.1:5081/rpc --router 0x… \
 *       --account 0x… [--account 0x…] [--out results/account_class.json]
 *
 * Estimation only: `SKIP_VALIDATE`, empty signature, nothing signed, nothing sent. Devnet only.
 */

import { writeFileSync } from "node:fs";

import {
  feeEstimateOf,
  invokeV3,
  RpcClient,
  toHex,
  type Call,
} from "../../../client/src/chain/rpc.js";
import { simulationBounds } from "../../../client/src/chain/estimate.js";
import { assertLocalRpc } from "../src/devnetSigner.js";

const argv = process.argv.slice(2);
const arg = (name: string, dflt?: string): string => {
  const i = argv.indexOf(`--${name}`);
  if (i >= 0 && i + 1 < argv.length) return argv[i + 1]!;
  if (dflt !== undefined) return dflt;
  throw new Error(`missing --${name}`);
};
const all = (name: string): string[] =>
  argv.flatMap((v, i) => (v === `--${name}` && argv[i + 1] ? [argv[i + 1]!] : []));

/** `probe_noop(payload: Span<felt252>)`: reads `n` calldata felts, touches no storage. */
const probe = (router: string, n: number): Call => ({
  contractAddress: router,
  entrypoint: "probe_noop",
  calldata: [toHex(n), ...Array.from({ length: n }, (_, i) => toHex(i + 1))],
});

/** Calldata lengths: empty, and the size of the heaviest transaction of a submission. */
const LENGTHS = [0, 1_000, 4_600];

async function main(): Promise<void> {
  const rpcUrl = arg("rpc", "http://127.0.0.1:5081/rpc");
  assertLocalRpc(rpcUrl);
  const router = arg("router");
  const accounts = all("account");
  if (!accounts.length) throw new Error("at least one --account");

  const rpc = new RpcClient(rpcUrl);
  const prices = await rpc.gasPrices();
  const bounds = simulationBounds(prices);
  const rows: Record<string, unknown>[] = [];

  for (const address of accounts) {
    const classHash = await rpc
      .request<string>("starknet_getClassHashAt", ["latest", address])
      .catch(() => "unknown");
    const nonce = await rpc.nonce(address);
    const gas: number[] = [];
    for (const n of LENGTHS) {
      const [entry] = await rpc.estimateFee([
        invokeV3(address, [probe(router, n)], nonce, bounds),
      ]);
      gas.push(Number(feeEstimateOf(entry).l2GasConsumed));
    }
    const envelope = gas[0]!;
    const slope = (gas[gas.length - 1]! - envelope) / LENGTHS[LENGTHS.length - 1]!;
    rows.push({
      address,
      class_hash: classHash,
      l2_gas: Object.fromEntries(LENGTHS.map((n, i) => [n, gas[i]])),
      empty_envelope_l2_gas: envelope,
      l2_gas_per_calldata_felt: slope,
      worst_tx_calldata_cost: slope * 4_627,
    });
    console.log(
      `${address.slice(0, 12)}…  class ${classHash.slice(0, 12)}…  ` +
        `envelope ${envelope.toLocaleString("en-US")}  ` +
        `slope ${slope.toFixed(1)} gas/felt  ` +
        `worst tx (4 627 felts) ${(slope * 4_627).toLocaleString("en-US", {
          maximumFractionDigits: 0,
        })}`,
    );
  }

  if (rows.length > 1) {
    const base = rows[0] as { l2_gas_per_calldata_felt: number };
    for (const r of rows.slice(1)) {
      const other = r as { l2_gas_per_calldata_felt: number; address: string };
      const delta =
        (100 * (other.l2_gas_per_calldata_felt - base.l2_gas_per_calldata_felt)) /
        base.l2_gas_per_calldata_felt;
      console.log(
        `  ${other.address.slice(0, 12)}… carries calldata ${delta.toFixed(1)} % ` +
          `${delta >= 0 ? "more" : "less"} expensively than the first account`,
      );
    }
  }

  const out = argv.indexOf("--out");
  if (out >= 0 && argv[out + 1]) {
    writeFileSync(
      argv[out + 1]!,
      JSON.stringify(
        {
          timestamp_utc: new Date().toISOString(),
          rpc: rpcUrl,
          router,
          starknet_version: prices.starknetVersion,
          lengths: LENGTHS,
          accounts: rows,
        },
        null,
        1,
      ),
    );
    console.log(`-> ${argv[out + 1]}`);
  }
}

main().catch((e: Error) => {
  console.error(e.message);
  process.exit(1);
});

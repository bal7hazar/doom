/**
 * S5 step 3 — read-only Sepolia sanity check.
 *
 * Estimates (never sends) the `stage_proof` transaction against the LIVE
 * modeofO registry on Sepolia, from an arbitrary account address picked out
 * of a recent block. Strictly read-only: `starknet_estimateFee` with
 * SKIP_VALIDATE, an empty signature, no key material, nothing broadcast.
 *
 * The point is to confirm that the L2 gas a public Sepolia node reports for
 * the staging transaction matches what the local devnet reported — i.e.
 * that devnet is a faithful pre-flight (docs/lane1-results.md claims it is).
 *
 * If the node refuses to estimate without a valid signature or a matching
 * nonce, that refusal is itself the result and is recorded.
 *
 * Usage:
 *   npx tsx sepolia_check.ts --calls results/calls.json \
 *     [--registry 0x0194f4...] [--sender 0x...] [--out results/sepolia_estimate.json]
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { num, transaction, type Call } from 'starknet';

/** modeofO's live lane-1 registry (docs/lane1-results.md). */
const MODEOFO_REGISTRY =
  '0x0194f44002b4af71e58ba7d30667ed565f1d420d3fb1e7c578de35170309c6aa';
const SEPOLIA_RPC = 'https://api.cartridge.gg/x/starknet/sepolia';

const argv = process.argv.slice(2);
function arg(name: string, dflt?: string): string {
  const i = argv.indexOf(`--${name}`);
  if (i >= 0 && i + 1 < argv.length) return argv[i + 1];
  if (dflt !== undefined) return dflt;
  throw new Error(`missing --${name}`);
}

async function rpc(url: string, method: string, params: unknown): Promise<any> {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    signal: AbortSignal.timeout(120_000),
  });
  const body = await res.json();
  if (body.error) throw Object.assign(new Error(JSON.stringify(body.error)), { rpc: body.error });
  return body.result;
}

/** An account address that actually exists on Sepolia: a recent v3 sender. */
async function anySender(url: string): Promise<string> {
  const block = await rpc(url, 'starknet_getBlockWithTxs', ['latest']);
  for (const tx of block.transactions) {
    if (tx.type === 'INVOKE' && tx.sender_address) return tx.sender_address;
  }
  throw new Error('no INVOKE transaction in the latest Sepolia block');
}

async function main() {
  const url = arg('rpc', SEPOLIA_RPC);
  const registry = arg('registry', MODEOFO_REGISTRY);
  const callsPath = arg('calls');
  const outPath = arg('out', '');

  if (!/sepolia/i.test(url)) throw new Error('this check is for Sepolia only');

  const doc = JSON.parse(readFileSync(callsPath, 'utf8'));
  // Default: the staging transaction only (the task's sanity check).
  // --sequence: all three, as one ordered array — still estimate-only.
  const wanted = argv.includes('--sequence')
    ? doc.calls
    : [doc.calls.find((c: any) => c.entrypoint === 'stage_proof')];
  const calls: Call[] = wanted.map((c: any) => ({
    contractAddress: registry,
    entrypoint: c.entrypoint,
    calldata: c.calldata,
  }));

  const sender = arg('sender', await anySender(url));
  const nonce = await rpc(url, 'starknet_getNonce', ['latest', sender]);
  const block = await rpc(url, 'starknet_getBlockWithTxHashes', ['latest']);
  console.log(`Sepolia ${url}`);
  console.log(`  registry ${registry}`);
  console.log(`  sender   ${sender} (nonce ${nonce}) — arbitrary, not ours, never signed`);
  console.log(
    `  block    ${block.block_number}, starknet ${block.starknet_version}, ` +
      `l2 ${(Number(BigInt(block.l2_gas_price.price_in_fri)) / 1e9).toFixed(3)} gFri`,
  );

  const txs = calls.map((call, i) => ({
    type: 'INVOKE',
    version: '0x3',
    sender_address: sender,
    calldata: transaction.getExecuteCalldata([call], '1').map((x) => num.toHex(x)),
    signature: [],
    nonce: '0x' + (BigInt(nonce) + BigInt(i)).toString(16),
    resource_bounds: {
      l1_gas: { max_amount: '0x186a0', max_price_per_unit: '0x2e90edd000' },
      l1_data_gas: { max_amount: '0xc350', max_price_per_unit: '0x2e90edd000' },
      l2_gas: { max_amount: '0x48214800', max_price_per_unit: '0x2e90edd000' },
    },
    tip: '0x0',
    paymaster_data: [],
    account_deployment_data: [],
    nonce_data_availability_mode: 'L1',
    fee_data_availability_mode: 'L1',
  }));

  let result: any = null;
  let error: any = null;
  try {
    // The array is applied in order, so phase 1 sees what staging wrote.
    const est = await rpc(url, 'starknet_estimateFee', [txs, ['SKIP_VALIDATE'], 'latest']);
    result = est.length === 1 ? est[0] : est;
    console.log('\n  estimate accepted:');
    est.forEach((e: any, i: number) => {
      console.log(
        `    ${wanted[i].entrypoint.padEnd(14)} l2_gas ${Number(
          e.l2_gas_consumed,
        ).toLocaleString().padStart(13)}   l1_data_gas ${Number(
          e.l1_data_gas_consumed,
        ).toLocaleString().padStart(7)}   fee ${(Number(e.overall_fee) / 1e18).toFixed(4)} STRK`,
      );
    });
    if (est.length > 1) {
      const tot = est.reduce((a: number, e: any) => a + Number(e.l2_gas_consumed), 0);
      const fee = est.reduce((a: number, e: any) => a + Number(e.overall_fee), 0);
      console.log(
        `    ${'TOTAL'.padEnd(14)} l2_gas ${tot.toLocaleString().padStart(13)}` +
          `                       fee ${(fee / 1e18).toFixed(4)} STRK`,
      );
    }
  } catch (e: any) {
    error = e.rpc ?? { message: e.message };
    console.log(`\n  estimate REFUSED: ${JSON.stringify(error).slice(0, 600)}`);
  }

  if (outPath) {
    writeFileSync(
      outPath,
      JSON.stringify(
        {
          timestamp_utc: new Date().toISOString(),
          network: 'starknet-sepolia (read-only, estimate only)',
          rpc: url,
          registry,
          sender,
          nonce,
          block: block.block_number,
          starknet_version: block.starknet_version,
          l2_gas_price_fri: block.l2_gas_price.price_in_fri,
          l1_data_gas_price_fri: block.l1_data_gas_price.price_in_fri,
          l1_gas_price_fri: block.l1_gas_price.price_in_fri,
          entrypoints: wanted.map((c: any) => c.entrypoint),
          calldata_felts: wanted.map((c: any) => c.calldata_felts),
          result,
          error,
        },
        null,
        1,
      ),
    );
    console.log(`\n-> ${outPath}`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

/**
 * S5 fee estimation for one Stwo fact (RISKS.md R7-A1 / R7-A2).
 *
 * The three transactions of a fact are *dependent*: `verify_phase1` reads
 * what `stage_proof` wrote, `verify_phase2` reads the checkpoint
 * `verify_phase1` wrote. A standalone estimate of either phase therefore
 * fails. Both `starknet_simulateTransactions` and `starknet_estimateFee`
 * take an ARRAY that is applied in order, which is the shape this script
 * uses — and the shape the client must use in Phase 4.
 *
 * The transactions are built as raw `INVOKE_TXN_V3` payloads and sent to
 * the RPC directly, because starknet.js's `Account.simulateTransaction`
 * returns only `resourceBounds` (already inflated by its own overhead) and
 * `overall_fee` — the raw `*_gas_consumed` fields we need for sizing are
 * dropped by its response parser. SKIP_VALIDATE is always set, so the
 * signature is not checked and none is produced: nothing here can be
 * broadcast. SKIP_FEE_CHARGE is added on retry if the sender cannot cover
 * the declared bounds.
 *
 * Output: per-transaction L2 gas / L1 data gas / fee, the total, then the
 * same gas amounts re-priced at (a) the node's own prices, (b) live
 * mainnet prices, (c) live Sepolia prices, (d) the 3 gFri protocol floor —
 * with a STRK/USD+EUR conversion and a timestamp. Finally it diffs the
 * estimate against the devnet receipts and prints recommended bounds.
 *
 * Usage:
 *   npx tsx estimate.ts --rpc http://127.0.0.1:5055/rpc \
 *     --account 0x... --registry 0x... --calls results/calls.json \
 *     [--receipts results/devnet_receipts.json] [--out results/estimates.json]
 *     [--no-live]
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { RpcProvider, num, transaction, type Call } from 'starknet';

// ---------------------------------------------------------------- constants

/** Empirical per-invoke L2 gas cap (sequencer rejection, docs/lane1-results.md). */
const INVOKE_L2_GAS_CAP = 1_210_000_000n;
/** RISKS.md R7-A5: no transaction provisioned above this share of the cap. */
const CAP_SAFETY = 0.9;
/** R7-A1 margins. Never a single global x1.5 — it overshoots the cap. */
const MARGIN_L2 = 1.15;
const MARGIN_L1_DATA = 1.3;
/** Protocol floor on the L2 gas price since Starknet v0.14.0. */
const L2_GAS_PRICE_FLOOR_FRI = 3_000_000_000n;

const PUBLIC_RPC: Record<string, string> = {
  mainnet: 'https://api.cartridge.gg/x/starknet/mainnet',
  sepolia: 'https://api.cartridge.gg/x/starknet/sepolia',
};
const PRICE_API =
  'https://api.coingecko.com/api/v3/simple/price?ids=starknet&vs_currencies=usd,eur';

/**
 * Amounts declared on the simulated transactions. `starknet_estimateFee`
 * ignores them; `starknet_simulateTransactions` without SKIP_FEE_CHARGE
 * checks them against the block's prices and the sender's balance, so the
 * max prices are derived from the live block (see `simBounds`).
 */
const SIM_AMOUNTS = { l1_gas: 100_000n, l1_data_gas: 50_000n, l2_gas: INVOKE_L2_GAS_CAP };
/** Headroom over the block's own prices, so a price tick mid-run is tolerated. */
const SIM_PRICE_FACTOR = 2n;

// ------------------------------------------------------------------- types

type Prices = {
  label: string;
  l1_gas_price_fri: bigint;
  l1_data_gas_price_fri: bigint;
  l2_gas_price_fri: bigint;
  source?: string;
};

type TxCost = {
  label: string;
  calldata_felts: number;
  l1_gas: bigint;
  l2_gas: bigint;
  l1_data_gas: bigint;
  fee_fri: bigint;
};

// ------------------------------------------------------------------- utils

const argv = process.argv.slice(2);
function arg(name: string, dflt?: string): string {
  const i = argv.indexOf(`--${name}`);
  if (i >= 0 && i + 1 < argv.length) return argv[i + 1];
  if (dflt !== undefined) return dflt;
  throw new Error(`missing --${name}`);
}
const flag = (name: string) => argv.includes(`--${name}`);

const big = (x: unknown): bigint =>
  typeof x === 'bigint' ? x : typeof x === 'number' ? BigInt(x) : BigInt((x as string) ?? 0);
const strk = (fri: bigint) => Number(fri) / 1e18;
const fmt = (n: bigint | number) => n.toLocaleString('en-US');
const gFri = (fri: bigint) => (Number(fri) / 1e9).toFixed(3);

async function rpc(url: string, method: string, params: unknown): Promise<any> {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    signal: AbortSignal.timeout(180_000),
  });
  const body = await res.json();
  if (body.error) throw new Error(`${method}: ${JSON.stringify(body.error).slice(0, 400)}`);
  return body.result;
}

const hex = (x: bigint) => '0x' + x.toString(16);

function simBounds(p: Prices) {
  const bound = (amount: bigint, price: bigint) => ({
    max_amount: hex(amount),
    max_price_per_unit: hex(price * SIM_PRICE_FACTOR),
  });
  return {
    l1_gas: bound(SIM_AMOUNTS.l1_gas, p.l1_gas_price_fri),
    l1_data_gas: bound(SIM_AMOUNTS.l1_data_gas, p.l1_data_gas_price_fri),
    l2_gas: bound(SIM_AMOUNTS.l2_gas, p.l2_gas_price_fri),
  };
}

/** An unsigned INVOKE_TXN_V3 — only ever valid under SKIP_VALIDATE. */
function invokeV3(sender: string, calls: Call[], nonce: bigint, bounds: object) {
  return {
    type: 'INVOKE',
    version: '0x3',
    sender_address: sender,
    // getExecuteCalldata yields decimal strings; the RPC wants 0x-prefixed felts.
    calldata: transaction.getExecuteCalldata(calls, '1').map((x) => num.toHex(x)),
    signature: [],
    nonce: hex(nonce),
    resource_bounds: bounds,
    tip: '0x0',
    paymaster_data: [],
    account_deployment_data: [],
    nonce_data_availability_mode: 'L1',
    fee_data_availability_mode: 'L1',
  };
}

function costOf(label: string, calldataFelts: number, e: any): TxCost {
  const src = e?.fee_estimation ?? e;
  return {
    label,
    calldata_felts: calldataFelts,
    l1_gas: big(src.l1_gas_consumed ?? 0),
    l2_gas: big(src.l2_gas_consumed ?? 0),
    l1_data_gas: big(src.l1_data_gas_consumed ?? 0),
    fee_fri: big(src.overall_fee ?? 0),
  };
}

async function pricesOf(label: string, url: string): Promise<Prices | null> {
  try {
    const b = await rpc(url, 'starknet_getBlockWithTxHashes', ['latest']);
    return {
      label,
      l1_gas_price_fri: big(b.l1_gas_price.price_in_fri),
      l1_data_gas_price_fri: big(b.l1_data_gas_price.price_in_fri),
      l2_gas_price_fri: big(b.l2_gas_price.price_in_fri),
      source: `block ${b.block_number}, starknet ${b.starknet_version}, ${new Date(
        b.timestamp * 1000,
      ).toISOString()}`,
    };
  } catch (e) {
    console.warn(`  ! ${label} prices unavailable: ${(e as Error).message}`);
    return null;
  }
}

async function strkPrice(): Promise<{ usd: number; eur: number; at: string } | null> {
  try {
    const res = await fetch(PRICE_API, { signal: AbortSignal.timeout(20_000) });
    const body = (await res.json()) as any;
    if (!body?.starknet?.usd) throw new Error(JSON.stringify(body).slice(0, 200));
    return { usd: body.starknet.usd, eur: body.starknet.eur, at: new Date().toISOString() };
  } catch (e) {
    console.warn(`  ! STRK price unavailable: ${(e as Error).message}`);
    return null;
  }
}

/** Re-price measured gas amounts under another network's gas prices. */
const reprice = (txs: TxCost[], p: Prices) =>
  txs.reduce(
    (a, t) =>
      a +
      t.l2_gas * p.l2_gas_price_fri +
      t.l1_gas * p.l1_gas_price_fri +
      t.l1_data_gas * p.l1_data_gas_price_fri,
    0n,
  );

// -------------------------------------------------------------------- main

async function main() {
  const rpcUrl = arg('rpc', 'http://127.0.0.1:5055/rpc');
  const sender = arg('account');
  const registry = arg('registry');
  const callsPath = arg('calls');
  const receiptsPath = arg('receipts', '');
  const outPath = arg('out', '');

  const doc = JSON.parse(readFileSync(callsPath, 'utf8'));
  const calls: Call[] = doc.calls.map((c: any) => ({
    contractAddress: registry,
    entrypoint: c.entrypoint,
    calldata: c.calldata,
  }));
  const labels: string[] = doc.calls.map((c: any) => c.label);
  const felts: number[] = doc.calls.map((c: any) => c.calldata_felts);

  const provider = new RpcProvider({ nodeUrl: rpcUrl });
  const specVersion = await provider.getSpecVersion();
  const nonce0 = big(await rpc(rpcUrl, 'starknet_getNonce', ['latest', sender]));
  const nodePrices = (await pricesOf('devnet (node)', rpcUrl))!;
  console.log(`RPC ${rpcUrl} (spec ${specVersion}) — sender ${sender}, nonce ${nonce0}\n`);

  // The array is applied in order: tx i sees the state left by tx i-1.
  const bounds0 = simBounds(nodePrices);
  const txs = calls.map((c, i) => invokeV3(sender, [c], nonce0 + BigInt(i), bounds0));

  // --- 1. simulate the SEQUENCE
  let simFlags = ['SKIP_VALIDATE'];
  let sim: any;
  try {
    sim = await rpc(rpcUrl, 'starknet_simulateTransactions', ['latest', txs, simFlags]);
  } catch (e) {
    console.warn(`  SKIP_VALIDATE alone failed (${(e as Error).message});`);
    console.warn('  retrying with SKIP_FEE_CHARGE');
    simFlags = ['SKIP_VALIDATE', 'SKIP_FEE_CHARGE'];
    sim = await rpc(rpcUrl, 'starknet_simulateTransactions', ['latest', txs, simFlags]);
  }
  const simulated = sim.map((e: any, i: number) => costOf(labels[i], felts[i], e));

  // --- 2. starknet_estimateFee over the same ordered array
  let estimated: TxCost[] = [];
  try {
    const est = await rpc(rpcUrl, 'starknet_estimateFee', [txs, ['SKIP_VALIDATE'], 'latest']);
    estimated = est.map((e: any, i: number) => costOf(labels[i], felts[i], e));
  } catch (e) {
    console.warn(`  ! starknet_estimateFee failed: ${(e as Error).message}`);
  }

  // --- 3. the table
  console.log(`starknet_simulateTransactions — sequence of ${txs.length}, [${simFlags}]`);
  console.log(
    '  tx             calldata        L2 gas   %cap    L1 data gas          fee (FRI)      STRK',
  );
  const line = (t: TxCost) =>
    console.log(
      `  ${t.label.padEnd(13)} ${String(t.calldata_felts).padStart(8)} ` +
        `${fmt(t.l2_gas).padStart(13)} ${((100 * Number(t.l2_gas)) / Number(INVOKE_L2_GAS_CAP))
          .toFixed(1)
          .padStart(6)} ${fmt(t.l1_data_gas).padStart(14)} ` +
        `${fmt(t.fee_fri).padStart(18)} ${strk(t.fee_fri).toFixed(4).padStart(9)}`,
    );
  simulated.forEach(line);
  const totL2 = simulated.reduce((a: bigint, t: TxCost) => a + t.l2_gas, 0n);
  const totData = simulated.reduce((a: bigint, t: TxCost) => a + t.l1_data_gas, 0n);
  const totFee = simulated.reduce((a: bigint, t: TxCost) => a + t.fee_fri, 0n);
  console.log(
    `  ${'TOTAL'.padEnd(13)} ${''.padStart(8)} ${fmt(totL2).padStart(13)} ${''.padStart(6)} ` +
      `${fmt(totData).padStart(14)} ${fmt(totFee).padStart(18)} ${strk(totFee)
        .toFixed(4)
        .padStart(9)}`,
  );

  if (estimated.length) {
    console.log('\nstarknet_estimateFee (same ordered array) — L2 gas / L1 data gas per tx');
    estimated.forEach((t) =>
      console.log(
        `  ${t.label.padEnd(13)} ${fmt(t.l2_gas).padStart(13)} ${fmt(t.l1_data_gas).padStart(14)}` +
          (t.l2_gas === simulated.find((s: TxCost) => s.label === t.label)!.l2_gas
            ? '   (identical to simulate)'
            : '   (DIFFERS from simulate)'),
      ),
    );
  }

  // --- 4. re-price at devnet / mainnet / Sepolia / floor
  const scenarios: Prices[] = [nodePrices];
  if (!flag('no-live')) {
    console.log('\nlive gas prices (read-only, latest block):');
    for (const [label, url] of Object.entries(PUBLIC_RPC)) {
      const p = await pricesOf(label, url);
      if (p) {
        scenarios.push(p);
        console.log(
          `  ${label.padEnd(8)} l2 ${gFri(p.l2_gas_price_fri).padStart(10)} gFri` +
            `   l1_data ${gFri(p.l1_data_gas_price_fri).padStart(10)} gFri` +
            `   l1 ${gFri(p.l1_gas_price_fri).padStart(12)} gFri   [${p.source}]`,
        );
      }
    }
  }
  scenarios.push({
    label: 'protocol floor',
    l1_gas_price_fri: nodePrices.l1_gas_price_fri,
    l1_data_gas_price_fri: nodePrices.l1_data_gas_price_fri,
    l2_gas_price_fri: L2_GAS_PRICE_FLOOR_FRI,
    source: 'Starknet v0.14.0 minimum L2 gas price (3 gFri), other prices as the node',
  });

  const px = flag('no-live') ? null : await strkPrice();
  console.log(
    `\ncost of one fact (3 tx, ${fmt(totL2)} L2 gas) re-priced` +
      (px ? `   [1 STRK = $${px.usd} / €${px.eur}, ${px.at}]` : ''),
  );
  const priced = scenarios.map((p) => {
    const fee = reprice(simulated, p);
    console.log(
      `  ${p.label.padEnd(16)} l2 ${gFri(p.l2_gas_price_fri).padStart(10)} gFri   ` +
        `${strk(fee).toFixed(4).padStart(10)} STRK` +
        (px
          ? `   $${(strk(fee) * px.usd).toFixed(2).padStart(8)}   €${(strk(fee) * px.eur)
              .toFixed(2)
              .padStart(8)}`
          : ''),
    );
    return {
      label: p.label,
      source: p.source,
      l2_gas_price_fri: p.l2_gas_price_fri.toString(),
      l1_data_gas_price_fri: p.l1_data_gas_price_fri.toString(),
      l1_gas_price_fri: p.l1_gas_price_fri.toString(),
      l2_price_over_floor: Number(p.l2_gas_price_fri) / Number(L2_GAS_PRICE_FLOOR_FRI),
      fee_fri: fee.toString(),
      fee_strk: strk(fee),
      fee_usd: px ? strk(fee) * px.usd : null,
      fee_eur: px ? strk(fee) * px.eur : null,
    };
  });

  // --- 5. estimate vs. the real devnet receipts
  let comparison: any[] = [];
  let worstGap: number | null = null;
  if (receiptsPath) {
    const rec = JSON.parse(readFileSync(receiptsPath, 'utf8'));
    console.log('\nestimate vs devnet receipt');
    console.log(
      '  tx               est L2 gas     actual L2 gas      gap    est data   act data   data gap',
    );
    comparison = simulated.map((t: TxCost) => {
      const a = rec.txs.find((r: any) => r.label === t.label);
      const gapL2 = (Number(t.l2_gas) - a.l2_gas) / a.l2_gas;
      const gapData = (Number(t.l1_data_gas) - a.l1_data_gas) / Math.max(a.l1_data_gas, 1);
      console.log(
        `  ${t.label.padEnd(13)} ${fmt(t.l2_gas).padStart(14)} ${fmt(a.l2_gas).padStart(17)} ` +
          `${(100 * gapL2).toFixed(2).padStart(7)}% ${fmt(t.l1_data_gas).padStart(11)} ` +
          `${fmt(a.l1_data_gas).padStart(10)} ${(100 * gapData).toFixed(2).padStart(9)}%`,
      );
      return {
        label: t.label,
        estimated_l2_gas: Number(t.l2_gas),
        actual_l2_gas: a.l2_gas,
        gap_l2_pct: 100 * gapL2,
        estimated_l1_data_gas: Number(t.l1_data_gas),
        actual_l1_data_gas: a.l1_data_gas,
        gap_l1_data_pct: 100 * gapData,
        estimated_fee_fri: t.fee_fri.toString(),
        actual_fee_fri: a.fee_fri,
        gap_fee_pct: (100 * (Number(t.fee_fri) - a.fee_fri)) / a.fee_fri,
      };
    });
    worstGap = Math.max(...comparison.map((c) => Math.abs(c.gap_l2_pct)));
    const totalGap =
      (100 * (Number(totL2) - comparison.reduce((a, c) => a + c.actual_l2_gas, 0))) /
      comparison.reduce((a, c) => a + c.actual_l2_gas, 0);
    console.log(
      `  worst |gap| on L2 gas: ${worstGap.toFixed(3)}%   total gap ${totalGap.toFixed(3)}%` +
        `   (C5 target: < 20%)`,
    );
  }

  // --- 6. recommended bounds
  console.log(`\nrecommended bounds (R7-A1: L2 x${MARGIN_L2}, L1 data x${MARGIN_L1_DATA})`);
  const bounds = simulated.map((t: TxCost) => {
    const l2 = BigInt(Math.ceil(Number(t.l2_gas) * MARGIN_L2));
    const data = BigInt(Math.ceil(Number(t.l1_data_gas) * MARGIN_L1_DATA));
    const naive15 = BigInt(Math.ceil(Number(t.l2_gas) * 1.5));
    const overCap = l2 > INVOKE_L2_GAS_CAP;
    const overSafety = Number(l2) > CAP_SAFETY * Number(INVOKE_L2_GAS_CAP);
    console.log(
      `  ${t.label.padEnd(13)} l2_gas ${fmt(l2).padStart(13)} (${(
        (100 * Number(l2)) /
        Number(INVOKE_L2_GAS_CAP)
      )
        .toFixed(1)
        .padStart(5)}% of cap${overCap ? ' — OVER CAP' : overSafety ? ' — over the 90% rule' : ''})` +
        `   l1_data_gas ${fmt(data).padStart(7)}` +
        `   [sncast x1.5 -> ${fmt(naive15)}${naive15 > INVOKE_L2_GAS_CAP ? ' REJECTED' : ''}]`,
    );
    return {
      label: t.label,
      l2_gas_bound: Number(l2),
      l1_data_gas_bound: Number(data),
      pct_of_invoke_cap: (100 * Number(l2)) / Number(INVOKE_L2_GAS_CAP),
      over_cap: overCap,
      over_90pct_rule: overSafety,
      naive_x15_l2_gas: Number(naive15),
      naive_x15_over_cap: naive15 > INVOKE_L2_GAS_CAP,
    };
  });

  if (outPath) {
    const pkg = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8'));
    writeFileSync(
      outPath,
      JSON.stringify(
        {
          timestamp_utc: new Date().toISOString(),
          rpc: rpcUrl,
          spec_version: specVersion,
          starknet_js: pkg.dependencies.starknet,
          sender,
          registry,
          simulation_flags: simFlags,
          simulated: simulated.map((t: TxCost) => ({
            label: t.label,
            calldata_felts: t.calldata_felts,
            l1_gas: t.l1_gas.toString(),
            l2_gas: t.l2_gas.toString(),
            l1_data_gas: t.l1_data_gas.toString(),
            fee_fri: t.fee_fri.toString(),
          })),
          estimate_fee: estimated.map((t) => ({
            label: t.label,
            l2_gas: t.l2_gas.toString(),
            l1_data_gas: t.l1_data_gas.toString(),
            fee_fri: t.fee_fri.toString(),
          })),
          total_l2_gas: totL2.toString(),
          total_l1_data_gas: totData.toString(),
          total_fee_fri: totFee.toString(),
          strk_price: px,
          priced,
          comparison,
          worst_gap_l2_pct: worstGap,
          bounds,
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

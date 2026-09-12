#!/usr/bin/env -S npx tsx
// SPDX-License-Identifier: Apache-2.0
/**
 * `submit-batch` — the submission orchestrator of `client/src/chain` driven from a terminal.
 *
 * Same code as the browser: the CLI only supplies a `Signer` backed by a devnet key, file-backed
 * stores and a text rendering of the cost screen. That is the point — D20 has the wrapper
 * submitting whole batches, and the wrapper is not a browser.
 *
 *   submit-batch --rpc http://127.0.0.1:5081/rpc --account <addr>:<key> \
 *       --batch <fixture dir | wrapper batch json> \
 *       --router 0x… --runs 0x… [--proof-id 1] [--replay] [--dry-run | --send]
 *
 * `--dry-run` (the default) stops after the cost screen: it simulates the whole ordered sequence
 * from the account that would sign, prints the per-transaction cost in STRK and fiat with the
 * bounds it would use, and sends nothing. `--send` plays the sequence, resuming wherever the
 * router's checkpoint says it stopped.
 *
 * **Devnet only.** The RPC host must be local; there is no flag that changes that.
 */

import { writeFileSync } from "node:fs";
import { join } from "node:path";

import {
  CachedPriceSource,
  CoinGeckoSource,
  StaticPriceSource,
  S5_SNAPSHOT,
  type FiatQuote,
  type PriceSource,
} from "../../../client/src/chain/prices.js";
import { GasPriceMedian } from "../../../client/src/chain/median.js";
import {
  feeEstimateOf,
  invokeV3,
  RpcClient,
  type Call,
  type ResourceBounds,
} from "../../../client/src/chain/rpc.js";
import {
  boundsFor,
  priceEstimate,
  simulateSequence,
  simulationBounds,
  withPrices,
  INVOKE_L2_GAS_CAP,
} from "../../../client/src/chain/estimate.js";
import {
  resumePoint,
  runSequence,
  type StepProgress,
} from "../../../client/src/chain/sequence.js";
import { prepareSubmission, preflight } from "../../../client/src/chain/submission.js";
import { checkBatch } from "../../../client/src/chain/batch.js";
import { submissionPolicies } from "../../../client/src/chain/signer.js";

import { DevnetSigner, assertLocalRpc } from "./devnetSigner.js";
import { addVersionCall, setGenesisCall } from "./version.js";
import { loadBatch } from "./fixture.js";
import { FileEchoStore, FileSampleStore } from "./stores.js";

const argv = process.argv.slice(2);
const flag = (name: string): boolean => argv.includes(`--${name}`);
function arg(name: string, dflt?: string): string {
  const i = argv.indexOf(`--${name}`);
  if (i >= 0 && i + 1 < argv.length) return argv[i + 1]!;
  if (dflt !== undefined) return dflt;
  throw new Error(`missing --${name}`);
}

const fmt = (n: bigint | number): string => n.toLocaleString("en-US");
const pad = (s: string, n: number) => s.padEnd(n);
const rpad = (s: string, n: number) => s.padStart(n);

function usage(): never {
  console.log(
    `submit-batch — P4.3 on-chain submission (devnet only)

  --rpc <url>            local devnet RPC (default http://127.0.0.1:5081/rpc)
  --account <addr>:<key> devnet account; ':key' may be omitted for --dry-run
  --batch <path>         fixture directory or saved 'GET /v1/batches/{id}' JSON
  --router <addr>        StwoCircuitRouter (P4.0)
  --runs <addr>          DoomRuns (P4.2)
  --proof-id <n>         router proof id (default 1); a fresh id restarts a sequence
  --version-id <n>       DoomRuns version table entry (default: the batch's)
  --player <addr>        address recorded for every game (default: the signer)
  --fri-split a,b        FRI cut; default '1,3' = 6 transactions (see --fewest-tx)
  --fewest-tx            prefer the 5-transaction plan: 0.3 % cheaper, but its fri1 bound is
                         over the invoke cap, so it can only be sent with no margin at all
  --replay               publish the packed input logs (R10-A3), +24 % consumer gas
  --single <run_id>      register_member for one run instead of submit_batch for the batch
  --no-live-price        skip the fiat quote (uses the S5 snapshot, shown as such)
  --work <dir>           state directory: echoes, gas samples, receipts (default .work)
  --out <file>           write the estimate + receipts as JSON
  --dry-run              cost screen only, send nothing (default)
  --send                 play the sequence, resuming where the checkpoint says it stopped
  --verifier-only        stop after the fact is registered (skip DoomRuns)
  --yes                  with --send: do not ask, even when the price looks high`,
  );
  process.exit(0);
}

function renderCostScreen(
  priced: ReturnType<typeof priceEstimate>,
  bounds: ReturnType<typeof withPrices>,
  verdict: ReturnType<GasPriceMedian["verdict"]>,
  sponsored: boolean,
): void {
  const q = priced.quote;
  console.log(
    `\n=== estimated cost — ${priced.steps.length} transactions ===` +
      `   [l2 ${(Number(priced.prices.l2GasPriceFri) / 1e9).toFixed(3)} gFri, ` +
      `block ${priced.prices.blockNumber}, starknet ${priced.prices.starknetVersion}]`,
  );
  console.log(
    `  ${pad("tx", 14)} ${rpad("calldata", 9)} ${rpad("L2 gas", 14)} ${rpad("%cap", 6)} ` +
      `${rpad("L1 data", 8)} ${rpad("STRK", 10)} ${rpad("bound L2", 14)} ${rpad("%cap", 6)}`,
  );
  priced.steps.forEach((s, i) => {
    const b = bounds[i]!;
    console.log(
      `  ${pad(s.label, 14)} ${rpad("", 9)} ${rpad(fmt(s.l2Gas), 14)} ` +
        `${rpad(s.pctOfCap.toFixed(1), 6)} ${rpad(fmt(s.l1DataGas), 8)} ` +
        `${rpad(s.strk.toFixed(4), 10)} ${rpad(fmt(b.l2GasBound), 14)} ` +
        `${rpad(b.pctOfCap.toFixed(1), 6)}` +
        (b.overCap ? "  OVER CAP" : b.over90PctRule ? "  over the 90 % rule (R7-A5)" : ""),
    );
  });
  console.log(
    `  ${pad("TOTAL", 14)} ${rpad("", 9)} ${rpad("", 14)} ${rpad("", 6)} ${rpad("", 8)} ` +
      `${rpad(priced.totalStrk.toFixed(4), 10)}` +
      (q ? `   $${priced.totalUsd!.toFixed(3)}  €${priced.totalEur!.toFixed(3)}` : ""),
  );
  if (q) console.log(`  1 STRK = $${q.usd} / €${q.eur}   [${q.source}, read ${q.at}]`);
  console.log(`  at the 3 gFri protocol floor the same gas costs ${priced.floorStrk.toFixed(4)} STRK`);
  if (sponsored) {
    console.log("  a paymaster covers this submission (R7-A4) — the cost is shown, not charged");
  }

  switch (verdict.kind) {
    case "high":
      console.log(
        `\n  ! the L2 gas price is ${verdict.ratio.toFixed(2)}× the 24 h median ` +
          `(${(Number(verdict.medianFri) / 1e9).toFixed(3)} gFri over ${verdict.samples} samples).` +
          `\n    Waiting is a real option: the game is kept locally and can be submitted later (C6).`,
      );
      break;
    case "normal":
      console.log(
        `\n  the L2 gas price is ${verdict.ratio.toFixed(2)}× the 24 h median ` +
          `(${verdict.samples} samples) — nothing unusual.`,
      );
      break;
    default:
      console.log(`\n  price history: ${verdict.reason} — no spike warning is possible yet.`);
  }
}

async function main(): Promise<void> {
  if (flag("help") || flag("h") || argv.length === 0) usage();

  const rpcUrl = arg("rpc", "http://127.0.0.1:5081/rpc");
  assertLocalRpc(rpcUrl);
  const work = arg("work", join(process.cwd(), ".work"));
  const rpc = new RpcClient(rpcUrl);

  const [address, privateKey] = arg("account").split(":");
  if (!address) throw new Error("--account must be <address>[:<private key>]");
  const send = flag("send");
  if (send && !privateKey) throw new Error("--send needs --account <address>:<private key>");

  const batchPath = arg("batch");
  const loaded = loadBatch(batchPath);
  const router = arg("router");
  const doomRuns = arg("runs");
  const proofId = BigInt(arg("proof-id", "1"));
  const versionId = Number(arg("version-id", String(loaded.versionId)));
  const player = arg("player", address);

  const runIds = [...new Set(loaded.batch.placements.map((p) => p.runId))];
  const players = Object.fromEntries(runIds.map((r) => [r, player]));
  const single = flag("single") ? arg("single") : null;

  const common = {
    batch: loaded.batch,
    router,
    doomRuns,
    versionId,
    proofId,
    players,
    levelIds: loaded.levelIds,
    replay: flag("replay"),
    plan: {
      ...(flag("fri-split") ? { friSplit: arg("fri-split").split(",").map(Number) } : {}),
      preferFewestTransactions: flag("fewest-tx"),
    },
  };
  let prepared = prepareSubmission(common);
  if (single) {
    const member = prepared.members.find((m) => m.runId === single);
    if (!member) throw new Error(`--single ${single}: no such run in the batch`);
    prepared = prepareSubmission({ ...common, singleMember: member });
  }
  const members = prepared.members;

  console.log(
    `batch ${loaded.name} (${loaded.source}): ${loaded.batch.leaves.length} leaves, ` +
      `${prepared.members.length} members, proof ${prepared.phases.length} transactions ` +
      `(${prepared.payloadSlots} packed slots), consumer ${prepared.consumerCalldataFelts} felts`,
  );
  for (const p of prepared.phases) {
    console.log(
      `  ${pad(p.label, 8)} ${pad(p.entrypoint, 8)} calldata ${rpad(String(p.calldataFelts), 5)} felts` +
        `   ${JSON.stringify(p.meta)}`,
    );
  }

  const problems = checkBatch(loaded.batch, members, loaded.genesis);
  if (problems.length) {
    console.log("\nthe batch would be rejected on chain:");
    for (const p of problems) console.log(`  ! ${p}`);
    if (send) throw new Error("refusing to pay for a batch that cannot be accepted");
  }

  // Free queries: is the fact already registered, is a run already recorded (D18 / R10-A1)?
  const pre = await preflight(rpc, {
    router,
    doomRuns,
    versionId,
    batch: loaded.batch,
    members,
  }).catch((e: Error) => {
    console.log(`  (pre-flight views unavailable: ${e.message.slice(0, 120)})`);
    return null;
  });
  if (pre) {
    console.log(
      `\nfact ${pre.fact}  ${pre.factRegistered ? "ALREADY REGISTERED — the verifier transactions can be skipped" : "not registered yet"}`,
    );
    for (const m of pre.alreadyRegistered) {
      console.log(`  ! run ${m.runId} is already recorded; it will be skipped on chain (D18)`);
    }
  }

  const signer = privateKey ? new DevnetSigner(rpcUrl, address, privateKey) : null;
  const policies = submissionPolicies({ router, doomRuns });
  console.log(
    `\nsession policies (${policies.length}): ` +
      policies.map((p) => `${p.target.slice(0, 8)}…/${p.method}`).join(", "),
  );
  if (signer) console.log(`account class ${(await signer.classHash()) ?? "unknown"} (S5 §4.1: +19 % between classes)`);

  // --- one-off owner setup, when the drive asks for it --------------------
  if (flag("setup-version")) {
    if (!signer) throw new Error("--setup-version needs --account <address>:<private key>");
    const registryName = arg("registry-name", loaded.name.split("_").slice(1).join("_") || "doom");
    const calls = [
      addVersionCall({
        doomRuns,
        versionId,
        batch: loaded.batch,
        router,
        registryName,
        ...(flag("program-hash-function")
          ? { programHashFunction: arg("program-hash-function") }
          : {}),
      }),
    ];
    if (loaded.genesis === undefined) throw new Error("the batch carries no genesis to pin");
    for (const levelId of new Set(Object.values(loaded.levelIds))) {
      calls.push(setGenesisCall(doomRuns, versionId, levelId, loaded.genesis));
    }
    console.log(`\nowner setup: add_version(${versionId}, registry '${registryName}') + set_genesis`);
    for (const call of calls) {
      const bounds = await estimateBounds(rpc, address, call);
      const { transactionHash } = await signer.execute([call], { bounds });
      const rec = await rpc.waitForReceipt(transactionHash);
      console.log(
        `  ${pad(call.entrypoint, 14)} ${transactionHash}  ` +
          `l2_gas ${fmt(BigInt(rec.execution_resources?.l2_gas ?? 0))}`,
      );
    }
  }

  // --- resume ------------------------------------------------------------
  const echoStore = new FileEchoStore(join(work, `echoes_${loaded.name}.json`));
  const resume = await resumePoint(rpc, prepared.sequence, address, echoStore);
  if (resume.nextPhase > 0) {
    console.log(
      `\nresuming: the router's checkpoint for proof id ${proofId} is at tag ${resume.checkpoint.tag}; ` +
        `${resume.nextPhase} phase(s) already paid for, echo from ${resume.echoSource}`,
    );
  }

  // --- estimate ----------------------------------------------------------
  // A bound over the invoke cap is refused by the sequencer before execution, so an over-cap
  // bound is not a warning, it is a plan that cannot be sent: cut the FRI walk finer and
  // estimate again. Only possible before the first transaction — once a sequence has started,
  // its plan is pinned by the checkpoint (a differently-cut resume fails the state echo).
  const splits: (number[] | null)[] =
    flag("fri-split") || resume.nextPhase > 0 ? [null] : [null, [1, 2, 4], [1, 2, 3, 4]];
  let est!: Awaited<ReturnType<typeof simulateSequence>>;
  for (const [attempt, split] of splits.entries()) {
    if (split) {
      prepared = prepareSubmission({ ...common, plan: { friSplit: split } });
      console.log(
        `\nre-planning with FRI split [${split}] — ${prepared.phases.length} verifier ` +
          `transactions — and estimating again`,
      );
    }
    const t0 = Date.now();
    est = await simulateSequence(rpc, prepared.sequence, {
      sender: address,
      verifierOnly: flag("verifier-only"),
      fromPhase: resume.nextPhase,
      ...(resume.echo ? { echoes: fillEchoes(resume.nextPhase, resume.echo) } : {}),
      onPrefix: (done, total) => process.stderr.write(`\r  simulating ${done}/${total}…   `),
    });
    process.stderr.write("\r" + " ".repeat(40) + "\r");
    console.log(
      `simulated ${est.steps.length} transactions in ${((Date.now() - t0) / 1000).toFixed(1)} s ` +
        `[${est.simulationFlags.join(", ")}] from ${address}`,
    );
    const over = est.bounds.filter((b) => b.overCap);
    if (!over.length) break;
    console.log(
      `  ! ${over.map((b) => b.label).join(", ")}: the ×1.15 bound is over the ` +
        `${fmt(INVOKE_L2_GAS_CAP)} invoke cap` +
        (attempt + 1 < splits.length ? "" : " and no finer plan is left"),
    );
  }

  const source: PriceSource = flag("no-live-price")
    ? new StaticPriceSource(S5_SNAPSHOT, "S5 snapshot (--no-live-price)")
    : new CachedPriceSource(new CoinGeckoSource());
  let quote: FiatQuote | null = null;
  try {
    quote = await source.quote();
  } catch {
    quote = null;
  }

  const median = new GasPriceMedian(new FileSampleStore(join(work, "gas_samples.json")));
  median.record(est.prices.l2GasPriceFri, est.prices.timestamp);
  const verdict = median.verdict(est.prices.l2GasPriceFri);

  const priced = priceEstimate(est, quote);
  const bounds = withPrices(est.bounds, est.prices);
  renderCostScreen(priced, bounds, verdict, signer?.sponsored ?? false);

  const overCap = bounds.filter((b) => b.overCap);
  const overCapMessage =
    `${overCap.map((b) => b.label).join(", ")}: the ×1.15 bound is over the ` +
    `${fmt(INVOKE_L2_GAS_CAP)} invoke cap and no finer FRI cut helped — the sequencer refuses ` +
    `the bound itself, so this plan cannot be sent (S5 §6)`;
  if (overCap.length) console.log(`\n  ! ${overCapMessage}`);
  const over90 = bounds.filter((b) => b.over90PctRule);
  if (over90.length) {
    console.log(
      `  note: ${over90.map((b) => b.label).join(", ")} bound above 90 % of the cap (R7-A5). ` +
        `'--fri-split 1,2,4' keeps every bound under 90 % for +0.3 % total gas.`,
    );
  }

  const out: Record<string, unknown> = {
    timestamp_utc: new Date().toISOString(),
    rpc: rpcUrl,
    batch: loaded.name,
    router,
    doom_runs: doomRuns,
    proof_id: "0x" + proofId.toString(16),
    version_id: versionId,
    sender: address,
    account_class: signer ? await signer.classHash() : null,
    simulation_flags: est.simulationFlags,
    prices: {
      l2_gas_price_fri: est.prices.l2GasPriceFri.toString(),
      l1_data_gas_price_fri: est.prices.l1DataGasPriceFri.toString(),
      l1_gas_price_fri: est.prices.l1GasPriceFri.toString(),
      block_number: est.prices.blockNumber,
      starknet_version: est.prices.starknetVersion,
    },
    strk_price: quote,
    price_verdict: verdict,
    plan: prepared.phases.map((p) => ({
      label: p.label,
      entrypoint: p.entrypoint,
      calldata_felts: p.calldataFelts,
      payload_slots: p.payloadSlots,
      meta: p.meta,
    })),
    estimated: est.steps.map((s, i) => ({
      label: s.label,
      phase: s.phase,
      calldata_felts: s.calldataFelts,
      l2_gas: s.estimate.l2GasConsumed.toString(),
      l1_data_gas: s.estimate.l1DataGasConsumed.toString(),
      fee_fri: s.estimate.overallFee.toString(),
      pct_of_invoke_cap: s.pctOfCap,
      l2_gas_bound: bounds[i]!.l2GasBound.toString(),
      l1_data_gas_bound: bounds[i]!.l1DataGasBound.toString(),
      naive_x15_l2_gas: bounds[i]!.naiveX15L2Gas.toString(),
      naive_x15_over_cap: bounds[i]!.naiveX15OverCap,
    })),
    total_l2_gas: est.totalL2Gas.toString(),
    total_l1_data_gas: est.totalL1DataGas.toString(),
    total_fee_fri: est.totalFeeFri.toString(),
    total_strk: priced.totalStrk,
    total_usd: priced.totalUsd,
    ...(pre ? { preflight: { fact: pre.fact, fact_registered: pre.factRegistered } } : {}),
  };

  if (!send) {
    console.log(
      "\n--dry-run: nothing was signed and nothing was sent." +
        "\n  submit now      : re-run with --send" +
        "\n  wait for a price: re-run later; the batch and its proof stay on disk" +
        "\n  keep offline    : do nothing — the game is kept locally (C6)",
    );
    writeOut(out);
    return;
  }
  if (overCap.length) throw new Error(overCapMessage);

  if (verdict.kind === "high" && !flag("yes")) {
    throw new Error(
      "the L2 gas price is more than twice the 24 h median (R7-A2). Re-run with --yes to " +
        "submit anyway, or wait — nothing is lost by waiting.",
    );
  }

  // --- send --------------------------------------------------------------
  const receipts: StepProgress[] = [];
  const result = await runSequence(rpc, prepared.sequence, {
    signer: signer!,
    bounds: padBounds(bounds.map((b) => b.bounds), resume.nextPhase, est.steps.length),
    store: echoStore,
    verifierOnly: flag("verifier-only"),
    onProgress: (p) => {
      receipts.push(p);
      if (p.state === "skipped") console.log(`  ${pad(p.label, 14)} already on chain, skipped`);
      if (p.state === "sending") process.stderr.write(`  ${pad(p.label, 14)} sending…`);
      if (p.state === "accepted") {
        process.stderr.write("\r");
        console.log(
          `  ${pad(p.label, 14)} ${p.transactionHash}  l2_gas ${rpad(fmt(p.l2Gas!), 13)}  ` +
            `fee ${(Number(p.feeFri!) / 1e18).toFixed(4)} STRK`,
        );
      }
    },
  });

  const accepted = receipts.filter((r) => r.state === "accepted");
  const comparison = accepted.map((r) => {
    const e = est.steps.find((s) => s.label === r.label);
    const actual = Number(r.l2Gas ?? 0n);
    return {
      label: r.label,
      transaction_hash: r.transactionHash,
      estimated_l2_gas: e ? Number(e.estimate.l2GasConsumed) : null,
      actual_l2_gas: actual,
      gap_l2_pct: e && actual ? (100 * (Number(e.estimate.l2GasConsumed) - actual)) / actual : null,
      estimated_l1_data_gas: e ? Number(e.estimate.l1DataGasConsumed) : null,
      actual_l1_data_gas: Number(r.l1DataGas ?? 0n),
      estimated_fee_fri: e ? e.estimate.overallFee.toString() : null,
      actual_fee_fri: (r.feeFri ?? 0n).toString(),
      pct_of_invoke_cap: (100 * actual) / Number(INVOKE_L2_GAS_CAP),
    };
  });

  console.log("\nestimate vs receipt (C5 target: < 20 %)");
  console.log(`  ${pad("tx", 14)} ${rpad("estimated", 14)} ${rpad("actual", 14)} ${rpad("gap", 9)}`);
  for (const c of comparison) {
    console.log(
      `  ${pad(c.label, 14)} ${rpad(fmt(c.estimated_l2_gas ?? 0), 14)} ` +
        `${rpad(fmt(c.actual_l2_gas), 14)} ${rpad((c.gap_l2_pct ?? 0).toFixed(3) + " %", 9)}`,
    );
  }
  const totalActual = comparison.reduce((a, c) => a + c.actual_l2_gas, 0);
  const totalEst = comparison.reduce((a, c) => a + (c.estimated_l2_gas ?? 0), 0);
  const totalGap = totalActual ? (100 * (totalEst - totalActual)) / totalActual : 0;
  const totalFee = accepted.reduce((a, r) => a + (r.feeFri ?? 0n), 0n);
  console.log(
    `  ${pad("TOTAL", 14)} ${rpad(fmt(totalEst), 14)} ${rpad(fmt(totalActual), 14)} ` +
      `${rpad(totalGap.toFixed(3) + " %", 9)}   ${(Number(totalFee) / 1e18).toFixed(4)} STRK paid`,
  );
  if (result.fact) console.log(`\nfact registered: ${result.fact}`);

  out.receipts = comparison;
  out.resumed_at = result.resumedAt;
  out.fact = result.fact ?? null;
  out.total_actual_l2_gas = totalActual;
  out.total_actual_fee_fri = totalFee.toString();
  out.total_gap_l2_pct = totalGap;
  writeOut(out);
}

/**
 * R7-A1 bounds for a standalone call (the owner setup): simulate it from the signing account,
 * then the same ×1.15 / ×1.30 margins. Not a shortcut for the sequence — the sequence must be
 * estimated as an ordered array, which is what `simulateSequence` does.
 */
async function estimateBounds(rpc: RpcClient, sender: string, call: Call): Promise<ResourceBounds> {
  const prices = await rpc.gasPrices();
  const nonce = await rpc.nonce(sender);
  const tx = invokeV3(sender, [call], nonce, simulationBounds(prices));
  const [entry] = await rpc.estimateFee([tx]);
  const estimate = feeEstimateOf(entry);
  const step = {
    index: 0,
    label: call.entrypoint,
    phase: "consumer" as const,
    calldataFelts: call.calldata.length,
    estimate,
    pctOfCap: 0,
  };
  return withPrices([boundsFor(step, prices)], prices)[0]!.bounds;
}

/** Echoes array with the resumed echo at its phase slot (the estimator fills in the rest). */
function fillEchoes(nextPhase: number, echo: string[]): (string[] | null)[] {
  const echoes: (string[] | null)[] = [];
  for (let i = 0; i < nextPhase; i++) echoes.push(null);
  echoes.push(echo);
  return echoes;
}

/** Bounds are indexed by sequence step; a resumed run's estimate starts at `from`. */
function padBounds<T>(bounds: T[], from: number, _total: number): T[] {
  return [...new Array<T>(from).fill(bounds[0]!), ...bounds];
}

function writeOut(out: Record<string, unknown>): void {
  if (!flag("out")) return;
  const path = arg("out");
  writeFileSync(path, JSON.stringify(out, null, 1));
  console.log(`\n-> ${path}`);
}

main().catch((e: Error) => {
  console.error(`\n${process.env["SUBMIT_DEBUG"] ? (e.stack ?? e.message) : e.message}`);
  process.exit(1);
});

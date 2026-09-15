#!/usr/bin/env -S npx tsx
// SPDX-License-Identifier: Apache-2.0
/**
 * `prover-node` — the open prover of D35, from a terminal.
 *
 *   prover-node run --rpc <url> --doom-runs <addr> --router <addr> --wrapper <url> [--once | --watch]
 *   prover-node status [--work .work]
 *
 * `run` polls `DoomRuns` for open commitments, and for each one it selects: reconstructs the
 * journal, executes and cuts it, proves the segments, folds them through the wrapper and
 * registers the run for the bounty. Every stage is persisted under `--work`, so a relaunch
 * resumes where it stopped. The signer's key comes from the environment only
 * (`PROVER_NODE_ADDRESS`, `PROVER_NODE_PRIVATE_KEY`) and is never printed.
 */
import { join, resolve } from "node:path";

import { RpcClient } from "../../../client/src/chain/rpc.js";
import { WrapperClient } from "../../../prover/wrapper/client-ts/src/index.js";
import { FileEchoStore } from "../../submit/src/stores.js";
import { FileDiscoveryStore } from "./discovery.js";
import { FakeExecutor, type Executor } from "./executor.js";
import { Logbook } from "./log.js";
import { MetricsFile } from "./metrics.js";
import { describeJob, ProverNode, type NodeConfig } from "./node.js";
import { assertNotMainnet, NodeSigner } from "./nodeSigner.js";
import { DEFAULT_POLICY, type SelectionPolicy } from "./policy.js";
import { FakeProver, SubprocessProver, type Prover } from "./prover.js";
import { StarknetRpcEventSource } from "./rpcSource.js";
import { ScarbExecutor } from "./scarbExecutor.js";
import { FileJobStore } from "./store.js";

const REPO = resolve(import.meta.dirname, "../../..");
const argv = process.argv.slice(2);
const command = argv[0] && !argv[0].startsWith("--") ? argv[0] : "";
const rest = command ? argv.slice(1) : argv;
const flag = (name: string): boolean => rest.includes(`--${name}`);
function arg(name: string, dflt?: string): string {
  const i = rest.indexOf(`--${name}`);
  if (i >= 0 && i + 1 < rest.length) return rest[i + 1]!;
  if (dflt !== undefined) return dflt;
  throw new Error(`missing --${name}`);
}
function args(name: string): string[] {
  const out: string[] = [];
  rest.forEach((a, i) => {
    if (a === `--${name}` && rest[i + 1]) out.push(rest[i + 1]!);
  });
  return out;
}

function usage(): never {
  console.log(`prover-node — the open prover of D35 (devnet / Sepolia)

  prover-node run    poll DoomRuns and prove what the policy selects
  prover-node status what the work directory holds, and the metrics

run:
  --rpc <url>              Starknet JSON-RPC (devnet or Sepolia; mainnet is refused)
  --doom-runs <addr>       DoomRuns with the D35 commitment extension
  --router <addr>          StwoCircuitRouter (optimized P4.1 classes, D28)
  --wrapper <url>          wrapper service base URL       --wrapper-key <token>
  --work <dir>             state: jobs, proofs, echoes, metrics, logbook (default .work)
  --start-block <n>        first block to scan (default 0)   --reorg-depth <n> (default 10)
  --once | --watch         one poll, or poll forever every --interval-ms (default 15000)

policy:
  --min-bounty <strk>      floor, in STRK (default 0)     --versions 1,2   --max-tics <n>
  --allow-player <addr>    (repeatable)  --deny-player <addr> (repeatable)  --max-queue <n>

execution and proof:
  --executor scarb|fake    scarb execute on doom_run (default scarb); fake is a toy game
  --manifest <Scarb.toml>  (default cairo/Scarb.toml)      --scarb <bin>
  --prover stwo|fake       stwo-run-and-prove (default stwo); fake never yields a valid proof
  --stwo-bin <path>        (default $PROVING/target/release/stwo-run-and-prove)
  --bootloader <path>      leaf simple bootloader (default under $PROVING)
  --params <path>          (default prover/wasm/harness/params/leaf.json)
  --executable <path>      (default cairo/target/proving/run_segment.executable.json)
  --lock-dir <dir>         shared proof lock (default $SCRATCH/.proof-lock)
  --proof-timeout <s>      per segment (default 600)     --proof-format bincode|cairo-serde
  --threads <n>            RAYON_NUM_THREADS (default 2)
  --max-steps <n>          D26 step ceiling (default 2300000 mono / 1500000 threaded)
  --log-size <n>           leaf registry row limit, log2 (default 20)
  --program-hash <felt>    every proof must carry it      --genesis <v>:<l>=<felt> (repeatable)

on chain:
  --stop-after cut|proved|folded   dry runs: no wrapper and/or no signer needed
  --no-replay              (ignored for multi-segment runs: their logs must be published)
  --max-attempts <n>       before a job is given up (default 5)
  PROVER_NODE_ADDRESS / PROVER_NODE_PRIVATE_KEY   the signer, from the environment only`);
  process.exit(0);
}

function policyFromArgs(): SelectionPolicy {
  const strk = arg("min-bounty", "0");
  const [whole, frac = ""] = strk.split(".");
  const minBounty = BigInt(whole || "0") * 10n ** 18n + BigInt((frac + "0".repeat(18)).slice(0, 18));
  return {
    ...DEFAULT_POLICY,
    minBounty,
    versions: flag("versions") ? arg("versions").split(",").map(Number) : [],
    ...(flag("max-tics") ? { maxTics: Number(arg("max-tics")) } : {}),
    ...(args("allow-player").length ? { allowPlayers: args("allow-player") } : {}),
    ...(args("deny-player").length ? { denyPlayers: args("deny-player") } : {}),
    maxQueue: Number(arg("max-queue", String(DEFAULT_POLICY.maxQueue))),
  };
}

function executorFromArgs(work: string): Executor {
  if (arg("executor", "scarb") === "fake") return new FakeExecutor();
  return new ScarbExecutor({
    manifest: arg("manifest", join(REPO, "cairo/Scarb.toml")),
    workDir: join(work, "execute"),
    ...(flag("scarb") ? { scarb: arg("scarb") } : {}),
  });
}

function proverFromArgs(): Prover {
  if (arg("prover", "stwo") === "fake") return new FakeProver();
  const scratch = process.env["SCRATCH"] ?? join(process.env["HOME"] ?? ".", ".hellproof/scratch");
  const proving = process.env["PROVING"] ?? join(scratch, "proving-s4");
  const format = arg("proof-format", "bincode");
  if (format !== "bincode" && format !== "cairo-serde") throw new Error("--proof-format is bincode or cairo-serde");
  return new SubprocessProver({
    bin: arg("stwo-bin", join(proving, "target/release/stwo-run-and-prove")),
    bootloader: arg("bootloader", join(proving, "crates/stwo_run_and_prove_recursive_tree/test_data/leaf_simple_bootloader_compiled.json")),
    params: arg("params", join(REPO, "prover/wasm/harness/params/leaf.json")),
    executable: arg("executable", join(REPO, "cairo/target/proving/run_segment.executable.json")),
    lockDir: arg("lock-dir", join(scratch, ".proof-lock")),
    proofFormat: format,
    timeoutMs: Number(arg("proof-timeout", "600")) * 1000,
    threads: Number(arg("threads", "2")),
  });
}

async function run(): Promise<void> {
  const work = resolve(arg("work", ".work"));
  const rpcUrl = arg("rpc");
  const rpc = new RpcClient(rpcUrl);
  const chainId = await assertNotMainnet(rpc);
  const stopAfter = flag("stop-after") ? arg("stop-after") : undefined;
  if (stopAfter && !["cut", "proved", "folded"].includes(stopAfter)) throw new Error("--stop-after is cut, proved or folded");
  const threads = Number(arg("threads", "2"));
  const maxSteps = flag("max-steps") ? Number(arg("max-steps")) : undefined;

  const config: NodeConfig = {
    doomRuns: arg("doom-runs"),
    router: arg("router", "0x0"),
    startBlock: Number(arg("start-block", "0")),
    reorgDepth: Number(arg("reorg-depth", "10")),
    policy: policyFromArgs(),
    planner: {
      ...(maxSteps !== undefined ? { maxStepsSingleThread: maxSteps, maxStepsThreaded: maxSteps } : {}),
      ...(flag("log-size") ? { maxComponentLogSize: Number(arg("log-size")) } : {}),
    },
    threads,
    proofTimeoutMs: Number(arg("proof-timeout", "600")) * 1000,
    ...(flag("program-hash") ? { programHash: arg("program-hash") } : {}),
    genesis: Object.fromEntries(args("genesis").map((g) => g.split("=") as [string, string])),
    ...(stopAfter ? { stopAfter: stopAfter as NodeConfig["stopAfter"] } : {}),
    replay: !flag("no-replay"),
    maxAttempts: Number(arg("max-attempts", "5")),
  };

  const needsWrapper = stopAfter !== "cut" && stopAfter !== "proved";
  const needsSigner = stopAfter === undefined;
  if (needsSigner && config.router === "0x0") throw new Error("--router is needed to register (or use --stop-after)");
  const wrapper = needsWrapper
    ? new WrapperClient({ baseUrl: arg("wrapper"), ...(flag("wrapper-key") ? { apiKey: arg("wrapper-key") } : {}) })
    : null;
  const signer = needsSigner ? NodeSigner.fromEnv(rpcUrl) : null;

  const log = new Logbook(join(work, "logbook.txt"));
  const node = new ProverNode(
    config,
    {
      source: new StarknetRpcEventSource(rpcUrl),
      executor: executorFromArgs(work),
      prover: proverFromArgs(),
      wrapper,
      rpc,
      signer,
      echoStore: new FileEchoStore(join(work, "echoes.json")),
    },
    {
      jobs: new FileJobStore(work),
      discovery: new FileDiscoveryStore(join(work, "discovery.json")),
      metrics: new MetricsFile(join(work, "metrics.json")),
      log,
    },
  );
  log.info(
    `prover-node on ${rpcUrl} (chain ${chainId}), DoomRuns ${config.doomRuns}, executor ${node.deps.executor.id}, ` +
      `prover ${node.deps.prover.id}, signer ${signer ? signer.address : "none"}, work ${work}` +
      (stopAfter ? `, stopping after ${stopAfter}` : ""),
  );
  if (node.deps.executor.id === "fake" || node.deps.prover.id === "fake") {
    log.warn("fake executor/prover in use: nothing produced here is a valid proof and the wrapper will reject it");
  }

  if (flag("watch")) {
    const abort = new AbortController();
    for (const sig of ["SIGINT", "SIGTERM"] as const) process.on(sig, () => abort.abort());
    await node.watch(Number(arg("interval-ms", "15000")), abort.signal);
    return;
  }
  const out = await node.pollOnce();
  console.log(`\n${out.processed.length} job(s) processed, ${out.selection.skipped.length} skipped, ${out.discovery.open.length} open`);
  for (const job of out.processed) console.log("  " + describeJob(job));
}

function status(): void {
  const work = resolve(arg("work", ".work"));
  const jobs = new FileJobStore(work).list();
  const metrics = new MetricsFile(join(work, "metrics.json")).data;
  if (flag("json")) {
    console.log(JSON.stringify({ metrics, jobs }, (_k, v: unknown) => (typeof v === "bigint" ? v.toString() : v), 1));
    return;
  }
  console.log(`work ${work}: ${jobs.length} job(s)`);
  for (const job of jobs) console.log("  " + describeJob(job));
  console.log(
    `\nsince ${metrics.startedAt}: ${metrics.polls} poll(s), ${metrics.commitmentsSeen} commitment event(s) seen, ` +
      `${metrics.selected} selected, ${metrics.skipped} skipped, ${metrics.registered} registered ` +
      `(${metrics.unsettled} unsettled), ${metrics.refused} refused, ${metrics.failed} failed, ${metrics.lostRace} lost race(s); ` +
      `${metrics.segmentsCut} segment(s) cut, ${metrics.segmentsProved} proved, ${metrics.proofFailures} proof failure(s); ` +
      `${(Number(BigInt(metrics.bountyClaimedFri)) / 1e18).toFixed(4)} STRK settled`,
  );
  for (const [stage, t] of Object.entries(metrics.stages)) {
    console.log(`  ${stage.padEnd(13)} ${String(t.count).padStart(4)} ×  mean ${(t.totalMs / t.count / 1000).toFixed(1)} s  max ${(t.maxMs / 1000).toFixed(1)} s`);
  }
}

async function main(): Promise<void> {
  if (flag("help") || flag("h") || argv.length === 0) usage();
  if (command === "status") return status();
  if (command === "run") return run();
  throw new Error(`unknown command '${command}' (run | status)`);
}

main().catch((e: Error) => {
  console.error(`\n${process.env["PROVER_NODE_DEBUG"] ? (e.stack ?? e.message) : e.message}`);
  process.exit(1);
});

// SPDX-License-Identifier: Apache-2.0
// Prove one real `run_segment` segment with the node's own stages, end to end, on a machine
// that has the proving binaries: `ScarbExecutor` builds the arguments and the ten public felts
// exactly as a poll would (genesis, then `run_segment`), `SubprocessProver` runs the real
// `stwo-run-and-prove` as a leaf-bootloader task under the shared lock and the process-group
// timeout, the preimage is checked against the execution the way `proveSegments` checks it,
// and the artifact is written in the wrapper's wire format (`bincode_b64` or
// `cairo_serde_felts`). With `--leaf-verify`, the independent verifier of
// `prover/wrapper/leaf-verify` is run on the proof as the wrapper would.
//
//   npx tsx scripts/prove-one.mjs --words <words.json | prove_segment.sh args.json> --tics 35 \
//       --out <dir> [--level 0] [--threads 1] [--timeout 900] [--proof-format bincode|cairo-serde] \
//       [--stwo-bin …] [--bootloader …] [--params …] [--executable …] [--lock-dir …] \
//       [--leaf-verify <hellproof-leaf-verify>] [--expect-task-hash <felt>]
//
// `--words` is either a JSON array of packed journal words or the `args.json` written by
// `cairo/doom/doom_run/bench/prove_segment.sh` ([len, state…, len, words…, tic_start, max_tics]):
// the words are taken from it and the arguments the node builds are checked to be identical.
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { feltEquals, feltValue, normalizeFelt } from "../../../client/src/prove/felt.ts";
import { SubprocessProver, spawnWithTimeout } from "../src/prover.ts";
import { ScarbExecutor, missingExecutables, probeScarb, scarbBinary } from "../src/scarbExecutor.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "../../..");
const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  if (i < 0) {
    if (fallback === undefined) throw new Error(`--${name} is required`);
    return fallback;
  }
  return argv[i + 1];
};

const scratch = process.env["SCRATCH"] ?? join(process.env["HOME"] ?? ".", ".hellproof/scratch");
const proving = process.env["PROVING"] ?? join(scratch, "proving-s4");
const out = resolve(arg("out"));
const tics = Number(arg("tics", "35"));
const levelId = Number(arg("level", "0")); // 0 = E1M1 (doom_run README)
const threads = Number(arg("threads", "1"));
const timeoutMs = Number(arg("timeout", "900")) * 1000;
const format = arg("proof-format", "bincode");
if (format !== "bincode" && format !== "cairo-serde") throw new Error("--proof-format is bincode or cairo-serde");
const manifest = arg("manifest", join(REPO, "cairo/Scarb.toml"));
const executable = arg("executable", join(REPO, "cairo/target/proving/run_segment.executable.json"));
const bootloader = arg("bootloader", join(proving, "crates/stwo_run_and_prove_recursive_tree/test_data/leaf_simple_bootloader_compiled.json"));
const options = {
  bin: arg("stwo-bin", join(proving, "target/release/stwo-run-and-prove")),
  bootloader,
  params: arg("params", join(REPO, "prover/wasm/harness/params/leaf.json")),
  executable,
  lockDir: arg("lock-dir", join(scratch, ".proof-lock")),
  proofFormat: format,
  timeoutMs,
  threads,
};
for (const [k, v] of Object.entries({ bin: options.bin, bootloader, params: options.params, executable })) {
  if (!existsSync(v)) throw new Error(`${k}: ${v} does not exist`);
}

// --- the words (and, when given the shell script's args.json, the arguments to reproduce)
const raw = JSON.parse(readFileSync(arg("words"), "utf8"));
let words;
let referenceArgs = null;
if (raw.length > 0 && typeof raw[0] === "string" && raw[0].startsWith("0x") && raw.length > 4) {
  const felts = raw.map((v) => feltValue(v));
  const stateLen = Number(felts[0]);
  const wordsLen = Number(felts[1 + stateLen]);
  words = felts.slice(2 + stateLen, 2 + stateLen + wordsLen).map(Number);
  const [ticStart, maxTics] = felts.slice(2 + stateLen + wordsLen).map(Number);
  if (ticStart !== 0 || maxTics !== tics) throw new Error(`args.json is a segment [${ticStart}, +${maxTics}) tics, --tics says ${tics}`);
  referenceArgs = raw.map((v) => normalizeFelt(String(v)));
} else {
  words = raw.map(Number);
}
if (words.length < tics) throw new Error(`${words.length} words for ${tics} tics`);
words = words.slice(0, tics);

// --- the node's stages: genesis, run_segment (arguments + the ten felts), then the proof
const scarb = probeScarb(scarbBinary(flag("scarb") ? arg("scarb") : undefined));
if (!scarb) throw new Error("no runnable scarb ($HELLPROOF_SCARB or --scarb)");
const missing = missingExecutables(manifest);
if (missing.length) throw new Error(`doom_run is not built for the proving profile (${missing.join(", ")})`);
mkdirSync(out, { recursive: true });
const executor = new ScarbExecutor({ manifest, workDir: join(out, "execute"), scarb: scarb.bin });
const genesis = await executor.genesis(levelId);
const segment = await executor.segment(genesis.state, words, 0, tics);
console.log(`run_segment: ${segment.nSteps} steps, ${segment.args.length} argument felts, h_in ${genesis.hash}`);
if (referenceArgs) {
  if (referenceArgs.length !== segment.args.length || referenceArgs.some((f, i) => !feltEquals(f, segment.args[i]))) {
    throw new Error("the node's arguments differ from the args.json of prove_segment.sh");
  }
  console.log("arguments identical to prove_segment.sh's args.json");
}

const prover = new SubprocessProver(options);
const t0 = performance.now();
const artifact = await prover.prove({ index: 0, args: segment.args, expectedOutput: segment.outputFelts, workDir: out }, { timeoutMs });
const proveMs = performance.now() - t0;

// The same admission `proveSegments` applies: the preimage is [task_hash, the ten felts].
if (artifact.outputPreimage.length !== 11) throw new Error(`preimage has ${artifact.outputPreimage.length} felts, expected 11`);
const got = artifact.outputPreimage.slice(1);
if (got.some((f, i) => !feltEquals(f, segment.outputFelts[i]))) {
  throw new Error("public output differs: the proof's preimage is not the executed ten felts");
}
const taskHash = normalizeFelt(artifact.programHash);
const expectTaskHash = flag("expect-task-hash") ? normalizeFelt(arg("expect-task-hash")) : null;
if (expectTaskHash && !feltEquals(taskHash, expectTaskHash)) throw new Error(`task hash ${taskHash}, expected ${expectTaskHash}`);

const executableSha256 = createHash("sha256").update(readFileSync(executable)).digest("hex");
const metrics = JSON.parse(readFileSync(join(out, "segment-0/proof_metrics.json"), "utf8"));
const summary = {
  tics,
  levelId,
  nSteps: segment.nSteps,
  executable,
  executableSha256,
  taskHash,
  outputFelts: segment.outputFelts,
  format: artifact.format,
  proofPath: artifact.proofPath,
  proofBytes: artifact.data ? Buffer.from(artifact.data, "base64").length : undefined,
  proofFelts: artifact.felts?.length,
  proveMs: Math.round(artifact.proveMs),
  wallMs: Math.round(proveMs),
  threads,
  metrics,
};

// --- the wrapper's independent gate, when the verifier is on hand
if (flag("leaf-verify")) {
  const verifier = resolve(arg("leaf-verify"));
  if (artifact.format !== "bincode_b64") throw new Error("leaf-verify reads the bincode form only (cairo-serde is one-way)");
  const r = await spawnWithTimeout(verifier, ["--proof", artifact.proofPath, "--expect-bootloader", bootloader], {
    timeoutMs: 120_000,
    logPath: join(out, "leaf-verify.log"),
  });
  const text = readFileSync(join(out, "leaf-verify.log"), "utf8");
  const report = JSON.parse(text.trim().split("\n").pop());
  summary.leafVerify = report;
  if (r.exitCode !== 0 || !report.ok) throw new Error(`leaf-verify rejected the proof: ${report.error ?? r.exitCode}`);
  const programOutput = JSON.parse(readFileSync(join(out, "segment-0/program_output.json"), "utf8")).map((v) => normalizeFelt(String(v)));
  if (report.output.length !== 2 || report.output.some((f, i) => !feltEquals(f, programOutput[i]))) {
    throw new Error("leaf-verify's two output cells differ from the bootloader's program_output.json");
  }
  console.log(`leaf-verify: ok in ${report.verify_ms.toFixed(1)} ms, bootloader ${report.program_hash}, trace_log_size ${report.trace_log_size}`);
}

writeFileSync(join(out, "proof-0.json"), JSON.stringify(artifact));
writeFileSync(join(out, "summary.json"), JSON.stringify(summary, null, 2));
console.log(JSON.stringify({ ...summary, metrics: undefined, outputFelts: undefined }, null, 2));
console.log(`artifact: ${join(out, "proof-0.json")} (${artifact.format})`);

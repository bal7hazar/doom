// End-to-end smoke test of the built package in Node >= 24 (Memory64 needs V8 >= 13.3).
//
//   cd prover/wasm/pkg && npm run build
//   node test/smoke.mjs [--threads 4] [--k 14] [--params ../harness/params/leaf.json]
//
// Uses ProverCore directly (Node has no DOM Worker for the prover wrapper itself; the rayon
// thread workers do run in `node:worker_threads`).
import fs from "node:fs";
import crypto from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ProverCore } from "../dist/core.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = (n, d) => {
  const i = argv.indexOf(`--${n}`);
  return i >= 0 ? argv[i + 1] : d;
};
const threads = Number(opt("threads", 1));
const size = opt("size", `k${opt("k", 14)}`);
const initialPages = Number(opt("initial-pages", 512));
const paramsFile = opt("params", null);
const params = paramsFile ? fs.readFileSync(paramsFile, "utf8") : undefined;

const executable = fs.readFileSync(
  path.join(here, "../../harness/programs/steps_k/target/dev/main.executable.json"),
  "utf8",
);
const args = JSON.parse(
  fs.readFileSync(path.join(here, `../../harness/programs/steps_k/args/${size}.json`), "utf8"),
);

const core = new ProverCore((e) => {
  if (e.type === "log" && (e.level === "error" || e.level === "warn")) console.error(`[${e.level}] ${e.message}`);
});

const info = await core.init({ threads, initialPages });
console.log(`init: ${JSON.stringify(info)}`);

const { input, stats, ms: execMs } = core.execute(executable, args);
console.log(`execute: ${execMs.toFixed(0)} ms, n_steps=${stats.n_steps}, input=${stats.prover_input_bytes} B`);

const res = core.resources(input, params);
console.log(
  `resources: n_steps=${res.n_steps} max_component=${res.max_component}(${res.max_component_rows} rows) ` +
    `log_max=${res.log_max_component_size} fits_leaf=${res.fits_leaf_registry}`,
);

const { proof, stats: pstats, ms: proveMs } = core.prove(input, params);
console.log(
  `prove: ${(proveMs / 1000).toFixed(2)} s, ${pstats.proof_bytes} B, ${pstats.proof_felts} felts, ` +
    `trace_log_size=${pstats.trace_log_size}, max_trace_component=${pstats.max_trace_component_log_size}, components=${pstats.component_log_sizes.length}`,
);

const ok = core.verify(proof, params);
const felts = core.proofToFelts(proof, params);
console.log(`verify: ${ok}; proofToFelts: ${felts.length} felts (first ${felts[0]})`);

if (!ok) process.exit(1);
if (felts.length !== pstats.proof_felts) {
  console.error(`felt count mismatch: ${felts.length} != ${pstats.proof_felts}`);
  process.exit(1);
}
console.log(
  JSON.stringify({
    threads: info.threads,
    size,
    initialPages,
    n_steps: stats.n_steps,
    prove_s: +(proveMs / 1000).toFixed(2),
    proof_felts: felts.length,
    proof_sha256: crypto.createHash("sha256").update(proof).digest("hex").slice(0, 16),
    trace_log_size: pstats.trace_log_size,
    max_trace_component_log_size: pstats.max_trace_component_log_size,
    resources_log_max: res.log_max_component_size,
    memory_gib: +(core.memoryBytes / 2 ** 30).toFixed(2),
  }),
);
core.terminate();
process.exit(0);

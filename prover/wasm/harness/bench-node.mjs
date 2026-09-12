// Node reference run of the same wasm64 module (no browser). Needs Node >= 24 (Memory64 with
// 64-bit table limits ships in V8 13.3; Node 22 rejects the module at compile time).
//   node --stack-size=8192 bench-node.mjs [--k 14] [--params file.json]
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ProverModule } from "./src/abi.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : d; };
const k = Number(opt("k", 14));
const params = opt("params", null) ? fs.readFileSync(opt("params"), "utf8") : "";

const wasm = fs.readFileSync(path.join(here, "public", "hellproof_prover_wasm.wasm"));
const executable = fs.readFileSync(path.join(here, "programs/steps_k/target/dev/main.executable.json"), "utf8");
const args = fs.readFileSync(path.join(here, `programs/steps_k/args/k${k}.json`), "utf8");

const t0 = performance.now();
const mod = await ProverModule.instantiate(wasm, {
  onLog: (level, msg) => { if (level !== "debug") console.error(`[wasm:${level}] ${msg}`); },
});
const instantiateMs = performance.now() - t0;

const ex = mod.call("execute", [executable, args]);
const pr = mod.call("prove", [ex.data, params]);
const ve = mod.call("verify", [pr.data, params]);
const fe = mod.call("proof_to_felts", [pr.data, params]);
const rss = process.memoryUsage().rss;
console.log(JSON.stringify({
  label: `k${k}`, target: "node-wasm64", node: process.version, k,
  instantiate_ms: instantiateMs,
  n_steps: ex.info.n_steps, execute_ms: ex.ms, prove_ms: pr.ms, verify_ms: ve.ms,
  proof_bytes: pr.info.proof_bytes, proof_felts: JSON.parse(new TextDecoder().decode(fe.data)).length,
  max_log_size: pr.info.max_log_size,
  trace_lifting_log_size: pr.info.trace_lifting_log_size,
  verify_ok: ve.info.ok === true,
  wasm_memory_bytes: mod.memoryBytes, process_rss_bytes: rss,
  prove_spans: pr.spans,
}));

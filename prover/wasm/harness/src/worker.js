// Web Worker: owns the wasm64 instance and runs execute -> prove -> verify -> proof_to_felts.
// Messages: { type: "init", wasmUrl } | { type: "run", id, executable, args, params }
// Replies:  { type: "ready" } | { type: "log", level, msg } | { type: "stage", ... }
//           | { type: "result", id, result } | { type: "error", id, message }
import { ProverModule } from "./abi.mjs";

let mod = null;

function post(msg) {
  self.postMessage(msg);
}

async function init(wasmUrl) {
  const t0 = performance.now();
  const resp = fetch(wasmUrl);
  mod = await ProverModule.instantiate(resp, {
    onLog: (level, msg) => post({ type: "log", level, msg }),
  });
  post({ type: "ready", instantiateMs: performance.now() - t0, memoryBytes: mod.memoryBytes });
}

function stage(name, fn) {
  const t0 = performance.now();
  const r = fn();
  const wall = performance.now() - t0;
  const out = {
    name,
    ms: r.ms,
    wallMs: wall,
    memoryBytes: r.memoryBytes,
    info: r.info,
    spans: r.spans,
  };
  post({ type: "stage", ...out });
  return { ...out, data: r.data };
}

function run(id, executable, args, params) {
  const stages = {};
  const ex = stage("execute", () => mod.call("execute", [executable, args]));
  stages.execute = { ms: ex.ms, memoryBytes: ex.memoryBytes, info: ex.info, spans: ex.spans };
  const pr = stage("prove", () => mod.call("prove", [ex.data, params]));
  stages.prove = { ms: pr.ms, memoryBytes: pr.memoryBytes, info: pr.info, spans: pr.spans };
  const ve = stage("verify", () => mod.call("verify", [pr.data, params]));
  stages.verify = { ms: ve.ms, memoryBytes: ve.memoryBytes, info: ve.info, spans: ve.spans };
  const fe = stage("proof_to_felts", () => mod.call("proof_to_felts", [pr.data, params]));
  stages.proof_to_felts = { ms: fe.ms, memoryBytes: fe.memoryBytes, info: fe.info };
  const feltsJson = new TextDecoder().decode(fe.data);
  const nFelts = JSON.parse(feltsJson).length;
  post({
    type: "result",
    id,
    result: {
      n_steps: ex.info.n_steps,
      builtins: ex.info.builtins,
      output: ex.info.output,
      prover_input_bytes: ex.info.prover_input_bytes,
      execute_ms: ex.ms,
      prove_ms: pr.ms,
      verify_ms: ve.ms,
      proof_bytes: pr.info.proof_bytes,
      proof_felts: nFelts,
      proof_felts_json_bytes: fe.data.byteLength,
      max_log_size: pr.info.max_log_size,
      trace_lifting_log_size: pr.info.trace_lifting_log_size,
      preprocessed_lifting_log_size: pr.info.preprocessed_lifting_log_size,
      verify_ok: ve.info.ok === true,
      wasm_memory_bytes: mod.memoryBytes,
      stages,
    },
  });
}

self.addEventListener("message", async (ev) => {
  const d = ev.data;
  try {
    if (d.type === "init") await init(d.wasmUrl);
    else if (d.type === "run") run(d.id, d.executable, d.args, d.params);
  } catch (e) {
    post({ type: "error", id: d.id, message: String(e?.message ?? e), memoryBytes: mod?.memoryBytes ?? 0 });
  }
});

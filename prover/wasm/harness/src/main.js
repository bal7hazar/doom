// Page controller. Exposes `window.hellproof.run({ k, params, fresh })` for the Playwright bench and
// a small manual UI. Each run may use a fresh Worker (fresh wasm instance = memory released).
import executableJson from "../programs/steps_k/target/dev/main.executable.json?raw";

const ARGS = import.meta.glob("../programs/steps_k/args/k*.json", { query: "?raw", import: "default", eager: true });
const WASM_URL = "/hellproof_prover_wasm.wasm";

const $ = (id) => document.getElementById(id);
const log = (msg, level = "info") => {
  const el = $("log");
  const line = document.createElement("div");
  line.className = `lvl-${level}`;
  line.textContent = `[${new Date().toISOString().slice(11, 23)}] ${msg}`;
  el.appendChild(line);
  el.scrollTop = el.scrollHeight;
  if (level === "error") console.error(msg);
};

let worker = null;
let workerReady = null;
let lastInit = null;

function newWorker() {
  worker?.terminate();
  worker = new Worker(new URL("./worker.js", import.meta.url), { type: "module" });
  workerReady = new Promise((resolve, reject) => {
    const onMsg = (ev) => {
      if (ev.data.type === "ready") {
        worker.removeEventListener("message", onMsg);
        lastInit = ev.data;
        resolve(ev.data);
      } else if (ev.data.type === "error") {
        worker.removeEventListener("message", onMsg);
        reject(new Error(ev.data.message));
      } else if (ev.data.type === "log") {
        log(`[wasm] ${ev.data.msg}`, ev.data.level);
      }
    };
    worker.addEventListener("message", onMsg);
    worker.addEventListener("error", (e) => log(`worker error: ${e.message}`, "error"));
    worker.postMessage({ type: "init", wasmUrl: WASM_URL });
  });
  return workerReady;
}

async function uaMemory() {
  try {
    if (!("measureUserAgentSpecificMemory" in performance)) return null;
    const m = await performance.measureUserAgentSpecificMemory();
    return m.bytes;
  } catch (e) {
    return null;
  }
}

let runId = 0;
async function run({ k = 14, params = "", fresh = true } = {}) {
  const argsKey = Object.keys(ARGS).find((p) => p.endsWith(`/k${k}.json`));
  if (!argsKey) throw new Error(`no args for k=${k}`);
  const args = ARGS[argsKey];
  if (fresh || !worker) await newWorker();
  else await workerReady;
  const id = ++runId;
  const memBefore = await uaMemory();
  const stageMem = {};
  const t0 = performance.now();
  const result = await new Promise((resolve, reject) => {
    const onMsg = async (ev) => {
      const d = ev.data;
      if (d.type === "log") {
        log(`[wasm] ${d.msg}`, d.level);
      } else if (d.type === "stage") {
        const ua = await uaMemory();
        stageMem[d.name] = { wasm_memory_bytes: d.memoryBytes, ua_memory_bytes: ua };
        log(`stage ${d.name}: ${d.ms.toFixed(0)} ms, wasm memory ${(d.memoryBytes / 2 ** 30).toFixed(2)} GiB` +
            (ua ? `, UA memory ${(ua / 2 ** 30).toFixed(2)} GiB` : ""));
      } else if (d.type === "result" && d.id === id) {
        worker.removeEventListener("message", onMsg);
        resolve(d.result);
      } else if (d.type === "error") {
        worker.removeEventListener("message", onMsg);
        reject(Object.assign(new Error(d.message), { memoryBytes: d.memoryBytes }));
      }
    };
    worker.addEventListener("message", onMsg);
    worker.postMessage({ type: "run", id, executable: executableJson, args, params });
  });
  const totalMs = performance.now() - t0;
  const memAfter = await uaMemory();
  const out = {
    k,
    label: `k${k}`,
    target: "chrome-wasm64",
    user_agent: navigator.userAgent,
    hardware_concurrency: navigator.hardwareConcurrency,
    device_memory_gib: navigator.deviceMemory ?? null,
    cross_origin_isolated: crossOriginIsolated,
    instantiate_ms: lastInit?.instantiateMs ?? null,
    total_ms: totalMs,
    ua_memory_before_bytes: memBefore,
    ua_memory_after_bytes: memAfter,
    ua_memory_peak_bytes: Math.max(...Object.values(stageMem).map((s) => s.ua_memory_bytes ?? 0), memAfter ?? 0) || null,
    stage_memory: stageMem,
    ...result,
  };
  log(`k=${k}: steps=${out.n_steps} execute=${out.execute_ms.toFixed(0)}ms prove=${out.prove_ms.toFixed(0)}ms ` +
      `verify=${out.verify_ms.toFixed(0)}ms proof=${out.proof_felts} felts (${(out.proof_bytes / 1e6).toFixed(2)} MB) ` +
      `wasm mem=${(out.wasm_memory_bytes / 2 ** 30).toFixed(2)} GiB ok=${out.verify_ok}`);
  renderRow(out);
  return out;
}

function renderRow(r) {
  const tb = $("rows");
  const tr = document.createElement("tr");
  const gib = (b) => (b == null ? "-" : (b / 2 ** 30).toFixed(2));
  tr.innerHTML = `<td>${r.k}</td><td>${r.n_steps}</td><td>${r.execute_ms.toFixed(0)}</td><td>${r.prove_ms.toFixed(0)}</td>` +
    `<td>${r.verify_ms.toFixed(0)}</td><td>${r.proof_felts}</td><td>${gib(r.wasm_memory_bytes)}</td><td>${gib(r.ua_memory_peak_bytes)}</td><td>${r.verify_ok}</td>`;
  tb.appendChild(tr);
}

window.hellproof = { run, newWorker, uaMemory, terminate: () => worker?.terminate() };

document.addEventListener("DOMContentLoaded", () => {
  $("env").textContent = `crossOriginIsolated=${crossOriginIsolated} cores=${navigator.hardwareConcurrency} ` +
    `deviceMemory=${navigator.deviceMemory ?? "?"} GiB  UA=${navigator.userAgent}`;
  $("run").addEventListener("click", async () => {
    const k = Number($("k").value);
    const params = $("params").value.trim();
    $("run").disabled = true;
    try {
      await run({ k, params, fresh: $("fresh").checked });
    } catch (e) {
      log(String(e.message ?? e), "error");
    } finally {
      $("run").disabled = false;
    }
  });
  const auto = new URLSearchParams(location.search).get("k");
  if (auto) run({ k: Number(auto) }).catch((e) => log(String(e.message ?? e), "error"));
});

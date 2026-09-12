// Harness page: drives `@hellproof/prover-wasm` (the package under ../../pkg) from the main
// thread and exposes `window.hellproof.run()` for the Playwright bench.
//
// Everything heavy happens inside the package's prover Worker; the page only collects timings,
// the wasm memory high-water mark and `performance.measureUserAgentSpecificMemory()`.
import { createProver } from "@hellproof/prover-wasm";

const $ = (id) => document.getElementById(id);
const log = (level, msg) => {
  const el = $("log");
  if (!el) return;
  const line = document.createElement("div");
  line.className = `lvl-${level}`;
  line.textContent = msg;
  el.appendChild(line);
  el.scrollTop = el.scrollHeight;
};

const ARGS = import.meta.glob("../programs/steps_k/args/*.json", { query: "?raw", import: "default", eager: true });
// `scarb build` output when present, else the committed copy (CI proves without Scarb installed).
const EXECUTABLE = import.meta.glob(
  ["../programs/steps_k/target/dev/main.executable.json", "../programs/steps_k/main.executable.json"],
  { query: "?raw", import: "default", eager: true },
);

function argsFor(size) {
  const key = Object.keys(ARGS).find((k) => k.endsWith(`/${size}.json`));
  if (!key) throw new Error(`no args file for size "${size}" (have: ${Object.keys(ARGS).join(", ")})`);
  return JSON.parse(ARGS[key]);
}

function executable() {
  const keys = Object.keys(EXECUTABLE).sort((a, b) => (b.includes("/target/") ? 1 : 0) - (a.includes("/target/") ? 1 : 0));
  if (!keys.length) throw new Error("no steps_k executable (scarb build in programs/steps_k)");
  return EXECUTABLE[keys[0]];
}

async function uaMemory() {
  try {
    if (!("measureUserAgentSpecificMemory" in performance)) return null;
    const m = await performance.measureUserAgentSpecificMemory();
    return m.bytes;
  } catch {
    return null;
  }
}

/**
 * One measurement: a fresh prover Worker (so the whole linear memory is released between runs and
 * every run pays V8's tier-up), then execute -> resources -> prove -> verify -> proof_to_felts.
 */
async function run({ size = "k14", params = "", threads = 1, felts = true, initialPages } = {}) {
  const spans = { execute: [], prove: [], verify: [], proof_to_felts: [], resources: [] };
  let peakMemory = 0;
  const prover = createProver({
    onEvent: (e) => {
      if (e.type === "span") spans[e.stage]?.push({ name: e.name, ms: e.ms });
      if (e.type === "log") log(e.level, e.message);
      if (e.memoryBytes) peakMemory = Math.max(peakMemory, e.memoryBytes);
    },
  });

  const t0 = performance.now();
  const info = await prover.init({ threads, ...(initialPages ? { initialPages } : {}) });
  log("info", `init: ${info.threads} thread(s), ${info.threaded ? "threaded" : "single-threaded"} artifact`);

  const exe = executable();
  const args = argsFor(size);
  const ex = await prover.execute(exe, args);
  const res = await prover.resources(ex.input, params);
  const pr = await prover.prove(ex.input, params);
  const t1 = performance.now();
  const verifyStart = performance.now();
  const ok = await prover.verify(pr.proof, params);
  const verifyMs = performance.now() - verifyStart;
  let nFelts = pr.stats.proof_felts;
  let feltsMs = null;
  if (felts) {
    const t = performance.now();
    nFelts = (await prover.proofToFelts(pr.proof, params)).length;
    feltsMs = performance.now() - t;
  }
  const uaBytes = await uaMemory();
  await prover.terminate();

  return {
    size,
    threads: info.threads,
    threaded: info.threaded,
    wasm_url: info.wasmUrl.split("/").pop(),
    instantiate_ms: info.instantiateMs,
    initial_pages: initialPages ?? null,
    n_steps: ex.stats.n_steps,
    builtins: ex.stats.builtins,
    execute_ms: ex.ms,
    prove_ms: pr.ms,
    verify_ms: verifyMs,
    proof_to_felts_ms: feltsMs,
    total_ms: t1 - t0,
    proof_bytes: pr.stats.proof_bytes,
    proof_felts: nFelts,
    trace_log_size: pr.stats.trace_log_size,
    max_trace_component_log_size: pr.stats.max_trace_component_log_size,
    max_log_size: pr.stats.max_log_size,
    trace_lifting_log_size: pr.stats.trace_lifting_log_size,
    preprocessed_lifting_log_size: pr.stats.preprocessed_lifting_log_size,
    resources: {
      n_steps: res.n_steps,
      max_component: res.max_component,
      max_component_rows: res.max_component_rows,
      log_max_component_size: res.log_max_component_size,
      fits_leaf_registry: res.fits_leaf_registry,
      memory_address_to_id: res.memory_address_to_id,
      memory_id_to_big: res.memory_id_to_big,
      verify_instruction: res.verify_instruction,
    },
    verify_ok: ok,
    wasm_memory_bytes: peakMemory,
    ua_memory_peak_bytes: uaBytes,
    spans,
  };
}

window.hellproof = { run };

// ---- interactive page ---------------------------------------------------------------------------
if ($("run")) {
  $("env").textContent =
    `crossOriginIsolated=${crossOriginIsolated} · hardwareConcurrency=${navigator.hardwareConcurrency}` +
    ` · deviceMemory=${navigator.deviceMemory ?? "?"}`;
  $("run").addEventListener("click", async () => {
    $("run").disabled = true;
    try {
      const r = await run({
        size: $("k").value,
        params: $("params").value.trim(),
        threads: Number($("threads").value),
      });
      const row = document.createElement("tr");
      row.innerHTML = [
        r.size,
        r.threads,
        r.n_steps,
        r.execute_ms.toFixed(0),
        r.prove_ms.toFixed(0),
        r.verify_ms.toFixed(0),
        r.proof_felts,
        (r.wasm_memory_bytes / 2 ** 30).toFixed(2),
        r.ua_memory_peak_bytes ? (r.ua_memory_peak_bytes / 2 ** 30).toFixed(2) : "-",
        r.verify_ok,
      ]
        .map((v) => `<td>${v}</td>`)
        .join("");
      $("rows").appendChild(row);
    } catch (e) {
      log("error", String(e?.message ?? e));
    } finally {
      $("run").disabled = false;
    }
  });
}

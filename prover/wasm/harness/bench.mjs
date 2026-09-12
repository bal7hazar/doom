// Playwright bench: starts the Vite dev server (COOP/COEP), launches headless Chrome/Chromium,
// runs execute -> prove -> verify for each k, `runs` times each with a fresh wasm instance, and
// writes results/bench-<stamp>.{json,md}.
//
//   node bench.mjs [--k 14,16,18,19] [--runs 3] [--channel chrome|chromium] [--params file.json]
//                  [--headed] [--ci] [--timeout-min 40] [--label name]
import { createServer } from "vite";
import { chromium } from "playwright";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = (name, def) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 ? argv[i + 1] : def;
};
const flag = (name) => argv.includes(`--${name}`);

const ks = String(opt("k", "14,16,18,19")).split(",").map(Number);
const runs = Number(opt("runs", 3));
const channel = opt("channel", "chrome"); // "chrome" = installed Google Chrome, "chromium" = Playwright's
const paramsFile = opt("params", null);
const params = paramsFile ? fs.readFileSync(paramsFile, "utf8") : "";
const timeoutMs = Number(opt("timeout-min", 40)) * 60_000;
const label = opt("label", "");
const ci = flag("ci");

const wasmPath = path.join(here, "public", "hellproof_prover_wasm.wasm");
if (!fs.existsSync(wasmPath)) {
  console.error(`missing ${wasmPath}: run ../build.sh first`);
  process.exit(2);
}
const wasmSha = fs.existsSync(path.join(here, "..", "SHA256SUMS"))
  ? fs.readFileSync(path.join(here, "..", "SHA256SUMS"), "utf8").trim()
  : "";

const server = await createServer({ root: here, configFile: path.join(here, "vite.config.js"), logLevel: "warn" });
await server.listen();
const url = server.resolvedUrls.local[0];
console.error(`vite: ${url}`);

const launchOpts = {
  headless: !flag("headed"),
  args: [
    // Memory64 is on by default since Chrome 133; keep the flag explicit for older builds.
    "--enable-features=WebAssemblyMemory64",
    // Let the renderer use more than the default per-process cap; not needed on 64-bit macOS
    // but harmless.
    "--js-flags=--max-old-space-size=4096",
  ],
};
if (channel !== "chromium") launchOpts.channel = channel;
const browser = await chromium.launch(launchOpts);
const version = browser.version();
console.error(`browser: ${channel} ${version}`);

const results = [];
const errors = [];
try {
  for (const k of ks) {
    for (let run = 1; run <= runs; run++) {
      const context = await browser.newContext();
      const page = await context.newPage();
      const logs = [];
      page.on("console", (m) => {
        const t = m.text();
        logs.push(t);
        if (m.type() === "error") console.error(`[page] ${t}`);
      });
      page.on("pageerror", (e) => console.error(`[pageerror] ${e.message}`));
      await page.goto(url, { waitUntil: "load" });
      const isolated = await page.evaluate(() => crossOriginIsolated);
      if (!isolated) throw new Error("page is not crossOriginIsolated (COOP/COEP headers missing)");
      console.error(`== k=${k} run ${run}/${runs}`);
      const t0 = Date.now();
      try {
        const r = await page.evaluate(
          async ({ k, params }) => await window.hellproof.run({ k, params, fresh: true }),
          { k, params },
          { timeout: timeoutMs },
        ).catch(async (e) => {
          // page.evaluate has no timeout option; emulate with a race.
          throw e;
        });
        r.run = run;
        r.browser = `${channel} ${version}`;
        r.label = label || r.label;
        r.wall_ms = Date.now() - t0;
        results.push(r);
        console.error(
          `   steps=${r.n_steps} execute=${r.execute_ms.toFixed(0)}ms prove=${r.prove_ms.toFixed(0)}ms ` +
            `verify=${r.verify_ms.toFixed(0)}ms felts=${r.proof_felts} wasm_mem=${(r.wasm_memory_bytes / 2 ** 30).toFixed(2)}GiB ` +
            `ua_mem=${r.ua_memory_peak_bytes ? (r.ua_memory_peak_bytes / 2 ** 30).toFixed(2) : "?"}GiB ok=${r.verify_ok}`,
        );
      } catch (e) {
        const msg = String(e?.message ?? e);
        console.error(`   FAILED: ${msg}`);
        errors.push({ k, run, error: msg, wall_ms: Date.now() - t0, tail: logs.slice(-20) });
        if (ci) throw e;
      } finally {
        await context.close();
      }
    }
  }
} finally {
  await browser.close();
  await server.close();
}

// ---- report -----------------------------------------------------------------------------------
const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
const outDir = path.join(here, "results");
fs.mkdirSync(outDir, { recursive: true });
const meta = {
  date: new Date().toISOString(),
  host: { platform: os.platform(), arch: os.arch(), cpu: os.cpus()[0]?.model, cores: os.cpus().length, mem_gib: os.totalmem() / 2 ** 30 },
  browser: `${channel} ${version}`,
  wasm_sha256: wasmSha,
  params: params || "(built-in leaf defaults)",
  runs,
  ks,
};
fs.writeFileSync(path.join(outDir, `bench-${stamp}.json`), JSON.stringify({ meta, results, errors }, null, 2));

const gib = (b) => (b == null ? "-" : (b / 2 ** 30).toFixed(2));
const s = (ms) => (ms / 1000).toFixed(1);
const lines = [];
lines.push(`# wasm64 bench — ${meta.browser} — ${meta.date}`);
lines.push("");
lines.push(`host: ${meta.host.cpu} (${meta.host.cores} cores, ${meta.host.mem_gib.toFixed(0)} GiB) · wasm: ${wasmSha.split(/\s+/)[0] || "?"} · params: ${paramsFile ?? "built-in leaf defaults"}`);
lines.push("");
lines.push("| k | run | steps | execute s | prove s | verify s | total s | proof felts | proof MB | wasm mem GiB | UA mem peak GiB | max log | lifting | verified |");
lines.push("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|");
for (const r of results) {
  lines.push(
    `| ${r.k} | ${r.run} | ${r.n_steps} | ${s(r.execute_ms)} | ${s(r.prove_ms)} | ${s(r.verify_ms)} | ${s(r.total_ms)} | ${r.proof_felts} | ${(r.proof_bytes / 1e6).toFixed(2)} | ${gib(r.wasm_memory_bytes)} | ${gib(r.ua_memory_peak_bytes)} | ${r.max_log_size} | ${r.trace_lifting_log_size}/${r.preprocessed_lifting_log_size} | ${r.verify_ok} |`,
  );
}
for (const e of errors) lines.push(`| ${e.k} | ${e.run} | FAILED after ${s(e.wall_ms)} s: ${e.error.replace(/\|/g, "/").slice(0, 200)} |`);
lines.push("");
// Per-k summary (median over runs).
const median = (a) => { const b = [...a].sort((x, y) => x - y); return b.length ? b[Math.floor(b.length / 2)] : NaN; };
lines.push("| k | steps | prove s (median) | prove s (min..max) | wasm mem GiB (max) | UA mem peak GiB (max) | proof felts |");
lines.push("|---|---|---|---|---|---|---|");
for (const k of ks) {
  const rs = results.filter((r) => r.k === k);
  if (!rs.length) continue;
  const p = rs.map((r) => r.prove_ms);
  lines.push(
    `| ${k} | ${rs[0].n_steps} | ${s(median(p))} | ${s(Math.min(...p))}..${s(Math.max(...p))} | ${gib(Math.max(...rs.map((r) => r.wasm_memory_bytes)))} | ${gib(Math.max(...rs.map((r) => r.ua_memory_peak_bytes ?? 0)) || null)} | ${rs[0].proof_felts} |`,
  );
}
// Prover-internal span breakdown for the largest k (first run).
const big = results.filter((r) => r.k === Math.max(...ks))[0];
if (big?.stages?.prove?.spans?.length) {
  lines.push("");
  lines.push(`prove() span breakdown, k=${big.k} run ${big.run} (ms, from tracing spans inside the wasm):`);
  lines.push("");
  lines.push("| span | ms |");
  lines.push("|---|---|");
  for (const sp of big.stages.prove.spans) lines.push(`| ${sp.name} | ${sp.ms.toFixed(0)} |`);
}
const md = lines.join("\n") + "\n";
fs.writeFileSync(path.join(outDir, `bench-${stamp}.md`), md);
console.log(md);
if (ci && errors.length) process.exit(1);

// Playwright bench: starts the Vite dev server (COOP/COEP), launches headless Chrome/Chromium and
// runs execute -> resources -> prove -> verify -> proof_to_felts for each size and thread count,
// `runs` times each with a fresh prover Worker, then writes results/bench-<stamp>.{json,md}.
//
//   node bench.mjs [--sizes k14,k20,m2] [--threads 1,4,8] [--runs 3] [--channel chrome|chromium]
//                  [--params file.json] [--headed] [--ci] [--timeout-min 40] [--label name]
//
// Sizes are the files in programs/steps_k/args (k14 … k20, m2 … m4 = millions of steps).
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

const sizes = String(opt("sizes", opt("k", "k14"))).split(",").map((s) => (/^\d+$/.test(s) ? `k${s}` : s));
const threadCounts = String(opt("threads", "1")).split(",").map(Number);
const runs = Number(opt("runs", 3));
const channel = opt("channel", "chrome"); // "chrome" = installed Google Chrome, "chromium" = Playwright's
const paramsFile = opt("params", null);
const params = paramsFile ? fs.readFileSync(paramsFile, "utf8") : "";
const timeoutMs = Number(opt("timeout-min", 40)) * 60_000;
// Pre-grow the shared memory instead of letting the prover grow it under the threads (see
// README §Threads): 512 pages = 32 MiB is the package default.
const initialPages = Number(opt("initial-pages", 512));
const label = opt("label", "");
const ci = flag("ci");

for (const name of ["hellproof_prover_wasm.wasm", "hellproof_prover_wasm.threads.wasm"]) {
  const p = path.join(here, "..", "pkg", "wasm", name);
  if (!fs.existsSync(p)) {
    console.error(`missing ${p}: run ../build.sh first`);
    process.exit(2);
  }
}
if (!fs.existsSync(path.join(here, "..", "pkg", "dist", "index.js"))) {
  console.error("missing ../pkg/dist: run `npm run build` in prover/wasm/pkg first");
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
    "--enable-features=WebAssemblyMemory64,SharedArrayBuffer",
    "--js-flags=--max-old-space-size=4096",
  ],
};
if (channel !== "chromium") launchOpts.channel = channel;
const browser = await chromium.launch(launchOpts);
const version = browser.version();
console.error(`browser: ${channel} ${version}`);

// ROADMAP §4: one proof > 2^19 steps at a time per machine — a mkdir lock shared with the spikes.
const lockDir =
  process.env.PROOF_LOCK_DIR ?? (process.env.SCRATCH ? path.join(process.env.SCRATCH, ".proof-lock") : null);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const isBig = (size) => size.startsWith("m") || Number(size.slice(1)) >= 20;
async function withProofLock(size, fn) {
  if (!isBig(size) || !lockDir) return fn();
  for (;;) {
    try {
      fs.mkdirSync(lockDir);
      break;
    } catch {
      console.error(`waiting for proof lock ${lockDir}`);
      await sleep(30_000);
    }
  }
  try {
    return await fn();
  } finally {
    try {
      fs.rmdirSync(lockDir);
    } catch {}
  }
}

const results = [];
const errors = [];
try {
  for (const size of sizes) {
    for (const threads of threadCounts) {
      for (let run = 1; run <= runs; run++) {
        await withProofLock(size, async () => {
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
          console.error(`== ${size} threads=${threads} run ${run}/${runs}`);
          const t0 = Date.now();
          try {
            page.setDefaultTimeout(timeoutMs);
            const r = await page.evaluate(
              async ({ size, params, threads, initialPages }) =>
                await window.hellproof.run({ size, params, threads, initialPages }),
              { size, params, threads, initialPages },
            );
            r.run = run;
            r.browser = `${channel} ${version}`;
            r.label = label || r.label;
            r.wall_ms = Date.now() - t0;
            results.push(r);
            console.error(
              `   steps=${r.n_steps} threads=${r.threads} execute=${r.execute_ms.toFixed(0)}ms ` +
                `prove=${(r.prove_ms / 1000).toFixed(1)}s verify=${r.verify_ms.toFixed(0)}ms ` +
                `felts=${r.proof_felts} trace_log=${r.trace_log_size} res_log_max=${r.resources.log_max_component_size} ` +
                `wasm_mem=${(r.wasm_memory_bytes / 2 ** 30).toFixed(2)}GiB ` +
                `ua_mem=${r.ua_memory_peak_bytes ? (r.ua_memory_peak_bytes / 2 ** 30).toFixed(2) : "?"}GiB ok=${r.verify_ok}`,
            );
          } catch (e) {
            const msg = String(e?.message ?? e);
            console.error(`   FAILED: ${msg}`);
            errors.push({ size, threads, run, error: msg, wall_ms: Date.now() - t0, tail: logs.slice(-20) });
            if (ci) throw e;
          } finally {
            await context.close();
          }
        });
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
  host: {
    platform: os.platform(),
    arch: os.arch(),
    cpu: os.cpus()[0]?.model,
    cores: os.cpus().length,
    mem_gib: os.totalmem() / 2 ** 30,
  },
  browser: `${channel} ${version}`,
  wasm_sha256: wasmSha,
  params: params || "(built-in leaf defaults)",
  runs,
  sizes,
  threadCounts,
};
fs.writeFileSync(path.join(outDir, `bench-${stamp}.json`), JSON.stringify({ meta, results, errors }, null, 2));

const gib = (b) => (b == null ? "-" : (b / 2 ** 30).toFixed(2));
const s = (ms) => (ms / 1000).toFixed(1);
const median = (a) => {
  const b = [...a].sort((x, y) => x - y);
  return b.length ? b[Math.floor(b.length / 2)] : NaN;
};
const lines = [];
lines.push(`# wasm64 bench — ${meta.browser} — ${meta.date}`);
lines.push("");
lines.push(
  `host: ${meta.host.cpu} (${meta.host.cores} cores, ${meta.host.mem_gib.toFixed(0)} GiB) · params: ${paramsFile ?? "built-in leaf defaults"}`,
);
lines.push("");
lines.push(
  "| size | threads | run | steps | execute s | prove s | verify s | felts s | proof felts | proof MB | wasm mem GiB | UA mem GiB | trace_log | res log_max | verified |",
);
lines.push("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|");
for (const r of results) {
  lines.push(
    `| ${r.size} | ${r.threads} | ${r.run} | ${r.n_steps} | ${s(r.execute_ms)} | ${s(r.prove_ms)} | ${s(r.verify_ms)} | ` +
      `${r.proof_to_felts_ms == null ? "-" : s(r.proof_to_felts_ms)} | ${r.proof_felts} | ${(r.proof_bytes / 1e6).toFixed(2)} | ` +
      `${gib(r.wasm_memory_bytes)} | ${gib(r.ua_memory_peak_bytes)} | ${r.trace_log_size} | ${r.resources.log_max_component_size} | ${r.verify_ok} |`,
  );
}
for (const e of errors) {
  lines.push(`| ${e.size} | ${e.threads} | ${e.run} | FAILED after ${s(e.wall_ms)} s: ${e.error.replace(/\|/g, "/").slice(0, 200)} |`);
}
lines.push("");
lines.push("| size | threads | steps | prove s (median) | prove s (min..max) | wasm mem GiB (max) | UA mem GiB (max) | proof felts |");
lines.push("|---|---|---|---|---|---|---|---|");
for (const size of sizes) {
  for (const threads of threadCounts) {
    const rs = results.filter((r) => r.size === size && r.threads === threads);
    if (!rs.length) continue;
    const p = rs.map((r) => r.prove_ms);
    lines.push(
      `| ${size} | ${threads} | ${rs[0].n_steps} | ${s(median(p))} | ${s(Math.min(...p))}..${s(Math.max(...p))} | ` +
        `${gib(Math.max(...rs.map((r) => r.wasm_memory_bytes)))} | ${gib(Math.max(...rs.map((r) => r.ua_memory_peak_bytes ?? 0)) || null)} | ${rs[0].proof_felts} |`,
    );
  }
}
const big = results[results.length - 1];
if (big?.spans?.prove?.length) {
  lines.push("");
  lines.push(`prove() span breakdown, ${big.size} threads=${big.threads} run ${big.run} (ms, tracing spans inside the wasm):`);
  lines.push("");
  lines.push("| span | ms |");
  lines.push("|---|---|");
  for (const sp of big.spans.prove) lines.push(`| ${sp.name} | ${sp.ms.toFixed(0)} |`);
}
const md = lines.join("\n") + "\n";
fs.writeFileSync(path.join(outDir, `bench-${stamp}.md`), md);
console.log(md);
if (ci && errors.length) process.exit(1);

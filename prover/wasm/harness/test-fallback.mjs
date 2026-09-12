// Checks the single-threaded fallback: on a page that is **not** cross-origin isolated there is no
// SharedArrayBuffer, so `init({threads: 4})` must warn, load the single-threaded artifact and
// still prove and verify.
//
//   node test-fallback.mjs [--channel chrome|chromium] [--size k14]
import { createServer } from "vite";
import { chromium } from "playwright";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = (n, d) => {
  const i = argv.indexOf(`--${n}`);
  return i >= 0 ? argv[i + 1] : d;
};

// Same app, without the COOP/COEP headers.
const server = await createServer({
  root: here,
  configFile: path.join(here, "vite.config.js"),
  logLevel: "warn",
  server: { headers: {}, port: 0 },
});
await server.listen();
const url = server.resolvedUrls.local[0];

const launchOpts = { headless: true, args: ["--enable-features=WebAssemblyMemory64"] };
const channel = opt("channel", "chrome");
if (channel !== "chromium") launchOpts.channel = channel;
const browser = await chromium.launch(launchOpts);
const page = await browser.newPage();
page.on("pageerror", (e) => console.error(`[pageerror] ${e.message}`));

let code = 0;
try {
  await page.goto(url, { waitUntil: "load" });
  const isolated = await page.evaluate(() => crossOriginIsolated);
  if (isolated) throw new Error("expected a NON cross-origin isolated page");
  page.setDefaultTimeout(20 * 60_000);
  const r = await page.evaluate(
    async ({ size }) => await window.hellproof.run({ size, threads: 4, felts: false }),
    { size: opt("size", "k14") },
  );
  console.log(
    JSON.stringify({
      crossOriginIsolated: isolated,
      requested_threads: 4,
      got_threads: r.threads,
      threaded: r.threaded,
      artifact: r.wasm_url,
      prove_s: +(r.prove_ms / 1000).toFixed(1),
      verify_ok: r.verify_ok,
      proof_felts: r.proof_felts,
    }),
  );
  if (r.threaded || r.threads !== 1) throw new Error("expected the single-threaded fallback");
  if (!r.verify_ok) throw new Error("proof did not verify");
  console.log("fallback OK");
} catch (e) {
  console.error(`FAILED: ${e?.message ?? e}`);
  code = 1;
} finally {
  await browser.close();
  await server.close();
}
process.exit(code);

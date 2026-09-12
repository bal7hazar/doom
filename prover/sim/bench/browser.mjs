// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

// Headless Chromium runner: the benchmark runs inside a Web Worker, which is
// where the client's simulation will live.

import { chromium } from 'playwright';
import { startServer } from './server.mjs';

const iters = Number(process.env.BENCH_ITERS ?? 2000);
const leakIters = Number(process.env.BENCH_LEAK_ITERS ?? 10000);

const { server, port } = await startServer(0);
const browser = await chromium.launch({ args: ['--enable-features=SharedArrayBuffer'] });
const page = await browser.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(String(e)));
page.on('console', (m) => {
  if (m.type() === 'error') errors.push(m.text());
});

await page.goto(`http://127.0.0.1:${port}/bench/index.html?iters=${iters}&leakIters=${leakIters}`);
const payload = await page.waitForFunction(() => window.__benchDone, null, { timeout: 900000 });
const data = await payload.jsonValue();

await browser.close();
server.close();

if (!data.ok) {
  console.error(data.error);
  process.exit(1);
}
data.results.browser = await chromiumVersion();
if (errors.length) data.results.page_errors = errors;
console.log(JSON.stringify(data.results, null, 2));

async function chromiumVersion() {
  const b = await chromium.launch();
  const v = b.version();
  await b.close();
  return `chromium ${v} (playwright)`;
}

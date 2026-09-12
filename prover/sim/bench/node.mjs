// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

// Node runner: same wasm artifact, same benchmark body as the browser.

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import init, * as mod from '../pkg/hellproof_sim.js';
import { runBenchmark } from './bench-core.mjs';
import { CASES, EXECUTABLE, WASM } from './config.mjs';

const wasmPath = fileURLToPath(new URL(WASM, import.meta.url));
const execPath = fileURLToPath(new URL(EXECUTABLE, import.meta.url));

const bytes = await readFile(wasmPath);
const wasm = await init({ module_or_path: bytes });
const executableJson = await readFile(execPath, 'utf8');

const results = await runBenchmark({
  mod,
  wasm,
  executableJson,
  cases: CASES,
  environment: `node ${process.version} (wasm)`,
  iters: Number(process.env.BENCH_ITERS ?? 2000),
  leakIters: Number(process.env.BENCH_LEAK_ITERS ?? 10000),
});

results.wasm_bytes = bytes.length;
console.log(JSON.stringify(results, null, 2));

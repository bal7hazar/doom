// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

// The sim Worker. This is the shape the client's `sim` worker will have
// (PLAN.md phase 2, task 3): the wasm module is instantiated once, the
// executable is parsed once, and every tic is a plain call.

import init, * as mod from '../pkg/hellproof_sim.js';
import { runBenchmark } from './bench-core.mjs';

self.onmessage = async (event) => {
  const { wasmUrl, executableJson, cases, iters, leakIters } = event.data;
  try {
    const t0 = performance.now();
    const response = await fetch(wasmUrl);
    const bytes = await response.arrayBuffer();
    const tFetch = performance.now() - t0;

    const t1 = performance.now();
    const wasm = await init({ module_or_path: bytes });
    const tInstantiate = performance.now() - t1;

    const results = await runBenchmark({
      mod,
      wasm,
      executableJson,
      cases,
      iters,
      leakIters,
      environment: 'chromium worker (wasm)',
      // `performance.memory` does not exist in workers; this one does, but
      // only under cross-origin isolation (which the server provides).
      memoryProbe:
        typeof performance.measureUserAgentSpecificMemory === 'function' && self.crossOriginIsolated
          ? async () => (await performance.measureUserAgentSpecificMemory()).bytes
          : null,
    });
    results.wasm_bytes = bytes.byteLength;
    results.wasm_fetch_ms = tFetch;
    results.wasm_instantiate_ms = tInstantiate;
    results.hardware_concurrency = navigator.hardwareConcurrency;
    results.cross_origin_isolated = self.crossOriginIsolated;
    self.postMessage({ ok: true, results });
  } catch (error) {
    self.postMessage({ ok: false, error: String(error && error.stack ? error.stack : error) });
  }
};

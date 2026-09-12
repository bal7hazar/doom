// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

// Environment-agnostic benchmark body. It is imported as-is by the Node
// runner and by the browser Worker, so both environments measure exactly the
// same thing.
//
// The argument buffer is allocated once and refilled in place: allocating a
// fresh 48 kB typed array per tic would make the measurement a GC benchmark
// (it doubles the mean and multiplies the p99 by 20), and the real client
// keeps the state in one buffer anyway (R5-A2).

export const FELT_BYTES = 32;

const now = () =>
  typeof performance !== 'undefined' && performance.now ? performance.now() : Date.now();

export function allocArgs(stateLen) {
  const bytes = new Uint8Array((stateLen + 2) * FELT_BYTES);
  return { bytes, view: new DataView(bytes.buffer), stateLen };
}

/** Cairo serialization of `(state: Array<felt252>, cmd: felt252)` as fixed
 *  32-byte little-endian felts: `[len, s0, .., s_{n-1}, cmd]`. Same values as
 *  the native bench, without BigInt (which would allocate per element). */
export function fillArgs(args, tic) {
  const { view, stateLen } = args;
  view.setUint32(0, stateLen, true);
  for (let i = 0; i < stateLen; i += 1) {
    const product = i * 2654435761; // < 2^43, exact in a double
    const lo = (product % 4294967296 ^ tic) >>> 0;
    const hi = Math.floor(product / 4294967296) >>> 0;
    const off = (i + 1) * FELT_BYTES;
    view.setUint32(off, lo, true);
    view.setUint32(off + 4, hi, true);
  }
  view.setUint32((stateLen + 1) * FELT_BYTES, tic % 8, true);
  return args.bytes;
}

function stats(samples) {
  const sorted = Float64Array.from(samples).sort();
  const at = (p) => sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * p))];
  return {
    mean_ms: samples.reduce((a, b) => a + b, 0) / samples.length,
    p50_ms: at(0.5),
    p95_ms: at(0.95),
    p99_ms: at(0.99),
    max_ms: sorted[sorted.length - 1],
    over_28_6_ms: samples.filter((x) => x > 28.6).length,
  };
}

/** FNV-1a over the raw output bytes of 100 tics: a cheap cross-environment
 *  equivalence check (groundwork for R5-A3). The native bench computes the
 *  same value over the same inputs. */
export function outputFingerprint(program, stateLen, tics = 100) {
  const args = allocArgs(stateLen);
  let hash = 0x811c9dc5;
  for (let tic = 0; tic < tics; tic += 1) {
    const out = program.run(fillArgs(args, tic));
    for (let i = 0; i < out.length; i += 1) {
      hash ^= out[i];
      hash = Math.imul(hash, 0x01000193) >>> 0;
    }
  }
  return hash >>> 0;
}

function jsHeapBytes() {
  // Chromium only, and quantised, but it is the one number that shows a
  // JS-side leak.
  return typeof performance !== 'undefined' && performance.memory
    ? performance.memory.usedJSHeapSize
    : null;
}

/**
 * @param {object} o
 * @param {object} o.mod   the wasm-bindgen ES module namespace
 * @param {object} o.wasm  the raw wasm exports (for `memory`)
 * @param {string} o.executableJson  contents of the `.executable.json`
 * @param {Array<{name: string, stateLen: number}>} o.cases
 */
export async function runBenchmark({
  mod,
  wasm,
  executableJson,
  cases,
  iters = 2000,
  warmup = 500,
  leakIters = 10000,
  naiveIters = 20,
  environment = 'unknown',
  memoryProbe = null,
}) {
  const results = { environment, iters, warmup, cases: [] };

  // --- first-call latency: parse the executable + first run ------------------
  {
    const args = allocArgs(cases[0].stateLen);
    const t0 = now();
    const program = mod.SimProgram.load(executableJson);
    const tLoad = now() - t0;
    const t1 = now();
    program.run(fillArgs(args, 0));
    const tFirstRun = now() - t1;
    results.first_call = {
      case: cases[0].name,
      load_ms: tLoad,
      first_run_ms: tFirstRun,
      total_ms: tLoad + tFirstRun,
    };
    program.free();
  }

  for (const c of cases) {
    const program = mod.SimProgram.load(executableJson);
    const args = allocArgs(c.stateLen);
    fillArgs(args, 0);

    for (let i = 0; i < warmup; i += 1) program.run(args.bytes);
    const steps = program.last_steps();

    // --- sustained throughput, copy-in/copy-out API -------------------------
    const samples = new Array(iters);
    let outLen = 0;
    let encodeMs = 0;
    const t0 = now();
    for (let i = 0; i < iters; i += 1) {
      const tEnc = now();
      fillArgs(args, i);
      const tCall = now();
      encodeMs += tCall - tEnc;
      const out = program.run_timed(args.bytes);
      samples[i] = now() - tCall;
      outLen = out.length / FELT_BYTES;
    }
    const totalMs = now() - t0;

    // --- in-wasm breakdown, on a separate pass so that reading the timings
    // does not pollute the throughput loop above -----------------------------
    const breakdownIters = Math.min(iters, 300);
    const acc = new Float64Array(5);
    for (let i = 0; i < breakdownIters; i += 1) {
      fillArgs(args, i);
      program.run_timed(args.bytes);
      const s = program.last_timings();
      for (let k = 0; k < 5; k += 1) acc[k] += s[k];
    }
    const t = Array.from(acc, (v) => v / breakdownIters);

    // --- zero-copy variant: arguments written straight into wasm memory ------
    const zeroCopy = new Array(Math.min(iters, 500));
    let sink = 0;
    for (let i = 0; i < zeroCopy.length; i += 1) {
      fillArgs(args, i);
      const t1 = now();
      const ptr = program.reserve_input(c.stateLen + 2);
      new Uint8Array(wasm.memory.buffer, ptr, args.bytes.length).set(args.bytes);
      const n = program.run_buffered(c.stateLen + 2);
      const view = new Uint8Array(wasm.memory.buffer, program.output_ptr(), n * FELT_BYTES);
      sink += view[0]; // touch the result so nothing is optimized away
      zeroCopy[i] = now() - t1;
    }

    // --- the JS<->wasm copy on its own, no VM --------------------------------
    const copyOnly = new Array(500);
    for (let i = 0; i < copyOnly.length; i += 1) {
      const t1 = now();
      const ptr = program.reserve_input(c.stateLen + 2);
      new Uint8Array(wasm.memory.buffer, ptr, args.bytes.length).set(args.bytes);
      copyOnly[i] = now() - t1;
    }

    results.cases.push({
      name: c.name,
      state_felts: c.stateLen,
      steps_per_call: steps,
      output_felts: outLen,
      payload_bytes_in: (c.stateLen + 2) * FELT_BYTES,
      output_fingerprint: outputFingerprint(program, c.stateLen),
      tics_per_s: (1000 * iters) / totalMs,
      steps_per_s: (1000 * iters * steps) / totalMs,
      js_fill_args_ms: encodeMs / iters,
      call: stats(samples),
      zero_copy: stats(zeroCopy),
      copy_in_only_ms: copyOnly.reduce((a, b) => a + b, 0) / copyOnly.length,
      in_wasm_breakdown_ms: {
        decode_args: t[0],
        runner_init: t[1],
        vm_run: t[2],
        read_output: t[3],
        encode_output: t[4],
      },
      _sink: sink,
    });
    program.free();
  }

  // --- the naive alternative: re-parse the executable JSON per call ---------
  {
    const c = cases[0];
    const args = allocArgs(c.stateLen);
    fillArgs(args, 1);
    const t0 = now();
    for (let i = 0; i < naiveIters; i += 1) mod.run_once_from_json(executableJson, args.bytes);
    results.naive_reparse = {
      case: c.name,
      per_call_ms: (now() - t0) / naiveIters,
      iters: naiveIters,
      executable_json_bytes: executableJson.length,
    };
  }

  // --- memory growth over `leakIters` calls --------------------------------
  {
    const c = cases[0];
    const program = mod.SimProgram.load(executableJson);
    const args = allocArgs(c.stateLen);
    fillArgs(args, 7);
    program.run(args.bytes);
    const wasmBefore = mod.wasm_memory_bytes();
    const heapBefore = jsHeapBytes();
    const probeBefore = memoryProbe ? await memoryProbe() : null;
    const t0 = now();
    for (let i = 0; i < leakIters; i += 1) program.run(args.bytes);
    const elapsed = now() - t0;
    const wasmAfter = mod.wasm_memory_bytes();
    const heapAfter = jsHeapBytes();
    const probeAfter = memoryProbe ? await memoryProbe() : null;
    program.free();
    results.memory = {
      case: c.name,
      iters: leakIters,
      wasm_bytes_before: wasmBefore,
      wasm_bytes_after: wasmAfter,
      wasm_growth_bytes: wasmAfter - wasmBefore,
      js_heap_before: heapBefore,
      js_heap_after: heapAfter,
      js_heap_growth: heapBefore === null ? null : heapAfter - heapBefore,
      agent_memory_before: probeBefore,
      agent_memory_after: probeAfter,
      agent_memory_growth: probeBefore === null ? null : probeAfter - probeBefore,
      sustained_tics_per_s: (1000 * leakIters) / elapsed,
    };
  }

  return results;
}

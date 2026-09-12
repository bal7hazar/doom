// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

// `npm run bench`: native + Node + headless-Chromium-Worker, plus the
// program-size sweep for the naive alternative. Writes `results/*.json` and
// prints the tables that go into docs/spikes/S3.md.

import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, statSync, readFileSync } from 'node:fs';
import { gzipSync, brotliCompressSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { runNative } from './native.mjs';
import { CASES } from './config.mjs';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const RESULTS = here('./results');
mkdirSync(RESULTS, { recursive: true });

const node = (script, env = {}) =>
  JSON.parse(
    execFileSync(process.execPath, [here(script)], {
      encoding: 'utf8',
      maxBuffer: 1 << 26,
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'inherit'],
    }),
  );

console.error('# native…');
const native = runNative();
writeFileSync(`${RESULTS}/native.json`, JSON.stringify(native, null, 2));

console.error('# node (wasm)…');
const nodeWasm = node('./node.mjs');
writeFileSync(`${RESULTS}/node.json`, JSON.stringify(nodeWasm, null, 2));

console.error('# chromium worker (wasm)…');
const browser = node('./browser.mjs');
writeFileSync(`${RESULTS}/browser.json`, JSON.stringify(browser, null, 2));

console.error('# program-size sweep (naive re-parse)…');
const BIN = here('../target/release/hellproof-sim-bench');
const EXEC = here('./step_tic/target/dev/step_tic.executable.json');
const sweep = [0, 5000, 20000, 100000].map((inflate) => {
  const out = JSON.parse(
    execFileSync(
      BIN,
      [
        '--executable', EXEC,
        '--state-len', '112',
        '--iters', '200',
        '--leak-iters', '0',
        '--naive-iters', '10',
        '--inflate', String(inflate),
        '--json',
      ],
      { encoding: 'utf8', maxBuffer: 1 << 24 },
    ),
  );
  return {
    inflate_words: inflate,
    executable_json_bytes: out.executable_json_bytes,
    load_ms: out.load_ms,
    cached_ms: out.mean_ms,
    naive_reparse_ms: out.naive_reparse_ms,
    speedup: out.naive_reparse_ms / out.mean_ms,
  };
});
writeFileSync(`${RESULTS}/size-sweep.json`, JSON.stringify(sweep, null, 2));

const wasmPath = here('../pkg/hellproof_sim_bg.wasm');
const wasmBytes = statSync(wasmPath).size;
const wasmGzip = gzipSync(readFileSync(wasmPath), { level: 9 }).length;
const wasmBrotli = brotliCompressSync(readFileSync(wasmPath)).length;

// --- tables ---------------------------------------------------------------
const row = (...cells) => `| ${cells.join(' | ')} |`;
const f = (x, d = 2) => (typeof x === 'number' ? x.toFixed(d) : String(x));

console.log(`\n## Sustained throughput (${nodeWasm.iters} consecutive calls)\n`);
console.log(
  row('case', 'state felts', 'steps/tic', 'native tics/s', 'node tics/s', 'chromium worker tics/s', 'chromium steps/s', 'outputs agree'),
);
console.log(row('---', '---:', '---:', '---:', '---:', '---:', '---:', ':---:'));
for (const [i, c] of CASES.entries()) {
  const agree =
    native.cases[i].output_fingerprint === nodeWasm.cases[i].output_fingerprint &&
    native.cases[i].output_fingerprint === browser.cases[i].output_fingerprint;
  console.log(
    row(
      c.name,
      c.stateLen,
      native.cases[i].steps_per_call,
      f(native.cases[i].tics_per_s, 0),
      f(nodeWasm.cases[i].tics_per_s, 0),
      f(browser.cases[i].tics_per_s, 0),
      f(browser.cases[i].steps_per_s / 1e6, 2) + ' M',
      agree ? 'yes' : `NO (${native.cases[i].output_fingerprint}/${nodeWasm.cases[i].output_fingerprint}/${browser.cases[i].output_fingerprint})`,
    ),
  );
}

console.log(`\n## Per-call breakdown, chromium worker (ms)\n`);
console.log(row('case', 'JS fill args', 'copy in', 'decode felts', 'runner init', 'VM run', 'read output', 'encode output', 'total call'));
console.log(row('---', '---:', '---:', '---:', '---:', '---:', '---:', '---:', '---:'));
for (const c of browser.cases) {
  const b = c.in_wasm_breakdown_ms;
  console.log(
    row(
      c.name,
      f(c.js_fill_args_ms, 4),
      f(c.copy_in_only_ms, 4),
      f(b.decode_args, 4),
      f(b.runner_init, 4),
      f(b.vm_run, 4),
      f(b.read_output, 4),
      f(b.encode_output, 4),
      f(c.call.mean_ms, 4),
    ),
  );
}

console.log(`\n## Latency distribution, chromium worker (ms)\n`);
console.log(row('case', 'p50', 'p95', 'p99', 'max', 'calls > 28.6 ms'));
console.log(row('---', '---:', '---:', '---:', '---:', '---:'));
for (const c of browser.cases) {
  console.log(row(c.name, f(c.call.p50_ms, 3), f(c.call.p95_ms, 3), f(c.call.p99_ms, 3), f(c.call.max_ms, 3), c.call.over_28_6_ms));
}

console.log(`\n## Copy cost: copy-in/copy-out API vs zero-copy (mean ms)\n`);
console.log(row('case', 'payload bytes', 'run(Uint8Array)', 'run_buffered (zero copy)', 'delta'));
console.log(row('---', '---:', '---:', '---:', '---:'));
for (const c of browser.cases) {
  console.log(
    row(c.name, c.payload_bytes_in, f(c.call.mean_ms, 4), f(c.zero_copy.mean_ms, 4), f(c.call.mean_ms - c.zero_copy.mean_ms, 4)),
  );
}

console.log(`\n## First-call latency\n`);
console.log(row('environment', 'wasm fetch ms', 'wasm instantiate ms', 'executable parse ms', 'first run ms'));
console.log(row('---', '---:', '---:', '---:', '---:'));
console.log(row('native', '-', '-', f(native.cases[0].load_ms, 2), f(native.cases[0].first_run_ms, 2)));
console.log(row('node', '-', '-', f(nodeWasm.first_call.load_ms, 2), f(nodeWasm.first_call.first_run_ms, 2)));
console.log(
  row(
    'chromium worker',
    f(browser.wasm_fetch_ms, 1),
    f(browser.wasm_instantiate_ms, 1),
    f(browser.first_call.load_ms, 2),
    f(browser.first_call.first_run_ms, 2),
  ),
);
console.log(
  `\nwasm artifact: ${wasmBytes} bytes raw, ${wasmGzip} gzip, ${wasmBrotli} brotli ` +
    `(${browser.hardware_concurrency} cores, crossOriginIsolated=${browser.cross_origin_isolated}, ${browser.browser})\n`,
);

console.log(`\n## Memory over ${nodeWasm.memory.iters} calls\n`);
console.log(row('environment', 'wasm memory before', 'after', 'growth', 'JS heap growth'));
console.log(row('---', '---:', '---:', '---:', '---:'));
for (const [name, r] of [['node', nodeWasm.memory], ['chromium worker', browser.memory]]) {
  console.log(
    row(name, r.wasm_bytes_before, r.wasm_bytes_after, r.wasm_growth_bytes, r.agent_memory_growth ?? r.js_heap_growth ?? 'n/a'),
  );
}
console.log(
  row(
    'native (live heap bytes)',
    native.cases[0].live_bytes.leak_start,
    native.cases[0].live_bytes.leak_end,
    native.cases[0].live_bytes.leak_end - native.cases[0].live_bytes.leak_start,
    'n/a',
  ),
);

console.log(`\n## Naive alternative: re-parsing the executable JSON per call (native, 4k case)\n`);
console.log(row('dead words added', 'executable JSON bytes', 'parse ms', 'cached call ms', 'naive call ms', 'speedup'));
console.log(row('---:', '---:', '---:', '---:', '---:', '---:'));
for (const s of sweep) {
  console.log(
    row(s.inflate_words, s.executable_json_bytes, f(s.load_ms, 2), f(s.cached_ms, 3), f(s.naive_reparse_ms, 3), `${f(s.speedup, 1)}x`),
  );
}
console.log(
  `\nIn the browser Worker, the same comparison on the 4 kB benchmark program: ` +
    `${f(browser.cases[0].call.mean_ms, 3)} ms cached vs ${f(browser.naive_reparse.per_call_ms, 3)} ms naive ` +
    `(${f(browser.naive_reparse.per_call_ms / browser.cases[0].call.mean_ms, 1)}x).`,
);
console.error(`\nresults written to ${RESULTS}`);

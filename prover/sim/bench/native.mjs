// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

// Native runner: one process per case, so that each case gets a fresh
// allocator and the leak numbers mean something.

import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { CASES, EXECUTABLE } from './config.mjs';

const BIN = fileURLToPath(new URL('../target/release/hellproof-sim-bench', import.meta.url));
const EXEC = fileURLToPath(new URL(EXECUTABLE, import.meta.url));

const iters = String(process.env.BENCH_ITERS ?? 2000);
const leakIters = String(process.env.BENCH_LEAK_ITERS ?? 10000);

export function runNative(extraArgs = []) {
  const cases = CASES.map((c) => {
    const out = execFileSync(
      BIN,
      [
        '--executable', EXEC,
        '--state-len', String(c.stateLen),
        '--iters', iters,
        '--leak-iters', leakIters,
        '--json',
        ...extraArgs,
      ],
      { encoding: 'utf8', maxBuffer: 1 << 24 },
    );
    return { name: c.name, ...JSON.parse(out) };
  });
  return { environment: 'native (aarch64-apple-darwin)', cases };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  console.log(JSON.stringify(runNative(), null, 2));
}

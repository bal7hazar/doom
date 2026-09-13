#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0
// Execute the exact local artifact with the built WASM runtime; never generate a proof.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [corePath, executablePath, argsPath] = process.argv.slice(2);
if (!corePath || !executablePath || !argsPath) {
  throw new Error('usage: measure_task_hash.mjs <built core.js> <executable.json> <args.json> (Node 24)');
}
const { ProverCore } = await import(pathToFileURL(resolve(corePath)).href);
const executable = readFileSync(executablePath, 'utf8');
const args = JSON.parse(readFileSync(argsPath, 'utf8'));
if (!Array.isArray(args) || args.some((felt) => typeof felt !== 'string')) {
  throw new Error('arguments must be felt strings, never JSON numbers');
}
const core = new ProverCore();
try {
  await core.init({ threads: 1 });
  const result = core.execute(executable, args);
  const programHash = result.stats.output_preimage[0];
  if (typeof programHash !== 'string') throw new Error('runtime returned no task hash');
  console.log(JSON.stringify({
    executable: resolve(executablePath),
    executable_sha256: createHash('sha256').update(executable).digest('hex'),
    hash_function: 'blake', // D31: the pinned WASM core executes HashFunc::Blake.
    program_hash: programHash,
    n_steps: result.stats.n_steps,
  }, null, 2));
} finally { core.terminate(); }

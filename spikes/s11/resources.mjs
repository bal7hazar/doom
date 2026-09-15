// SPDX-License-Identifier: Apache-2.0
// Each job gets a fresh mono WASM instance/process. execute/resources only: no prove call.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const load = path => JSON.parse(readFileSync(path, 'utf8'));
const save = (path, value) => writeFileSync(path, JSON.stringify(value, null, 2) + '\n');
const pad = n => 2 ** Math.ceil(Math.log2(Math.max(16, n)));
function heights(r, params) {
  // The formulas and inventory are pinned to prover/wasm/src/core.rs at the recorded source hash.
  // All auxiliary parent padding has ALREADY been applied by resources(); do not apply it twice.
  assert(Array.isArray(r.auxiliary_components), 'AIR-complete artifact required');
  assert.equal(params.preprocessed_trace, 'canonical_small');
  const rows = [...r.opcodes.filter(([, n]) => n > 0),
    ...r.builtins.filter(([name, n]) => n > 0 && name !== 'output_builtin'),
    ['memory_address_to_id', Math.ceil(Math.max(0, r.memory_address_to_id - 1) / 16)],
    ['memory_id_to_big', Math.min(r.memory_id_to_big, 2 ** 20)],
    ['memory_id_to_small', r.memory_id_to_small],
    ['verify_instruction', r.verify_instruction], ...r.auxiliary_components]
    .map(([name, raw_rows]) => ({ name, raw_rows, padded_rows: pad(raw_rows), log_rows: Math.log2(pad(raw_rows)) }))
    .sort((a, b) => a.name.localeCompare(b.name));
  assert.equal(new Set(rows.map(r => r.name)).size, rows.length, 'duplicate component');
  const max = rows.reduce((a, b) => b.padded_rows > a.padded_rows ||
    (b.padded_rows === a.padded_rows && b.raw_rows > a.raw_rows) ? b : a);
  assert.equal(max.padded_rows, r.max_component_rows);
  assert.equal(rows.find(x => x.name === r.max_component)?.raw_rows, max.raw_rows);
  assert.equal(max.log_rows, r.log_max_component_size);
  return rows;
}

async function one(corePath, executable, jobPath, outPath) {
  const { ProverCore } = await import(pathToFileURL(resolve(corePath)).href);
  const job = load(jobPath);
  const core = new ProverCore(event => {
    if (event.type === 'log' && event.level === 'error') process.stderr.write(event.message + '\n');
  });
  try {
    const info = await core.init({ threads: 1 });
    const params = core.defaultParams();
    const bytes = readFileSync(executable);
    const execution = core.execute(bytes.toString('utf8'), job.args);
    const actual = execution.stats.output_preimage.slice(-job.expected.length).map(BigInt);
    assert.deepEqual(actual, job.expected.map(BigInt), 'WASM task output differs from native');
    const resources = core.resources(execution.input, params);
    const components = heights(resources, params);
    save(outPath, {
      name: job.name, program: job.program, executable_sha256: sha(bytes),
      bytecode_words: JSON.parse(bytes).program.bytecode.length,
      wasm: { sha256: sha(readFileSync(fileURLToPath(info.wasmUrl))), threads: info.threads },
      params, execution: execution.stats, execution_ms: execution.ms,
      resources, variable_components: components, variable_component_types: components.length,
      fixed_component_log_size: resources.fixed_component_log_size,
      forced_big_memory_components: params.opt_n_id_to_big_components,
      native_task_output_equal: true, proof_generated: false,
    });
  } finally { core.terminate(); }
}

if (process.argv[2] === '--one') {
  await one(...process.argv.slice(3));
} else {
  const [core, reference, measurement, timeout = '120000'] = process.argv.slice(2);
  assert(core && reference && measurement, 'usage: node resources.mjs CORE_JS REFERENCE_DIR MEASURE_DIR [timeout_ms]');
  const jobs = load(join(measurement, 'resource_jobs.json'));
  const outDir = join(measurement, 'resources');
  mkdirSync(outDir, { recursive: true });
  const results = [];
  for (const job of jobs) {
    const file = `${job.name}.${job.program}`;
    const jobPath = join(outDir, file + '.job.json');
    const outPath = join(outDir, file + '.json');
    save(jobPath, job);
    const production = job.program.startsWith('production_');
    const executable = join(reference, production ? 'production' : 'proving',
      (production ? job.program.slice('production_'.length) : job.program) + '.executable.json');
    const run = spawnSync(process.execPath, [fileURLToPath(import.meta.url), '--one', core, executable, jobPath, outPath], {
      encoding: 'utf8', timeout: Number(timeout), env: { ...process.env, RAYON_NUM_THREADS: '1' },
      maxBuffer: 4 * 1024 * 1024,
    });
    if (run.status !== 0 || run.error) throw new Error(`${file}: ${run.error ?? run.stderr}`);
    assert(existsSync(outPath));
    const result = load(outPath);
    results.push(result);
    console.log(`${file}: ${result.execution.n_steps} bootloader steps, ${result.resources.max_component} ` +
      `log${result.resources.log_max_component_size}, ${result.variable_component_types} variable component types; exact output`);
    save(join(measurement, 'resources.json'), results);
  }
}

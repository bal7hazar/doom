#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Exact per-tic costs from real VM call frames, not averages of chunks.

Execute a replay in bounded chunks. Identify the recursive step_tic_impl
loop in Sierra, map its entry to CASM, and subtract the recursive child's
inclusive frame cost from its parent's. Each sample includes all game
subcalls and loop return/argument bookkeeping. Deserialization, final
serialization/snapshot and dictionary squash outside these frames are
reported separately as boundary_steps. Every tic is sampled, including
terminal ones. Chunking only limits trace memory and never smooths p99.
"""
import argparse
import hashlib
import json
import math
import re
import statistics
import subprocess
import tempfile
from pathlib import Path
import profile as P


def loop_entry(sierra_path):
    sierra = json.loads(sierra_path.read_text())
    annotations = sierra['debug_info']['annotations']['github.com/software-mansion/cairo-profiler']['statements_functions']
    candidates = []
    for function in sierra['funcs']:
        entry = function['entry_point']
        stack = next((annotations[str(i)] for i in range(entry, entry + 20) if str(i) in annotations), [])
        if stack and stack[-1] == 'doom_run::step_tic_impl' and 'core::array::SpanImpl::pop_front' in stack:
            candidates.append(entry)
    if len(candidates) != 1:
        raise RuntimeError(f'expected one command loop, found {candidates}')
    tool = P.WORKSPACE.parent / 'infra/sierra_words/target/release/sierra_words'
    output = subprocess.check_output([str(tool), str(sierra_path)], text=True)
    for line in output.splitlines():
        values = line.split()
        if values[0] == str(candidates[0]): return int(values[1])
    raise RuntimeError('loop entry not found in CASM map')


def frame_costs(info, code_offset, actual):
    casm = info['cairo_execution_info']['casm_level_info']
    # Relocated program segment starts at address 1, ahead of its header.
    entry_pc = 1 + casm['program_offset'] + code_offset
    frames, active = [], []
    trace = casm['vm_trace']
    for index, row in enumerate(trace):
        while active and row['fp'] < frames[active[-1]]['fp']:
            frames[active.pop()]['end'] = index
        if row['pc'] == entry_pc:
            frames.append({'start': index, 'fp': row['fp']})
            active.append(len(frames) - 1)
    if active or len(frames) not in (actual, actual + 1):
        raise RuntimeError(f'incomplete loop frames: {len(frames)}, actual {actual}, active {active}')
    costs = []
    for i, frame in enumerate(frames[:actual]):
        cost = frame['end'] - frame['start']
        if i + 1 < len(frames):
            child = frames[i + 1]
            if child['end'] > frame['end']: raise RuntimeError('frames not nested')
            cost -= child['end'] - child['start']
        costs.append(cost)
    return costs


def execute_trace(state, commands, offset):
    args = [len(state), *state, len(commands), *commands]
    with tempfile.NamedTemporaryFile('w', suffix='.json') as f:
        json.dump([hex(x) for x in args], f); f.flush()
        run = P.scarb(['execute', '-p', 'doom_run', '--executable-name', 'step_tic', '--no-build',
            '--arguments-file', f.name, '--print-program-output', '--print-resource-usage', '--save-profiler-trace-data'])
    if run.returncode: raise RuntimeError(run.stdout[-4000:] + run.stderr[-4000:])
    trace_path = Path(re.search(r'Saving profiler trace data to: (.+)', run.stdout)[1])
    values = []
    output = False
    for line in run.stdout.splitlines():
        if line.startswith('Program output:'): output = True; continue
        if line.startswith('Resources:'): break
        if output and line.strip(): values.append(int(line.strip(), 0) % P.PRIME)
    status, count = values[:2]
    new_state = values[2:2 + count]
    actual = new_state[4] - state[4]
    info = json.loads(trace_path.read_text())
    costs = frame_costs(info, offset, actual)
    total = info['used_execution_resources']['vm_resources']['n_steps']
    # Delete only this freshly-created transient trace; samples and hashes
    # are saved in the report, and no prior trace/artifact is touched.
    trace_path.unlink()
    return new_state, status, costs, total


def quantile(values, q): return sorted(values)[max(0, math.ceil(len(values) * q) - 1)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--scenario', action='append', choices=sorted(P.LOGS))
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--chunk', type=int, default=35)
    ap.add_argument('--tics', type=int)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    sierra = P.WORKSPACE / 'target' / P.PROFILE / 'step_tic.executable.sierra.json'
    executable = sierra.with_name('step_tic.executable.json')
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    offset = loop_entry(sierra)
    names = sorted(P.LOGS) if args.all else (args.scenario or ['idle'])
    results = []
    for name in names:
        state = P.genesis_state()
        commands = P.LOGS[name]()[:args.tics]
        samples, chunks = [], []
        while state[4] < len(commands):
            start = state[4]
            state, status, costs, total = execute_trace(state, commands[start:start + args.chunk], offset)
            if not costs: raise RuntimeError('no progress')
            samples.extend(costs)
            chunks.append({'tic': start, 'tics': len(costs), 'total_steps': total, 'boundary_steps': total - sum(costs)})
            print(f'{name} tic{start} +{len(costs)} mean{statistics.fmean(costs):.0f} p99{quantile(costs,.99)} boundary{total-sum(costs)}', flush=True)
            if status: break
        boundary = [c['boundary_steps'] for c in chunks]
        h, _ = P.execute('run_segment', [len(state), *state, 0, state[4], 0])
        result = dict(scenario=name, profile=P.PROFILE, executable_sha256=digest, tics=len(samples), status=status,
            mean=statistics.fmean(samples), p50=quantile(samples,.5), p90=quantile(samples,.9), p99=quantile(samples,.99),
            max=max(samples), boundary_mean=statistics.fmean(boundary), final_hash=hex(h[1]), samples=samples, chunks=chunks)
        results.append(result)
        args.out.write_text(json.dumps(results, indent=2) + '\n')
        print(json.dumps({k:v for k,v in result.items() if k not in ('samples','chunks')}), flush=True)
    return 0

if __name__ == '__main__': raise SystemExit(main())

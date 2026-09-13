#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Count real single-tic instructions, actor allocations and roster writes.

Use an immutable Sierra and its matching --keep-trace profile directory.
Counts cover the actual command-loop frame, excluding its final empty child
and every input/output boundary. An allocation is one executed, nonempty
into_box<Mobj> statement, not a guessed heap/RAM bound.
"""
import argparse
from bisect import bisect_right
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('tic_frames', HERE.parent / 'bench/trace_profile.py')
T = importlib.util.module_from_spec(spec)
# trace_profile imports its sibling replay helper as `profile`.
sys.path.insert(0, str(HERE.parent / 'bench'))
try:
    spec.loader.exec_module(T)
finally:
    sys.path.pop(0)


def inspect(sierra_path, profile, tool):
    sierra = json.loads(sierra_path.read_text())
    executable = sierra_path.with_name('step_tic.executable.json')
    identity = json.loads((profile / 'monsters.json').read_text())
    assert identity['executable_sha256'] == hashlib.sha256(executable.read_bytes()).hexdigest()
    assert identity['arguments_sha256'] == hashlib.sha256((profile/'arguments.json').read_bytes()).hexdigest()
    trace_path = Path((profile / 'trace.path').read_text().strip())
    info = json.loads(trace_path.read_text())
    casm = info['cairo_execution_info']['casm_level_info']
    trace = casm['vm_trace']
    funcs = {x['id']['id']: x['long_id'] for x in sierra['libfunc_declarations']}
    types = {x['id']['id']: x['long_id'] for x in sierra['type_declarations']}
    annotations = sierra['debug_info']['annotations']['github.com/software-mansion/cairo-profiler']['statements_functions']

    def typename(ident):
        ty = types[ident]
        user = next((a['UserType'].get('debug_name') for a in ty['generic_args'] if 'UserType' in a), None)
        if user:
            return user
        inner = [typename(a['Type']['id']) for a in ty['generic_args'] if 'Type' in a]
        return ty['generic_id'] + ('<' + ','.join(inner) + '>' if inner else '')

    offsets = [tuple(map(int, row.split())) for row in subprocess.check_output(
        [str(tool.resolve()), str(sierra_path.resolve())], text=True).splitlines() if row[0].isdigit()]
    by_statement = {i: (lo, hi) for i, lo, hi in offsets}
    ranges = sorted((i, lo, hi) for i, lo, hi in offsets if hi > lo)
    ranges.sort(key=lambda x: x[1])
    starts = [lo for _, lo, _ in ranges]
    candidates = [f['entry_point'] for f in sierra['funcs']
        if (stack := next((annotations[str(i)] for i in range(f['entry_point'], f['entry_point'] + 20) if str(i) in annotations), []))
        and stack[-1] == 'doom_run::step_tic_impl' and 'core::array::SpanImpl::pop_front' in stack]
    assert len(candidates) == 1, candidates
    code_offset = by_statement[candidates[0]][0]
    expected = T.frame_costs(info, code_offset, 1)
    entry = 1 + casm['program_offset'] + code_offset
    frames, active = [], []
    for index, row in enumerate(trace):
        while active and row['fp'] < frames[active[-1]]['fp']:
            frames[active.pop()]['end'] = index
        if row['pc'] == entry:
            frames.append(dict(start=index, fp=row['fp']))
            active.append(len(frames) - 1)
    assert not active and 1 <= len(frames) <= 2
    outer = frames[0]
    child = frames[1] if len(frames) == 2 else dict(start=outer['end'], end=outer['end'])
    costs, calls, by_owner, unmapped = Counter(), Counter(), Counter(), Counter()
    counted = 0
    for index in range(outer['start'], outer['end']):
        if child['start'] <= index < child['end']:
            continue
        counted += 1
        pc = trace[index]['pc'] - 1 - casm['program_offset']
        slot = bisect_right(starts, pc) - 1
        assert slot >= 0
        statement, lo, hi = ranges[slot]
        if not lo <= pc < hi:
            unmapped[pc] += 1
            continue
        invocation = sierra['statements'][statement].get('Invocation')
        if not invocation:
            continue
        fn = funcs[invocation['libfunc_id']['id']]
        kind = fn['generic_id']
        args = [typename(a['Type']['id']) for a in fn['generic_args'] if 'Type' in a]
        ty = ','.join(args)
        if 'doom_physics::mobj::Mobj' not in ty:
            continue
        key = kind + '<' + ty + '>'
        costs[key] += 1
        if pc == lo:
            calls[key] += 1
            if kind == 'into_box' and ty == 'doom_physics::mobj::Mobj':
                owner = next((f.split('::<')[0] for f in annotations.get(str(statement), []) if f.startswith('doom_')), 'unattributed')
                by_owner[owner] += 1
    assert [counted] == expected
    exe = sierra_path.with_name('step_tic.executable.json')
    return dict(executable_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
        arguments_sha256=hashlib.sha256((profile/'arguments.json').read_bytes()).hexdigest(),
        total_steps=info['used_execution_resources']['vm_resources']['n_steps'], tic_steps=counted,
        boundary_steps=info['used_execution_resources']['vm_resources']['n_steps']-counted,
        actor_instructions=dict(costs), actor_statement_executions=dict(calls),
        mobj_box_allocations_by_owner=dict(by_owner),
        outside_sierra_statements=dict(unmapped),
        allocation_limit='Nonempty into_box<Mobj> executions; no heap/RAM or AIR bound inferred.')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--sierra', type=Path, required=True)
    ap.add_argument('--profile-dir', type=Path, required=True)
    ap.add_argument('--tool', type=Path, required=True)
    ap.add_argument('--json', type=Path, required=True)
    args = ap.parse_args()
    result = inspect(args.sierra, args.profile_dir, args.tool)
    args.json.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Lossless flat VM attribution by Sierra libfunc and source stack, without recursion truncation."""
import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('trace', type=Path)
    ap.add_argument('sierra', type=Path)
    ap.add_argument('mapper', type=Path)
    ap.add_argument('output', type=Path)
    args = ap.parse_args()
    trace = json.loads(args.trace.read_text())
    si = json.loads(args.sierra.read_text())
    ranges = subprocess.check_output([str(args.mapper), str(args.sierra)], text=True, timeout=30)
    owner = {}
    for line in ranges.splitlines():
        fields = line.split()
        if fields[0] == 'TOTAL': continue
        index, start, end = map(int, fields)
        for pc in range(start, end):
            assert pc not in owner
            owner[pc] = index
    libfuncs = {r['id']['id']: r['long_id']['generic_id'] for r in si['libfunc_declarations']}
    stacks = si['debug_info']['annotations']['github.com/software-mansion/cairo-profiler']['statements_functions']
    vm = trace['cairo_execution_info']['casm_level_info']
    offset = 1 + vm['program_offset']
    lib, sources, detail = Counter(), Counter(), Counter()
    for row in vm['vm_trace']:
        statement = owner.get(row['pc']-offset)
        if statement is None:
            name, stack = 'executable_scaffolding', ['executable_scaffolding']
        else:
            st = si['statements'][statement]
            name = libfuncs[st['Invocation']['libfunc_id']['id']] if 'Invocation' in st else 'return'
            stack = stacks.get(str(statement), ['unannotated'])
        lib[name] += 1
        source = next((x for x in stack if x.startswith('s11_state_hash::hash9::')), stack[-1])
        sources[source] += 1
        detail[(source, name)] += 1
    steps = trace['used_execution_resources']['vm_resources']['n_steps']
    assert sum(lib.values()) == len(vm['vm_trace']) == steps
    result = dict(steps=steps, libfunc_steps=lib.most_common(), source_steps=sources.most_common(),
                  source_libfunc_steps=[dict(source=s, libfunc=l, steps=n) for (s,l),n in detail.most_common()],
                  note='Flat count of executed PCs mapped to Sierra CASM ranges; no recursive-stack depth cap. VM scaffolding is separate.')
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print('SOURCES', sources.most_common())
    print('LIBFUNCS', lib.most_common(24))


if __name__ == '__main__':
    main()

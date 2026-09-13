#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Count executed instructions by Sierra libfunc in a bounded function body.

Only PCs directly inside [entry, end) are counted: callees are excluded.
store_temp/local costs are also grouped by their actual Cairo type, which
distinguishes aggregate copying from arithmetic/lookup costs. Inputs must
come from the same compiled artifact; offsets are emitted by sierra_words.
"""
import argparse
import bisect
import collections
import json
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sierra', type=Path, required=True)
    ap.add_argument('--offsets', type=Path, required=True)
    ap.add_argument('--trace', type=Path, required=True)
    ap.add_argument('--entry', type=int, required=True)
    ap.add_argument('--end', type=int, required=True)
    ap.add_argument('--json', type=Path)
    args = ap.parse_args()
    sierra = json.loads(args.sierra.read_text())
    libfuncs = {x['id']['id']: x['long_id'] for x in sierra['libfunc_declarations']}
    types = {x['id']['id']: x['long_id'] for x in sierra['type_declarations']}
    def type_name(type_id):
        ty = types[type_id]
        name = next((a['UserType'].get('debug_name') for a in ty['generic_args'] if 'UserType' in a), None)
        if name: return name
        inner = [type_name(a['Type']['id']) for a in ty['generic_args'] if 'Type' in a]
        return ty['generic_id'] + ('<' + ','.join(inner) + '>' if inner else '')
    ranges = []
    for line in args.offsets.read_text().splitlines():
        values = line.split()
        if values and values[0].isdigit() and int(values[2]) > int(values[1]):
            ranges.append(tuple(map(int, values[:3])))
    ranges.sort(key=lambda row: row[1])
    starts = [row[1] for row in ranges]
    info = json.loads(args.trace.read_text())['cairo_execution_info']['casm_level_info']
    costs, copies = collections.Counter(), collections.Counter()
    for row in info['vm_trace']:
        pc = row['pc'] - info['program_offset'] - 1
        index = bisect.bisect_right(starts, pc) - 1
        if index < 0: continue
        statement, lo, hi = ranges[index]
        if not (lo <= pc < hi and args.entry <= statement < args.end): continue
        invocation = sierra['statements'][statement].get('Invocation')
        op = libfuncs[invocation['libfunc_id']['id']] if invocation else {'generic_id': 'Return'}
        costs[op['generic_id']] += 1
        if op['generic_id'] in ('store_temp', 'store_local'):
            copies[type_name(op['generic_args'][0]['Type']['id'])] += 1
    result = dict(entry=args.entry, end=args.end, direct_steps=sum(costs.values()),
                  libfuncs=costs.most_common(), copied_types=copies.most_common())
    print(json.dumps(result, indent=2))
    if args.json: args.json.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__': main()

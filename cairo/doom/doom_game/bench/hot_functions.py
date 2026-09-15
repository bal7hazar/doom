#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Attribute cairo-profiler pprof samples to a selected game call subtree.

No protobuf dependency is needed. Unknown generated function IDs are resolved
from the first Sierra statement annotation at their entry; they remain marked
as generated loops, never presented as separately measured source functions.
Flat costs are disjoint; cumulative costs overlap and must not be summed.
Build the pprof with --show-inlined-functions and a depth sufficient for
recursive roster loops (512 for the measured 210-slot game, not default 100).
"""
import argparse
import collections
import gzip
import json
import re
from pathlib import Path


def varint(data, pos):
    value = shift = 0
    while True:
        byte = data[pos]; pos += 1
        value |= (byte & 127) << shift
        if byte < 128: return value, pos
        shift += 7


def fields(data):
    result = collections.defaultdict(list)
    pos = 0
    while pos < len(data):
        tag, pos = varint(data, pos)
        kind = tag & 7
        if kind == 0: value, pos = varint(data, pos)
        elif kind == 2:
            length, pos = varint(data, pos)
            value = data[pos:pos + length]; pos += length
        elif kind in (1, 5):
            length = 8 if kind == 1 else 4
            value = data[pos:pos + length]; pos += length
        else: raise ValueError(f'unsupported protobuf wire type {kind}')
        result[tag >> 3].append(value)
    return result


def packed(items):
    result = []
    for item in items:
        if isinstance(item, int): result.append(item); continue
        pos = 0
        while pos < len(item):
            value, pos = varint(item, pos); result.append(value)
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('profile', type=Path)
    ap.add_argument('--sierra', type=Path, required=True)
    ap.add_argument('--focus', default='doom_monsters::think::monsters_ticker')
    ap.add_argument('--limit', type=int, default=20)
    ap.add_argument('--json', type=Path)
    args = ap.parse_args()
    sierra = json.loads(args.sierra.read_text())
    annotations = sierra['debug_info']['annotations']['github.com/software-mansion/cairo-profiler']['statements_functions']
    aliases = {}
    for function in sierra['funcs']:
        entry = function['entry_point']
        stack = next((annotations[str(i)] for i in range(entry, entry + 20) if str(i) in annotations), [])
        if stack: aliases[f"[{function['id']['id']}]"] = stack[-1] + f'::<generated@{entry}>'
    profile = fields(gzip.decompress(args.profile.read_bytes()))
    strings = [s.decode() for s in profile[6]]
    types = [strings[fields(v)[1][0]] for v in profile[1]]
    sample_index = types.index('steps')
    functions = {}
    for raw in profile[5]:
        function = fields(raw)
        name = strings[function[2][0]]
        functions[function[1][0]] = aliases.get(name, name)
    locations = {}
    for raw in profile[4]:
        location = fields(raw)
        locations[location[1][0]] = [functions[fields(line)[1][0]] for line in location[4]]
    flat, cumulative, owners = (collections.Counter() for _ in range(3))
    selected = total = max_selected_frames = 0
    for raw in profile[2]:
        sample = fields(raw)
        steps = packed(sample[2])[sample_index]
        total += steps
        stack = [name for loc in packed(sample[1]) for name in locations[loc]]
        if not any(re.search(args.focus, name) for name in stack): continue
        max_selected_frames = max(max_selected_frames, len(packed(sample[1])))
        selected += steps
        flat[stack[0]] += steps
        for name in set(stack): cumulative[name] += steps
        owner = next((name for name in stack if name.startswith('doom_')), stack[0])
        owners[owner] += steps
    if not selected: raise ValueError(f'no step samples matched focus {args.focus}')
    result = dict(profile=str(args.profile), focus=args.focus, total_steps=total,
        selected_steps=selected, max_selected_frames=max_selected_frames,
        flat=flat.most_common(), cumulative=cumulative.most_common(),
        game_owner=owners.most_common())
    if args.json: args.json.write_text(json.dumps(result, indent=2) + '\n')
    print(f'Selected {selected} / {total} steps; focus={args.focus}')
    for label, values in [('Flat', flat), ('Cumulative (overlap)', cumulative), ('First game owner (disjoint)', owners)]:
        print('\n' + label)
        for name, steps in values.most_common(args.limit): print(f'{steps:9d} {name}')


if __name__ == '__main__': main()

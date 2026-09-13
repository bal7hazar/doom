#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Compare every output felt of five real replays and serialized cuts.

The reference target directory contains immutable executables in dev/ and
proving/. Scarb executes both with --no-build; it never regenerates goldens.
The smaller SimProgram comparison in ../bench_boundary/measure.py separately
checks the actual cairo-lang 2.19.4 executable ABI, including malformed input.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('game_replay', HERE.parent / 'bench/profile.py')
P = importlib.util.module_from_spec(spec)
spec.loader.exec_module(P)


def digest(values):
    return hashlib.sha256(' '.join(hex(x) for x in values).encode()).hexdigest()


def packed(state, words):
    return [len(state), *state, len(words), *words]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--reference', type=Path, required=True)
    ap.add_argument('--profile', choices=['dev', 'proving'], required=True)
    ap.add_argument('--json', type=Path, required=True)
    args = ap.parse_args()
    P.PROFILE = args.profile
    P.NATIVE_RUNNER = None
    current = P.WORKSPACE / 'target'
    rows = []

    def call(target, name, values):
        os.environ['SCARB_TARGET_DIR'] = str(target.resolve())
        return P.execute(name, values)

    def compare(label, name, values):
        a, ra = call(args.reference, name, values)
        b, rb = call(current, name, values)
        if a != b:
            index = next((i for i, pair in enumerate(zip(a, b)) if pair[0] != pair[1]), min(len(a), len(b)))
            raise AssertionError(f'{label}: output differs at felt {index}')
        rows.append(dict(case=label, executable=name, before_steps=ra['steps'], after_steps=rb['steps'],
                         output_felts=len(b), output_sha256=digest(b)))
        print(f'{label}: {ra["steps"]} -> {rb["steps"]}; {len(b)} equal felts', flush=True)
        return b

    initial = compare('genesis', 'genesis', [0])
    state0 = initial[1:1 + initial[0]]
    for count in [0, 1, 4]:
        words = [P.word(25, 0, 0, 0)] * count
        compare(f'call_{count}', 'step_tic', packed(state0, words))
        compare(f'segment_{count}', 'run_segment', [*packed(state0, words), 0, count])
    for name, log in P.LOGS.items():
        words = log()
        whole = compare(name + ':whole', 'step_tic', packed(state0, words))
        compare(name + ':D14', 'run_segment', [*packed(state0, words), 0, len(words)])
        state, offset, index = state0, 0, 0
        while offset < len(words):
            size = [29, 113, 47][index % 3]
            part = words[offset:offset + size]
            out = compare(f'{name}:cut{index}', 'step_tic', packed(state, part))
            state = out[2:2 + out[1]]
            offset += len(part)
            index += 1
            if out[0] != 0:
                break
        assert out == whole, f'{name}: serialized cuts diverge from whole replay'
        compare(name + ':end_boundary', 'step_tic', packed(state, []))
    identity = {}
    for label, target in [('reference', args.reference), ('current', current)]:
        identity[label] = {}
        for name in ['genesis', 'step_tic', 'run_segment']:
            path = target / args.profile / (name + '.executable.json')
            data = path.read_bytes()
            identity[label][name] = dict(sha256=hashlib.sha256(data).hexdigest(),
                                        words=len(json.loads(data)['program']['bytecode']))
    args.json.write_text(json.dumps(dict(profile=args.profile, identity=identity, cases=rows,
                                        exact_felt_equivalence=True, cuts_equivalent=True), indent=2) + '\n')


if __name__ == '__main__':
    main()

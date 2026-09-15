#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Compare real E1M1 game outputs and raw monster-pass outputs, felt for felt.

--reference is a preserved Cairo workspace containing the baseline doom_run
executables and an identical copy of ticker_probe built against that baseline.
No expected hash, fixture or budget is regenerated. Whole replay outputs must
also equal replay outputs resumed from serialized states every --chunk tics.
The raw probe exposes all Mobj/RNG/defense/event/grid fields on each of those
real boundary states; it does not claim to expose step_tic's internal cues.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[2]
spec = importlib.util.spec_from_file_location('game_replay_logs', HERE.parents[1] / 'doom_game/bench/profile.py')
LOGS = importlib.util.module_from_spec(spec)
spec.loader.exec_module(LOGS)
PRIME = (1 << 251) + 17 * (1 << 192) + 1


def digest(values):
    return hashlib.sha256(' '.join(hex(v) for v in values).encode()).hexdigest()


class Runner:
    def __init__(self, workspace, profile):
        self.workspace, self.profile = workspace.resolve(), profile

    def execute(self, name, arguments):
        manifest = self.workspace / 'Scarb.toml'
        package = 'doom_run'
        if name == 'ticker':
            manifest = self.workspace / 'doom/doom_monsters/bench/ticker_probe/Scarb.toml'
            package = 'monster_ticker_probe'
        with tempfile.NamedTemporaryFile('w', suffix='.json') as f:
            json.dump([hex(v) for v in arguments], f)
            f.flush()
            result = subprocess.run([
                'scarb', '--manifest-path', str(manifest), '--profile', self.profile,
                'execute', '-p', package, '--executable-name', name, '--no-build',
                '--arguments-file', f.name, '--print-program-output', '--print-resource-usage',
            ], capture_output=True, text=True, env=dict(os.environ, ASDF_SCARB_VERSION='2.16.0'))
        if result.returncode:
            raise RuntimeError(result.stdout[-3000:] + result.stderr[-3000:])
        values, output = [], False
        for line in result.stdout.splitlines():
            if line.startswith('Program output:'):
                output = True
                continue
            if line.startswith('Resources:'):
                output = False
            if output and line.strip():
                values.append(int(line.strip(), 0) % PRIME)
        steps = int(re.search(r'^\s*steps:\s*([0-9,]+)', result.stdout, re.M)[1].replace(',', ''))
        return values, steps

    def identity(self):
        paths = [self.workspace / f'target/{self.profile}/{name}.executable.json'
                 for name in ('genesis', 'step_tic', 'run_segment')]
        paths.append(self.workspace / f'doom/doom_monsters/bench/ticker_probe/target/{self.profile}/ticker.executable.json')
        return {p.name: {'sha256': hashlib.sha256(p.read_bytes()).hexdigest(),
                         'words': len(json.loads(p.read_text())['program']['bytecode'])} for p in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--current', type=Path, default=WORKSPACE)
    parser.add_argument('--profile', choices=('dev', 'proving'), default='proving')
    parser.add_argument('--chunk', type=int, default=25)
    parser.add_argument('--scenario', action='append', choices=sorted(LOGS.LOGS))
    parser.add_argument('--json', type=Path, required=True)
    args = parser.parse_args()
    if args.chunk <= 0:
        parser.error('--chunk must be positive')
    before, after = Runner(args.reference, args.profile), Runner(args.current, args.profile)
    report = {'profile': args.profile, 'reference': before.identity(), 'current': after.identity(),
              'chunk_tics': args.chunk, 'cases': [], 'scenarios': []}

    def compare(label, name, arguments):
        a, a_steps = before.execute(name, arguments)
        b, b_steps = after.execute(name, arguments)
        if a != b:
            mismatch = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
            raise AssertionError(f'{label}: {name} differs at output felt {mismatch}')
        report['cases'].append({'case': label, 'entry': name, 'felts': len(a),
            'sha256': digest(a), 'before_steps': a_steps, 'after_steps': b_steps})
        return a

    def packed(state, commands):
        return [len(state), *state, len(commands), *commands]

    genesis = compare('genesis', 'genesis', [0])
    start = genesis[1:1 + genesis[0]]
    for name in args.scenario or sorted(LOGS.LOGS):
        words = LOGS.LOGS[name]()
        whole = compare(name + '/whole', 'step_tic', packed(start, words))
        state, cuts, events = start, 0, 0
        while state[4] < len(words):
            tic = state[4]
            raw = compare(f'{name}/ticker/{tic}', 'ticker', [len(state), *state])
            # Array ABI length, six defense/RNG words, mobj count, 27 words per mobj.
            count = raw[7]
            events += raw[8 + count * 27]
            out = compare(f'{name}/cut/{tic}', 'step_tic', packed(state, words[tic:tic + args.chunk]))
            state = out[2:2 + out[1]]
            cuts += 1
            if out[0]:
                break
        if out != whole:
            raise AssertionError(f'{name}: whole replay and serialized cuts differ')
        # Hash and segment output ABI also agree after every complete scenario.
        compare(name + '/final_segment', 'run_segment', [*packed(state, []), state[4], 0])
        row = {'name': name, 'tics': state[4], 'status': out[0], 'cuts': cuts,
               'raw_probe_events': events, 'final_output_sha256': digest(out)}
        report['scenarios'].append(row)
        args.json.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(row), flush=True)
    report['exact_felt_equivalence'] = True
    report['serialized_cuts_equal_whole'] = True
    args.json.write_text(json.dumps(report, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

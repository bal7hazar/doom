#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Real executable ABI/steps comparison, with opaque runtime inputs.

SIM_PROBE must name the line-oriented SimProgram runner from
../doom_run/bench/sim_probe.rs. --reference contains preserved baseline
executables; no expected state or hash is generated or updated here.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def word(forward=0, side=0, turn=0, buttons=0):
    return (forward + 128) | ((side + 128) << 8) | ((turn // 256 + 128) << 16) | (buttons << 24)


def packed(state, words):
    return [len(state), *state, len(words), *words]


def digest(values):
    return hashlib.sha256(' '.join(hex(x) for x in values).encode()).hexdigest()


class Runner:
    def __init__(self, root, probe):
        self.root, self.probe, self.processes = root, probe, {}

    def call(self, name, arguments):
        if name not in self.processes:
            self.processes[name] = subprocess.Popen(
                [self.probe, str(self.root / f'{name}.executable.json')],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
        p = self.processes[name]
        p.stdin.write(' '.join(hex(x) for x in arguments) + '\n')
        p.stdin.flush()
        line = p.stdout.readline()
        if not line:
            raise RuntimeError(f'{name}: runner stopped: {p.stderr.read()}')
        values = line.split()
        return int(values[0]), [int(x, 16) for x in values[1:]]

    def close(self):
        for p in self.processes.values():
            p.stdin.close()
            p.wait(timeout=10)

    def identity(self):
        return {
            name: {
                'executable_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                'bytecode_words': len(json.loads(path.read_text())['program']['bytecode']),
            }
            for name in ['genesis', 'step_tic', 'run_segment']
            for path in [self.root / f'{name}.executable.json']
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executables', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--json', type=Path)
    args = parser.parse_args()
    probe = os.environ.get('SIM_PROBE')
    if not probe:
        parser.error('SIM_PROBE must name the compiled line-oriented SimProgram runner')
    before, after = Runner(args.reference.resolve(), probe), Runner(args.executables.resolve(), probe)
    rows = []

    def compare(label, name, values):
        a_steps, a = before.call(name, values)
        b_steps, b = after.call(name, values)
        if a != b:
            mismatch = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
            raise AssertionError(f'{label}: ABI output differs at felt {mismatch}')
        rows.append(dict(case=label, before_steps=a_steps, after_steps=b_steps,
                         output_felts=len(b), output_sha256=digest(b)))
        return b

    try:
        genesis = compare('genesis', 'genesis', [0])
        compare('unknown_level', 'genesis', [7])
        n = genesis[0]
        state = genesis[1:n + 1]
        assert len(genesis) == n + 2, 'state length and one hash'
        for label, words in [('empty', []), ('idle', [word()]), ('walk', [word(25)]),
                             ('four_walk', [word(25)] * 4)]:
            compare(label, 'step_tic', packed(state, words))
            compare('segment_' + label, 'run_segment', [*packed(state, words), 0, 100])
        for status in [1, 2, 3]:
            terminal = state.copy()
            terminal[5] = status
            compare(f'terminal_{status}_empty', 'step_tic', packed(terminal, []))
            compare(f'terminal_{status}_word', 'step_tic', packed(terminal, [word()]))
            compare(f'segment_terminal_{status}', 'run_segment', [*packed(terminal, [word()]), 0, 100])
        damaged = state.copy()
        damaged[48] = 1 << 33
        for label, malformed in [('empty_state', []), ('wrong_tag', [0, *state[1:]]),
                                 ('truncated', state[:-1]), ('trailing', [*state, 0]),
                                 ('fixed_domain', damaged)]:
            out = compare(label, 'step_tic', packed(malformed, [word()]))
            assert out == [3, 0, 0], f'{label}: ABORT with empty arrays'
            compare('segment_' + label, 'run_segment', [*packed(malformed, [word()]), 0, 100])
        compare('wrong_tic', 'run_segment', [*packed(state, [word()]), 1, 100])
        # Compare real serialized cuts, not a subtraction of two averages.
        whole = compare('cut_whole', 'step_tic', packed(state, [word(25)] * 4))
        current = state
        for i in range(4):
            out = compare(f'cut_{i + 1}', 'step_tic', packed(current, [word(25)]))
            current = out[2:2 + out[1]]
        assert out == whole, 'four serialized cuts produce exactly the grouped output'
        malformed_abi = [
            ('state_length', 'step_tic', [1]),
            ('u32_length', 'step_tic', [1 << 32]),
            ('word_length', 'step_tic', [0, 2, 1]),
            ('tic_domain', 'run_segment', [0, 0, 1 << 32, 0]),
        ]
        for label, executable, values in malformed_abi:
            for runner in [before, after]:
                result = subprocess.run(
                    [probe, str(runner.root / f'{executable}.executable.json')],
                    input=' '.join(hex(x) for x in values) + '\n',
                    capture_output=True, text=True, timeout=30,
                )
                assert result.returncode != 0, f'{label}: invalid executable ABI was accepted'
        report = dict(reference=before.identity(), current=after.identity(), cases=rows,
                      exact_felt_equivalence=True, cuts_equivalent=True,
                      malformed_abi_rejected=[case[0] for case in malformed_abi])
        result = json.dumps(report, indent=2) + '\n'
        if args.json:
            args.json.write_text(result)
        print(result)
    finally:
        before.close()
        after.close()


if __name__ == '__main__':
    main()

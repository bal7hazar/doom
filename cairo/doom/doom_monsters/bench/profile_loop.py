#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Profile one real game tic with a complete monster call subtree.

Build doom_run with its profiler annotations first. --arguments can reuse an
identical pre-tic state across revisions; otherwise derive it from a golden
replay. A depth of 512 is required: 100 truncates Cairo's recursive loop
frames and undercounts the 210-slot E1M1 ticker.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
GAME_BENCH = HERE.parents[1] / 'doom_game/bench'
spec = importlib.util.spec_from_file_location('monster_profile_game', GAME_BENCH / 'profile.py')
P = importlib.util.module_from_spec(spec)
spec.loader.exec_module(P)
P.NATIVE_RUNNER = None  # This harness measures and prepares inputs with Scarb.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scenario', choices=sorted(P.LOGS), default='idle')
    parser.add_argument('--tic', type=int, default=300)
    parser.add_argument('--arguments', type=Path)
    parser.add_argument('--profiler', default='cairo-profiler')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--keep-trace', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    if args.arguments:
        arguments = json.loads(args.arguments.read_text())
    else:
        commands = P.LOGS[args.scenario]()
        if not 0 <= args.tic < len(commands):
            parser.error('--tic must name a tic in the replay')
        _, state, _ = P.step(P.genesis_state(), commands[:args.tic])
        if state[4] != args.tic or state[5]:
            parser.error('the replay terminates before this tic')
        arguments = [hex(v) for v in [len(state), *state, 1, commands[args.tic]]]
    argument_file = args.out / 'arguments.json'
    argument_file.write_text(json.dumps(arguments) + '\n')
    result = P.scarb(['execute', '-p', 'doom_run', '--executable-name', 'step_tic', '--no-build',
        '--arguments-file', str(argument_file.resolve()), '--print-program-output',
        '--print-resource-usage', '--save-profiler-trace-data'])
    (args.out / 'execute.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(result.stdout[-2000:] + result.stderr[-2000:])
    trace = Path(re.search(r'Saving profiler trace data to: (.+)', result.stdout)[1])
    pb = args.out / 'profile.pb.gz'
    subprocess.run([args.profiler, str(trace), '--show-inlined-functions',
        '--max-function-stack-trace-depth', '512', '-o', str(pb)], check=True)
    sierra = P.WORKSPACE / 'target' / P.PROFILE / 'step_tic.executable.sierra.json'
    report_file = args.out / 'monsters.json'
    subprocess.run([sys.executable, str(GAME_BENCH / 'hot_functions.py'), str(pb), '--sierra',
        str(sierra), '--focus', 'doom_monsters', '--json', str(report_file)], check=True)
    report = json.loads(report_file.read_text())
    if report['max_selected_frames'] >= 512:
        raise RuntimeError('profile stack depth may be truncated')
    executable = sierra.with_name('step_tic.executable.json')
    report.update(executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
        arguments_sha256=hashlib.sha256(argument_file.read_bytes()).hexdigest(),
        build_profile=P.PROFILE, max_stack_depth=512)
    report_file.write_text(json.dumps(report, indent=2) + '\n')
    if args.keep_trace:
        (args.out / 'trace.path').write_text(str(trace) + '\n')
    else:
        trace.unlink()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Attribute consumer code and its core helpers without rebuilding anything.

Sierra must include statements-functions annotations. --tool is the pinned
infra/sierra_words executable; --executable counts the complete program,
including shared constant arrays and executable framing. Inlining stacks
are inner-first. Core helpers reached from another crate remain that
crate's consumer cost; they are not all charged to doom_game/doom_run.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess


def clean(name):
    name = re.sub(r'\{.*\}$', '', name)
    name = re.sub(r'::<.*>', '', name)
    return re.sub(r'\[\d+-\d+\]', '', name)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--sierra', type=Path, required=True)
    ap.add_argument('--executable', type=Path, required=True)
    ap.add_argument('--tool', type=Path, required=True)
    ap.add_argument('--json', type=Path, required=True)
    args = ap.parse_args()
    s = json.loads(args.sierra.read_text())
    annotations = s['debug_info']['annotations']['github.com/software-mansion/cairo-profiler']['statements_functions']
    source, core_callers, core_functions, game_callers = Counter(), Counter(), Counter(), Counter()
    code = 0
    for line in subprocess.check_output([str(args.tool.resolve()), str(args.sierra.resolve())], text=True).splitlines():
        if line.startswith('TOTAL'):
            continue
        index, start, end = map(int, line.split())
        words = end - start
        code += words
        stack = [clean(x) for x in annotations.get(str(index), [])]
        inner = stack[0] if stack else 'unattributed'
        source[inner.split('::')[0]] += words
        game = next((f for f in stack if f.startswith(('doom_game::', 'doom_run::'))), None)
        if game:
            game_callers[game] += words
        if inner.startswith('core::') and game:
            core_functions[inner] += words
            core_callers[game] += words
    total = len(json.loads(args.executable.read_text())['program']['bytecode'])
    report = dict(total_words=total, code_words=code, constant_arrays_and_framing=total-code,
                  innermost_source=dict(source.most_common()), core_in_game_run=sum(core_callers.values()),
                  core_callers=dict(core_callers.most_common()), core_functions=dict(core_functions.most_common()),
                  game_callers=dict(game_callers.most_common()))
    args.json.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k not in ['game_callers', 'core_functions', 'core_callers']}, indent=2))


if __name__ == '__main__':
    main()

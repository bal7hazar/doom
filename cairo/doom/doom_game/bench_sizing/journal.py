#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Measure the unchanged journal's growth without hiding its construction cost."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--json', type=Path, required=True)
    args = ap.parse_args()
    manifest = Path(__file__).resolve().parent / 'journal/Scarb.toml'
    env = dict(os.environ, ASDF_SCARB_VERSION='2.16.0')
    prefix = ['scarb', '--manifest-path', str(manifest), '--profile', 'proving']
    subprocess.run([*prefix, 'build'], env=env, check=True)
    rows, expected = [], None
    for count in [0, 64, 1000, 10000]:
        runs = []
        for include_hash in [0, 1]:
            result = subprocess.run([*prefix, 'execute', '--no-build', '--output', 'none',
                '--print-program-output', '--print-resource-usage', '--arguments', f'{count},{include_hash}'],
                env=env, capture_output=True, text=True, check=True)
            steps = int(re.search(r'^\s*steps:\s*([\d,]+)', result.stdout, re.M)[1].replace(',', ''))
            value = int(re.search(r'Program output:\s*(-?(?:0x[\da-f]+|\d+))', result.stdout)[1], 0)
            runs.append(steps)
            if include_hash:
                if expected is None:
                    expected = value
                assert value == expected, 'history must not change committed state'
        row = dict(unlink_link_pairs=count, construction_steps=runs[0], full_steps=runs[1],
                   boundary_hash_steps=runs[1]-runs[0])
        rows.append(row)
        print(row, flush=True)
    args.json.write_text(json.dumps(dict(cases=rows, all_hashes_equal=True,
                                        hash=str(expected)), indent=2) + '\n')


if __name__ == '__main__':
    main()

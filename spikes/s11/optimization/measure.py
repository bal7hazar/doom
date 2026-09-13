#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Measure a bounded S11 variant against the exact outputs of the frozen initial campaign."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vectors import P, vectors


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2)+'\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--programs', type=Path, required=True)
    ap.add_argument('--baseline-measurement', type=Path, required=True)
    ap.add_argument('--runner', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--full', action='store_true')
    args = ap.parse_args()
    source = Path(__file__).resolve().parents[1]/'src/hash9.cairo'
    if source.stat().st_mtime > (args.programs/'hash_blake9.executable.json').stat().st_mtime:
        raise RuntimeError('hash9 source is newer than its executable: rebuild successfully first')
    args.output.mkdir(parents=True, exist_ok=False)
    programs = {}
    for path in args.programs.glob('*.executable.json'):
        programs[path.name.split('.')[0]] = dict(sha256=sha(path),
            bytecode_words=len(json.loads(path.read_text())['program']['bytecode']))
        shutil.copy2(path, args.output/path.name)
    shutil.copy2(Path(__file__).resolve().parents[1]/'src/hash9.cairo', args.output/'hash9.cairo')
    rows = []

    def run(program, name, flat, expected, before=None):
        t = time.monotonic()
        path = args.output/(program+'.executable.json')
        p = subprocess.run([str(args.runner), str(path)], input=' '.join(hex(x) for x in flat)+'\n',
                           capture_output=True, text=True, timeout=120,
                           env=dict(os.environ, RAYON_NUM_THREADS='2'))
        p.check_returncode()
        fields = p.stdout.split()
        output = [int(x, 0) for x in fields[1:]]
        assert output == expected, (program, name, 'complete output mismatch')
        row = dict(program=program, name=name, steps=int(fields[0]), before_steps=before,
                   wall_ms=round((time.monotonic()-t)*1000, 3),
                   output_felts=len(output), output_sha256_le32=hashlib.sha256(b''.join(
                       x.to_bytes(32,'little') for x in output)).hexdigest())
        rows.append(row)
        print(name, program, row['steps'], 'before', before, flush=True)

    for v in vectors():
        flat = [int(x,0) for x in v['values']]
        run('vector_blake9', 'vector_'+v['name'], [len(flat),*flat],
            [1,*v['digestWords'],int(v['fieldHex'],0)])
    for x in (2**72, P-1):
        run('vector_blake9', 'domain_'+str(x), [1,x], [0]*10)
        run('hash_blake9', 'domain_option_'+str(x), [1,x], [1])
    native = json.loads((args.baseline_measurement/'native.json').read_text())
    pairs = [('genesis_hash_only', 'hash_blake9')]
    names = [c['name'] for c in native['cases']] if args.full else ['empty','walk4']
    for name in names:
        pairs.extend((name, p) for p in ('segment_blake9','inspect_blake9'))
    if args.full:
        pairs.append(('genesis','genesis_blake9'))
    for name, program in pairs:
        old = json.loads((args.baseline_measurement/'native'/f'{name}.{program}.json').read_text())
        flat, expected = [[int(x,0) for x in old[k]] for k in ('args','output')]
        run(program, name, flat, expected, old['steps'])
    save(args.output/'measurements.json', dict(programs=programs, calls=rows, full=args.full,
        baseline='4936c233e2ea9cf7a7b34312b522f7b96c8bf9fb',
        same_complete_outputs=True, proof_generated=False))


if __name__ == '__main__': main()

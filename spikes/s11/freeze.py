#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Freeze the already built S11/D33 executables and AIR-complete WASM without overwriting a reference."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE = 'f306c6afa3af652d1c91e579d940d7af94d57cbd'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--executables', type=Path, required=True)
    ap.add_argument('--production', type=Path, required=True)
    ap.add_argument('--wasm-pkg', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    changed = subprocess.check_output(['git', 'diff', BASE, '--', 'cairo'], cwd=ROOT, text=True)
    assert not changed, 'Cairo source must remain at the D33 reference; do not combine D29'
    expected = json.loads((HERE/'results.json').read_text())['native']['executables']
    sources = list(args.executables.glob('*.executable.json'))
    assert len(sources) == 9
    manifest = dict(base=BASE, source_commit=subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), source={}, executables={}, wasm={})
    copies = [(p, 'proving', p.name.split('.')[0]) for p in sources]
    copies.extend((args.production/(name+'.executable.json'), 'production', 'production_'+name)
                  for name in ('run_segment', 'step_tic', 'genesis'))
    for path, _, name in copies:
        rec = dict(sha256=sha(path), bytecode_words=len(json.loads(path.read_text())['program']['bytecode']))
        assert rec == expected[name], f'{name}: executable differs from the measured reference'
        manifest['executables'][name] = rec
    args.output.mkdir(parents=True, exist_ok=False)
    for path, directory, _ in copies:
        dest = args.output/directory/path.name
        dest.parent.mkdir(exist_ok=True)
        shutil.copy2(path, dest)
    for pattern in ('*.py', '*.mjs', '*.md', 'Scarb.toml', 'Scarb.lock', 'vectors.json', 'src/*.cairo'):
        for path in HERE.glob(pattern):
            rel = path.relative_to(HERE)
            dest = args.output/'source'/rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
            manifest['source']['spikes/s11/'+str(rel)] = sha(path)
    for sub in ('dist', 'wasm'):
        shutil.copytree(args.wasm_pkg/sub, args.output/'wasm/pkg'/sub)
    shutil.copy2(args.wasm_pkg/'package.json', args.output/'wasm/pkg/package.json')
    for path in (args.wasm_pkg/'wasm').glob('*.wasm'):
        manifest['wasm'][path.name] = dict(sha256=sha(path), bytes=path.stat().st_size)
    (args.output/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print('Frozen 12 executable JSONs and WASM provenance:', args.output)


if __name__ == '__main__':
    main()

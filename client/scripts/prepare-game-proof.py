#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Bal7hazar
# SPDX-License-Identifier: Apache-2.0
"""Stage the pinned D29 preparation executables and R5 simulator; never build anything."""
import argparse
import hashlib
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--target', type=Path, required=True, help='existing Cairo target directory with proving executables')
p.add_argument('--sim', type=Path, required=True, help='existing prover/sim/pkg directory')
p.add_argument('--out', type=Path, default=HERE.parent / 'public/prover/game-proof')
a = p.parse_args()
pins = dict(re.findall(r'(genesis|step|segment|wasm|glue|snippet): "([0-9a-f]{64})"', (HERE.parent / 'src/prove/doomArtifacts.ts').read_text()))
files = {'genesis': ('genesis.json', a.target / 'proving/genesis.executable.json'),
         'step': ('step.json', a.target / 'proving/step_tic.executable.json'),
         'segment': ('segment.json', a.target / 'proving/run_segment.executable.json'),
         'wasm': ('hellproof_sim_bg.wasm', a.sim / 'hellproof_sim_bg.wasm'),
         'glue': ('hellproof_sim.js', a.sim / 'hellproof_sim.js'),
         'snippet': ('inline0.js', a.sim / 'snippets/hellproof-sim-c1c84871eb3c9493/inline0.js')}
checked = []
for key, (name, source) in files.items():
    data = source.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != pins.get(key):
        raise SystemExit(f'{source}: SHA256 mismatch; expected {pins.get(key)}, got {actual}')
    checked.append((name, data, actual))
a.out.mkdir(parents=True, exist_ok=True)
for name, data, actual in checked:
    (a.out / name).write_bytes(data)
    print(f'{actual}  {a.out / name}')

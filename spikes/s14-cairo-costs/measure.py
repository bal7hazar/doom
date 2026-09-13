#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Hellproof contributors
# SPDX-License-Identifier: Apache-2.0
"""Opaque single-call costs, complete executable sizes, and Python integer oracle."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
RESOURCE = re.compile(r'^\s*([a-z_0-9 ]+):\s*([0-9,]+)\s*$')
CASES = [0, 1, 63, 64, 255, 256, 257, 4095, 4096, 4160, 2**32-1, 2**64-1, 2**128-1]
ORACLES = {
    'mod_operator': lambda x: [x % 256, 0],
    'mod_nonzero': lambda x: [x % 256, 0],
    'mask_byte': lambda x: [x & 255, 0],
    'pair_operator': lambda x: list(divmod(x, 256)),
    'pair_nonzero': lambda x: list(divmod(x, 256)),
    'sparse_mask': lambda x: [x & 0x1040, 0],
    'sparse_arithmetic': lambda x: [x & 0x1040, 0],
}

def trig_oracle(angle):
    radians = ((angle // 524288) + 0.5) * 2 * math.pi / 8192
    return [2**32 + int(math.sin(radians)*65536), 2**32 + int(math.cos(radians)*65536)]

ORACLES.update(sin_cos_reference=trig_oracle, sin_cos_shared=trig_oracle)
ANGLE_CASES = sorted(set([0, 1, 524287, 524288, 123456789, 0x2abcdef0, 2**32-1] +
    [q*2**30+d for q in [1, 2, 3] for d in [-1, 0, 1, 524287]]))

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args(); args.out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, ASDF_SCARB_VERSION='2.16.0', RAYON_NUM_THREADS='1', CARGO_BUILD_JOBS='1')
    result = {}
    for profile in ['dev', 'proving']:
        prefix = ['scarb', '--manifest-path', str(HERE/'Scarb.toml'), '--profile', profile]
        build = subprocess.run(prefix+['build'], capture_output=True, text=True, env=env, timeout=600)
        (args.out/f'{profile}-build.log').write_text(build.stdout+build.stderr)
        assert build.returncode == 0, build.stderr
        result[profile] = {}
        for name, oracle in ORACLES.items():
            program = json.loads((HERE/'target'/profile/f'{name}.executable.json').read_text())
            entry = {'words': len(program['program']['bytecode']), 'cases': []}
            for x in (ANGLE_CASES if name.startswith('sin_cos') else CASES):
                call = subprocess.run(prefix+['execute','--no-build','--executable-name',name,'--print-program-output','--print-resource-usage','--arguments',str(x)],capture_output=True,text=True,env=env,timeout=120)
                (args.out/f'{profile}-{name}-{x}.log').write_text(call.stdout+call.stderr)
                assert call.returncode == 0, call.stderr
                values = []; resources = {}; active = False
                for line in call.stdout.splitlines():
                    if line.startswith('Program output:'): active=True; continue
                    if line.startswith('Resources:'): active=False; continue
                    match = RESOURCE.match(line)
                    if match:
                        resources[match[1].strip()] = int(match[2].replace(',','')); active=False
                    elif active and line.strip(): values.append(int(line.strip(),0))
                assert values == oracle(x), (name,x,values,oracle(x))
                entry['cases'].append({'input':str(x),'output':[str(v) for v in values],'resources':resources})
            result[profile][name] = entry
            print(profile,name,entry['words'],entry['cases'][0]['resources'],flush=True)
    (args.out/'result.json').write_text(json.dumps(result,indent=2)+'\n')

if __name__ == '__main__': main()

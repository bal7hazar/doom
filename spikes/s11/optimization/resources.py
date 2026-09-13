#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded AIR-complete before/after S11 resource calls. Never prove."""
import argparse
import json
from pathlib import Path
import subprocess


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline-programs', type=Path, required=True)
    ap.add_argument('--candidate-programs', type=Path, required=True)
    ap.add_argument('--baseline-measurement', type=Path, required=True)
    ap.add_argument('--core', type=Path, required=True)
    ap.add_argument('--node', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    rows = []
    for variant, directory in [('before', args.baseline_programs), ('after', args.candidate_programs)]:
        for name, program in [('genesis_hash_only','hash_blake9'), ('empty','segment_blake9'), ('walk4','segment_blake9')]:
            old = json.loads((args.baseline_measurement/'native'/f'{name}.{program}.json').read_text())
            job = dict(name=name, program=program, args=old['args'], expected=old['output'])
            job_path = args.output/f'{variant}.{name}.job.json'
            out_path = args.output/f'{variant}.{name}.json'
            job_path.write_text(json.dumps(job)+'\n')
            p = subprocess.run([str(args.node), str(Path(__file__).resolve().parents[1]/'resources.mjs'),
                '--one', str(args.core), str(directory/(program+'.executable.json')), str(job_path), str(out_path)],
                capture_output=True, text=True, timeout=120)
            if p.returncode: raise RuntimeError(p.stderr[-4000:])
            row = json.loads(out_path.read_text())
            assert row['variable_component_types'] == 43
            row['variant'] = variant
            rows.append(row)
            print(variant, name, row['execution']['n_steps'], row['resources']['max_component'],
                  row['resources']['log_max_component_size'], flush=True)
    (args.output/'all.json').write_text(json.dumps(rows,indent=2)+'\n')


if __name__ == '__main__': main()

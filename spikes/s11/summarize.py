#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Produce the light S11 measurement artifact from the full local execution logs."""
import argparse
import hashlib
import json
from pathlib import Path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def felts_sha(values):
    return hashlib.sha256(b''.join(int(v, 0).to_bytes(32, 'little') for v in values)).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('measurement', type=Path)
    ap.add_argument('reference', type=Path)
    ap.add_argument('output', type=Path)
    args = ap.parse_args()
    native = json.loads((args.measurement/'native.json').read_text())
    resources = json.loads((args.measurement/'resources.json').read_text())
    assert len(resources) == native['resource_jobs']
    assert all(r['variable_component_types'] == 43 and r['native_task_output_equal'] for r in resources)
    rows = []
    for resource in resources:
        entry = dict(resource)
        execution = dict(entry.pop('execution'))
        preimage = execution.pop('output_preimage')
        execution['output_preimage_sha256_le32'] = felts_sha(preimage)
        execution['output_preimage_felts'] = len(preimage)
        # Genesis includes the entire serialized state: retain its digest instead of copying it.
        if entry['name'] != 'genesis':
            execution['task_d14'] = preimage[-10:]
        entry['execution'] = execution
        assert entry['executable_sha256'] == native['executables'][entry['program']]['sha256']
        rows.append(entry)
    result = dict(native=native, resources=rows,
                  provenance=json.loads((args.reference/'manifest.json').read_text()),
                  final_source_sha256={str(p.relative_to(Path(__file__).resolve().parent)): sha(p)
                      for pattern in ('*.py', '*.mjs', 'Scarb.toml', 'Scarb.lock', 'SPEC.md', 'src/*.cairo')
                      for p in sorted(Path(__file__).resolve().parent.glob(pattern))},
                  wasm_core_js_sha256=sha(args.reference/'wasm/pkg/dist/core.js'),
                  artifact_notes={
                      'source_base': 'f306c6afa3af652d1c91e579d940d7af94d57cbd',
                      'production_cairo_equal_to': 'aa16f2b952b0df29366597f3b4970ed790266f06',
                      'air_sizing_source_commit': '4309399',
                      'proving_commit': 'cd7bc5f4697fb188a27e09f9242f1dd76df8afdc',
                      'scarb': '2.16.0', 'node': '24.16.0',
                      'native_steps': 'direct executable, without leaf bootloader',
                      'wasm_steps': 'leaf bootloader including Blake program and output hashing',
                      'resource_n_steps': 'opcode count (execute trace length minus one)',
                      'heights': '43 variable types; memory_id_to_big records the largest chunk, 16 are forced by parameters',
                      'builtins': 'adapter labels retained; pedersen_builtin uses narrow-window AIR with canonical_small',
                      'timings': 'single observations, process loading and contention uncontrolled; no latency claim',
                      'proof': 'No proof generated. No RAM, proving-time or production-admission claim.',
                  })
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print('case | P native | B native | production native | P leaf | B leaf | production leaf | P cube raw | B cube raw | P Blake G raw | B Blake G raw')
    for name in ['empty', 'walk1', 'walk4', 'idle300_1', 'fight493_1', 'fight493_4', 'terminal846_1', 'invalid_tag', 'invalid_tic_start', 'invalid_domain_state']:
        case = next(x for x in native['cases'] if x['name'] == name)
        p, b, prod = [next(x for x in rows if x['name'] == name and x['program'] == pr)
                      for pr in ('segment_poseidon', 'segment_blake9', 'production_run_segment')]
        pa, ba = [dict(x['resources']['auxiliary_components']) for x in (p, b)]
        print(f"{name} | {case['variants']['poseidon']['native_steps']} | {case['variants']['blake9']['native_steps']} | {case['production_native_steps']} | {p['execution']['n_steps']} | {b['execution']['n_steps']} | {prod['execution']['n_steps']} | {pa['cube_252']} | {ba['cube_252']} | {pa['blake_g']} | {ba['blake_g']}")
    print('wrote', args.output, args.output.stat().st_size, 'bytes')


if __name__ == '__main__':
    main()

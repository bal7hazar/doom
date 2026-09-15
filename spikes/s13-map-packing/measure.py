#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Hellproof contributors
# SPDX-License-Identifier: GPL-2.0-only
"""Measure an isolated BM_ITEMS decoder; no production source, pins or proofs."""
import argparse
from functools import cache
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

HERE = Path(__file__).resolve().parent
RESOURCE = re.compile(r'^\s*([a-z_0-9 ]+):\s*([0-9,]+)\s*$')

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--scarb', default='scarb')
    ap.add_argument('--sierra-words', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args(); args.out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, ASDF_SCARB_VERSION='2.16.0', RAYON_NUM_THREADS='1')
    commands = []
    def run(command, label):
        start = time.monotonic()
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=120)
        (args.out / (label + '.log')).write_text(result.stdout + result.stderr)
        commands.append(dict(command=list(map(str,command)), returncode=result.returncode, seconds=time.monotonic()-start))
        if result.returncode: raise RuntimeError(f'{label}: see saved log')
        return result.stdout
    def call(name, values, label):
        path = args.out / (label + '.args.json'); path.write_text(json.dumps([hex(x) for x in values]))
        text = run([args.scarb, '--manifest-path', str(HERE/'Scarb.toml'), '--profile', 'proving', 'execute', '--executable-name', name,
                    '--no-build', '--print-program-output', '--print-resource-usage', '--arguments-file', str(path)], label)
        output=[]; resources={}; active=False
        for line in text.splitlines():
            if line.startswith('Program output:'): active=True; continue
            if line.startswith('Resources:'): active=False; continue
            m=RESOURCE.match(line)
            if m: resources[m[1].strip()]=int(m[2].replace(',','')); active=False; continue
            if active and line.strip(): output.append(int(line.strip(),0))
        assert 'steps' in resources, text[-1000:]
        return dict(output=output, resources=resources)
    base = call('reference',[2064],'reference-full')
    candidate = call('candidate',[2064],'candidate-full')
    assert base['output'] == candidate['output']
    # Pin against the independent original source, not the experimental copy.
    source = (HERE.parents[1]/'cairo/doom/doom_map/src/levels/e1m1.cairo').read_text()
    match = re.search(r'pub const BM_ITEMS: \[u32; 2064\] = \[(.*?)\];',source,re.S)
    original=[int(x.strip(),0) for x in match[1].split(',') if x.strip()]
    assert base['output'] == [0,len(original),*original]
    identities={}
    for name in ['reference','candidate','inspect_decode']:
        executable=HERE/'target/proving'/f'{name}.executable.json'
        sierra=executable.with_suffix('.sierra.json')
        mapping=run([str(args.sierra_words.resolve()),str(sierra)],name+'-words')
        instructions=int(mapping.splitlines()[-1].split()[1]);data=json.loads(executable.read_text())
        total=len(data['program']['bytecode'])
        program=json.loads(sierra.read_text())
        types={entry['id']['id']:entry['long_id'] for entry in program['type_declarations']}
        @cache
        def width(type_id):
            ty=types[type_id]; assert ty['generic_id']=='Const'
            parameters=ty['generic_args']; inner=types[parameters[0]['Type']['id']]
            if inner['generic_id'] in ['Struct','NonZero']:
                return sum(width(value['Type']['id']) for value in parameters[1:])
            assert len(parameters)==2 and 'Value' in parameters[1], inner
            return 1
        constant_words=sum(width(entry['long_id']['generic_args'][0]['Type']['id'])
            for entry in program['libfunc_declarations'] if entry['long_id']['generic_id']=='const_as_box')
        identities[name]=dict(sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),sierra_sha256=hashlib.sha256(sierra.read_bytes()).hexdigest(),total_words=total,instruction_words=instructions,constant_words=constant_words,framing_words=total-instructions-constant_words)
    delta_steps=candidate['resources']['steps']-base['resources']['steps']
    saved=identities['reference']['total_words']-identities['candidate']['total_words']
    preliminary=dict(reference=base,candidate=candidate,identities=identities,saved_words=saved,extra_decode_steps=delta_steps,estimated_blake_steps_saved=14.75*saved,passes_cost_filter=delta_steps<14.75*saved and saved>0)
    (args.out/'main-result.json').write_text(json.dumps(preliminary,indent=2)+'\n')
    print({k:v for k,v in preliminary.items() if k not in ['reference','candidate','identities']},flush=True)
    # Complete correctness/rejection checks even when the performance filter fails.
    cases=[('empty',[],0,[]),('one',[2047],1,[2047]),('zero',[0],1,[0]),
      ('six',[2**66-1],6,[2047]*6),('seven',[2**66-1,9],7,[2047]*6+[9]),
      ('partial-five',[sum(i<<(11*i) for i in range(5))],5,list(range(5))),
      ('padding',[1<<11],1,None),('highbits',[1<<66],6,None),('u128max',[2**128-1],6,None),
      ('truncated',[7],7,None),('surplus',[0,0],6,None),('empty-extra',[0],0,None),
      ('bound',[],2065,None),('u32max',[],2**32-1,None)]
    checked=[]
    for label,words,count,expected in cases:
        result=call('inspect_decode',[len(words),*words,count],'case-'+label)
        expected_output=[1] if expected is None else [0,len(expected),*expected]
        assert result['output']==expected_output,(label,result,expected_output)
        checked.append(dict(name=label,count=count,expected=expected_output,resources=result['resources']))
    for count in [0,2063,2065,2**32-1]:
        a=call('reference',[count],f'reference-count-{count}'); b=call('candidate',[count],f'candidate-count-{count}')
        assert a['output']==b['output']==[1]
    preliminary['cases']=checked;preliminary['invalid_count_pairs']=4
    (args.out/'result.json').write_text(json.dumps(preliminary,indent=2)+'\n')
    (args.out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
    print(f'{len(cases)} decoder cases and four opaque count rejection pairs passed')

if __name__=='__main__': main()

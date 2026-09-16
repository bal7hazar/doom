#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""S11 execution equivalence. Uses immutable executables; never generates a proof."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

from vectors import P, field_hash, vectors

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def felt_sha(values):
    return hashlib.sha256(b''.join(v.to_bytes(32, 'little') for v in values)).hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


def unhex(values):
    return [int(v, 0) if isinstance(v, str) else v for v in values]


def hx(values):
    return [hex(v) for v in values]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--executables', type=Path, required=True)
    ap.add_argument('--production', type=Path, required=True)
    ap.add_argument('--runner', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--timeout', type=int, default=120)
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    programs = {p.name.split('.')[0]: p.resolve() for p in args.executables.glob('*.executable.json')}
    programs.update({'production_' + p.name.split('.')[0]: p.resolve()
                     for p in args.production.glob('*.executable.json')})
    manifest = {name: dict(sha256=sha(path), bytecode_words=len(json.loads(path.read_text())['program']['bytecode']))
                for name, path in sorted(programs.items())}
    calls = []

    def run(program, felts, label):
        t0 = time.monotonic()
        p = subprocess.run([str(args.runner), str(programs[program])],
                           input=' '.join(hx(felts)) + '\n', text=True, capture_output=True,
                           timeout=args.timeout, env=dict(os.environ, RAYON_NUM_THREADS='2'))
        if p.returncode:
            raise RuntimeError(f'{program}/{label}: {p.stderr[-3000:]}')
        lines = p.stdout.strip().splitlines()
        assert len(lines) == 1, (program, lines[:1])
        fields = lines[0].split()
        out = unhex(fields[1:])
        rec = dict(label=label, program=program, steps=int(fields[0]),
                   wall_ms=round((time.monotonic()-t0)*1000, 3),
                   input_sha256=felt_sha(felts), output_sha256=felt_sha(out), output_felts=len(out))
        calls.append(rec)
        save(args.output/'native'/f'{label}.{program}.json', dict(**rec, args=hx(felts), output=hx(out)))
        return out, rec

    for row in vectors():
        values = unhex(row['values'])
        out, _ = run('vector_blake9', [len(values), *values], 'vector_' + row['name'])
        assert out == [1, *row['digestWords'], int(row['fieldHex'], 0)], row['name']
    for value in (2**72, P-1):
        out, _ = run('vector_blake9', [1, value], 'domain_' + str(value))
        assert out == [0] * 10
        out, _ = run('hash_blake9', [1, value], 'domain_option_' + str(value))
        assert out == [1]  # Serde Option::None

    pg, _ = run('production_genesis', [0], 'genesis')
    gp, _ = run('genesis_poseidon', [], 'genesis')
    gb, _ = run('genesis_blake9', [], 'genesis')
    state = pg[1:1+pg[0]]
    assert pg == gp and gb[:-1] == gp[:-1]
    assert gb[-1] == field_hash(state)
    hash_only = []
    for variant, expected in [('poseidon', [gp[-1]]), ('blake9', [0, gb[-1]])]:
        out, rec = run('hash_' + variant, [len(state), *state], 'genesis_hash_only')
        assert out == expected  # Blake9 uses Serde Option::Some(hash).
        hash_only.append(rec)
    save(args.output/'genesis.args.json', [])
    resource_jobs = [dict(name='genesis', program=pr, args=hx(ar), expected=hx(out))
                     for pr, ar, out in [('genesis_poseidon', [], gp), ('genesis_blake9', [], gb),
                                         ('production_genesis', [0], pg)]]

    profile_path = ROOT/'cairo/doom/doom_game/bench/profile.py'
    spec = importlib.util.spec_from_file_location('game_profile', profile_path)
    profile = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(profile)
    advanced = {}
    preparations = []
    for name, tic in [('idle', 300), ('fight', 493), ('death', 846)]:
        words = profile.LOGS[name]()[:tic]
        out, rec = run('production_step_tic', [len(state), *state, len(words), *words], 'prepare_' + name)
        next_state = out[2:2+out[1]]
        assert next_state[4] == tic
        assert out[0] == (1 if name == 'death' else 0)
        advanced[name] = next_state
        preparations.append(dict(name=name, tics=tic, commands_sha256=felt_sha(words),
                                 state_felts=len(next_state), state_sha256=felt_sha(next_state),
                                 status=out[0], steps=rec['steps']))

    cases = []
    full_outputs = {}

    def case(name, initial, words, tic=None, max_tics=None, valid=True, measure=True):
        tic = initial[4] if tic is None else tic
        max_tics = len(words) if max_tics is None else max_tics
        flat = [len(initial), *initial, len(words), *words, tic, max_tics]
        inspected = {}
        row = dict(name=name, state_in_felts=len(initial), state_in_sha256=felt_sha(initial),
                   tic_start=tic, word_count=len(words), max_tics=max_tics, valid_state=valid, variants={})
        for variant in ('poseidon', 'blake9'):
            out, irec = run('inspect_' + variant, flat, name)
            assert len(out) >= 12
            public = out[:10]
            end = 11 + out[10]
            st = out[11:end]
            snap = out[end+1:]
            assert out[end] == len(snap)
            result, rec = run('segment_' + variant, flat, name)
            assert result == public
            inspected[variant] = (public, st, snap)
            row['variants'][variant] = dict(native_steps=rec['steps'], inspect_steps=irec['steps'],
                                            d14=hx(public))
            if measure:
                resource_jobs.append(dict(name=name, program='segment_' + variant, args=hx(flat), expected=hx(public)))
        po, so, ro = inspected['poseidon']
        bo, sb, rb = inspected['blake9']
        assert so == sb and ro == rb, name
        assert [v for i, v in enumerate(po) if i not in (1, 2)] == [v for i, v in enumerate(bo) if i not in (1, 2)], name
        production, prodrec = run('production_run_segment', flat, name)
        assert production == po, (name, 'production D14')
        row['production_native_steps'] = prodrec['steps']
        if measure:
            resource_jobs.append(dict(name=name, program='production_run_segment', args=hx(flat), expected=hx(po)))
        if valid:
            assert bo[1] == field_hash(initial) and bo[2] == field_hash(sb), name
            pstep, _ = run('production_step_tic', [len(initial), *initial, min(len(words), max_tics), *words[:max_tics]], name)
            pstate = pstep[2:2+pstep[1]]
            psnap = pstep[3+pstep[1]:]
            assert pstate == so and psnap == ro and pstep[0] == po[5], name
        else:
            assert po == bo and po[5] == 3 and not so and not ro, name
            hash_out, _ = run('hash_poseidon', [len(initial), *initial], name + '_abort_hash')
            assert po[1] == po[2] == hash_out[0]
        row.update(state_out_felts=len(so), state_out_sha256=felt_sha(so),
                   snapshot_felts=len(ro), snapshot_sha256=felt_sha(ro),
                   only_d14_hashes_differ=valid, full_state_and_snapshot_equal=True)
        save(args.output/'cases'/f'{name}.args.json', hx(flat))
        full_outputs[name] = inspected
        cases.append(row)
        print(f"{name}: native P={row['variants']['poseidon']['native_steps']:,} B={row['variants']['blake9']['native_steps']:,}; state/render exact", flush=True)
        return inspected

    walk = profile.walk_log()
    case('empty', state, [])
    case('walk1', state, walk[:1])
    case('walk4', state, walk[:4])
    case('idle300_1', advanced['idle'], profile.idle_log()[300:301])
    case('fight493_1', advanced['fight'], profile.fight_log()[493:494])
    case('fight493_4', advanced['fight'], profile.fight_log()[493:497])
    case('terminal846_1', advanced['death'], profile.death_log()[846:847])
    bad_tag = list(state); bad_tag[0] += 1
    case('invalid_tag', bad_tag, walk[:1], valid=False)
    case('invalid_tic_start', state, walk[:1], tic=1, valid=False)
    bad_domain = list(state); bad_domain[12] = 2**72
    case('invalid_domain_state', bad_domain, walk[:1], valid=False)
    case('invalid_truncated', state[:-1], walk[:1], valid=False, measure=False)

    cuts = []
    for name, initial, words, parts, whole in [
        ('walk_1_3', state, walk[:4], [1, 3], 'walk4'),
        ('walk_1_1_1_1', state, walk[:4], [1, 1, 1, 1], 'walk4'),
        ('fight_2_2', advanced['fight'], profile.fight_log()[493:497], [2, 2], 'fight493_4')]:
        pos = 0; current = initial; previous = {}
        links = []
        for index, n in enumerate(parts):
            result = case(name + '_' + str(index), current, words[pos:pos+n], measure=False)
            for variant in ('poseidon', 'blake9'):
                public, st, snap = result[variant]
                if index:
                    assert previous[variant] == public[1]
                previous[variant] = public[2]
                links.append(dict(variant=variant, cut=index, h_in=hex(public[1]), h_out=hex(public[2])))
            current = result['poseidon'][1]
            pos += n
        assert current == full_outputs[whole]['poseidon'][1]
        assert result['poseidon'][2] == full_outputs[whole]['poseidon'][2]
        cuts.append(dict(name=name, parts=parts, links=links, complete_state_and_render_equal=True))

    save(args.output/'resource_jobs.json', resource_jobs)
    result = dict(schema=1, base='f306c6afa3af652d1c91e579d940d7af94d57cbd', profile='proving',
                  runner=dict(path=str(args.runner), sha256=sha(args.runner)),
                  executables=manifest, vector_count=16, domain_rejections=4,
                  genesis=dict(state_felts=len(state), state_sha256=felt_sha(state),
                               poseidon_hash=hex(gp[-1]), blake9_hash=hex(gb[-1]), full_state_equal=True),
                  preparations=preparations, hash_only=hash_only, cases=cases, cuts=cuts, calls=calls,
                  resource_jobs=len(resource_jobs), proof_generated=False)
    save(args.output/'native.json', result)
    print(f'{len(calls)} native executions, {len(cases)} full comparisons, {len(resource_jobs)} resource jobs ready', flush=True)


if __name__ == '__main__':
    main()

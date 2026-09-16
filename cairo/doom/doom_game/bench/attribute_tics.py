#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Attribute every VM step of every real tic to source functions (D2 profile).

Runs a golden replay through the real `step_tic` executable in bounded
chunks with `--save-profiler-trace-data`, exactly like `trace_profile.py`,
then walks the VM trace itself instead of calling cairo-profiler:

* the dynamic call stack is rebuilt from `fp` (a `call` pushes a frame whose
  `fp` is above the caller's; a `ret` pops back to the caller's `fp`);
* every pc is mapped to its Sierra statement through the `sierra_words`
  offsets, and the statement to its inlining stack through the
  `statements_functions` annotation of the proving build;
* the full stack of a step is its statement's inlining stack followed by the
  inlining stacks of the call sites of every dynamic ancestor.

Each step is charged once to three disjoint views and one overlapping view:

* **flat**: the innermost source function (core helpers included);
* **owner**: the innermost *game* function on the stack (`doom_*` first,
  else the first non-core crate), so a core helper is charged to the game
  code that inlined or called it;
* **category** of that owner (physics, sight, monsters, player, specials,
  serialization, snapshot, game loop, wrapper), per tic;
* **cumulative**: every function on the stack, counted once per step. These
  overlap and must not be summed.

Tics are separated with the recursive `step_tic_impl` command-loop frames;
everything outside them (argument parsing, `from_felts`, `serialize`,
`snapshot`, dictionary squashes) is the boundary and is attributed too.
Per-tic totals equal `trace_profile.py`'s samples: chunking never smooths p99.

    python3 attribute_tics.py --all --chunk 35 --out /tmp/d2-profile
    python3 attribute_tics.py --scenario fight --tics 35 --out /tmp/d2-fight
"""
import argparse
import array
import collections
import hashlib
import json
import math
import re
import statistics
import subprocess
import tempfile
from pathlib import Path
import profile as P
import trace_profile as T

CATEGORIES = [
    ('doom_physics::sight', 'check_sight'),
    ('doom_physics::', 'physique/collision'),
    ('doom_monsters::', 'monstres/IA'),
    ('doom_player::', 'joueur'),
    ('doom_specials::', 'speciaux/secteurs'),
    ('doom_game::state', 'serialisation/hachage'),
    ('doom_game::render', 'snapshot'),
    ('doom_game::', 'boucle doom_game'),
    ('doom_run::', 'wrapper doom_run'),
    ('doom_map::', 'tables carte'),
    ('doom_things::', 'tables carte'),
    ('state_hash::', 'serialisation/hachage'),
    ('segment::', 'boucle doom_game'),
    ('ticcmd::', 'boucle doom_game'),
]
STAGES = [
    'doom_game::tic::height_clip',
    'doom_specials::triggers::player_in_special_sector',
    'doom_player::think::player_think',
    'doom_game::tic::apply_player_events_boxed',
    'doom_game::tic::player_mobj_thinker_boxed',
    'doom_game::tic::rebuild_list',
    'doom_monsters::think::monsters_ticker_with_defense',
    'doom_game::tic::apply_monster_events_boxed',
    'doom_game::tic::reconcile_player',
    'doom_game::tic::place_drops',
    'doom_specials::thinkers::specials_ticker',
    'doom_game::level::refresh_heights',
    'doom_game::level::ctx_of',
    'doom_game::level::moving_sectors',
]


def category_of(owner):
    for prefix, name in CATEGORIES:
        if owner.startswith(prefix):
            return name
    return 'core/autre'


class Program:
    """Static maps of one executable: pc -> statement -> inlining stack."""

    def __init__(self, sierra_path, tool):
        sierra = json.loads(sierra_path.read_text())
        ann = sierra['debug_info']['annotations']['github.com/software-mansion/cairo-profiler']
        self.stacks = {int(k): tuple(v) for k, v in ann['statements_functions'].items()}
        declared = {x['id']['id']: x['long_id'] for x in sierra['libfunc_declarations']}
        types = {x['id']['id']: x['long_id'] for x in sierra['type_declarations']}

        def type_name(type_id):
            ty = types[type_id]
            name = next((a['UserType'].get('debug_name') for a in ty['generic_args'] if 'UserType' in a), None)
            if name:
                return name
            inner = [type_name(a['Type']['id']) for a in ty['generic_args'] if 'Type' in a]
            return ty['generic_id'] + ('<' + ','.join(inner) + '>' if inner else '')
        self.statements = sierra['statements']
        self.stmt_op = []
        self.stmt_copy = []
        for st in self.statements:
            inv = st.get('Invocation')
            if inv:
                long_id = declared[inv['libfunc_id']['id']]
                op = long_id['generic_id']
                copied = None
                if op in ('store_temp', 'store_local'):
                    copied = type_name(long_id['generic_args'][0]['Type']['id'])
            else:
                op, copied = 'return', None
            self.stmt_op.append(op)
            self.stmt_copy.append(copied)
        entries = sorted((f['entry_point'], f['id'].get('debug_name') or '[%d]' % f['id']['id']) for f in sierra['funcs'])
        self.owner = [None] * len(self.statements)
        for k, (ep, name) in enumerate(entries):
            end = entries[k + 1][0] if k + 1 < len(entries) else len(self.statements)
            for i in range(ep, end):
                self.owner[i] = name
        out = subprocess.check_output([str(tool), str(sierra_path)], text=True)
        total = 0
        ranges = []
        for line in out.splitlines():
            v = line.split()
            if v[0] == 'TOTAL':
                total = int(v[1])
            else:
                ranges.append((int(v[0]), int(v[1]), int(v[2])))
        self.pc_stmt = array.array('i', [-1]) * total
        for idx, lo, hi in ranges:
            for pc in range(lo, hi):
                self.pc_stmt[pc] = idx
        self.total_words = total
        self.loop_offset = T.loop_entry(sierra_path)
        self.executable_sha256 = hashlib.sha256(sierra_path.with_name('step_tic.executable.json').read_bytes()).hexdigest()

    def names(self, stmt):
        s = self.stacks.get(stmt)
        if s:
            return s
        return (self.owner[stmt] or '?',)


ROW = re.compile(rb'"pc":\s*(\d+),\s*"ap":\s*(\d+),\s*"fp":\s*(\d+)')


def parse_trace(path):
    text = path.read_bytes()
    m = re.search(rb'"program_offset":\s*(\d+)', text)
    offset = int(m.group(1))
    pcs, fps = array.array('i'), array.array('q')
    tail = text[text.index(b'"vm_trace"'):]
    for r in ROW.finditer(tail):
        pcs.append(int(r.group(1)))
        fps.append(int(r.group(3)))
    m = re.search(rb'"n_steps":\s*(\d+)', text)
    n_steps = int(m.group(1))
    if n_steps != len(pcs):
        raise RuntimeError('trace rows %d != n_steps %d' % (len(pcs), n_steps))
    del text, tail
    return offset, pcs, fps


def tic_of_rows(pcs, fps, entry_pc, actual):
    """Tic index of every row (-1 = boundary), from the nested loop frames."""
    frames, active = [], []
    for index in range(len(pcs)):
        fp = fps[index]
        while active and fp < frames[active[-1]]['fp']:
            frames[active.pop()]['end'] = index
        if pcs[index] == entry_pc:
            frames.append({'start': index, 'fp': fp})
            active.append(len(frames) - 1)
    if active or len(frames) not in (actual, actual + 1):
        raise RuntimeError('incomplete loop frames: %d, actual %d' % (len(frames), actual))
    tic = array.array('i', [-1]) * len(pcs)
    for i, frame in enumerate(frames):
        value = i if i < actual else -2  # -2: the empty terminator frame
        for r in range(frame['start'], frame['end']):
            tic[r] = value
    return tic, frames


def attribute(program, offset, pcs, fps, tic):
    """Counter over (tic, stack_id, statement) plus the interned stacks."""
    pc_stmt = program.pc_stmt
    base = offset + 1
    stack_ids = {}          # (parent_id, callsite_stmt) -> id
    parents = [None]        # id -> (parent_id, callsite_stmt); 0 is the root
    counts = collections.Counter()
    frames = [(fps[0], 0)]  # (fp, stack_id)
    prev_stmt = -1
    n = len(pcs)
    for i in range(n):
        fp = fps[i]
        top_fp = frames[-1][0]
        if fp > top_fp:
            key = (frames[-1][1], prev_stmt)
            sid = stack_ids.get(key)
            if sid is None:
                sid = len(parents)
                parents.append(key)
                stack_ids[key] = sid
            frames.append((fp, sid))
        elif fp < top_fp:
            while frames and frames[-1][0] > fp:
                frames.pop()
            if not frames:
                raise RuntimeError('call stack underflow at row %d' % i)
        pc = pcs[i] - base
        stmt = pc_stmt[pc] if 0 <= pc < len(pc_stmt) else -1
        counts[(tic[i], frames[-1][1], stmt)] += 1
        prev_stmt = stmt
    return counts, parents


def stack_names(program, parents, cache, sid):
    got = cache.get(sid)
    if got is None:
        if sid == 0:
            got = ()
        else:
            parent, callsite = parents[sid]
            got = (program.names(callsite) if callsite >= 0 else ('?',)) + stack_names(program, parents, cache, parent)
        cache[sid] = got
    return got


def owner_of(names):
    for name in names:
        if name.startswith('doom_'):
            return name
    for name in names:
        if not name.startswith('core::'):
            return name
    return names[0]


class Totals:
    def __init__(self):
        self.flat = collections.Counter()
        self.owner = collections.Counter()
        self.cumulative = collections.Counter()
        self.owner_ops = collections.defaultdict(collections.Counter)
        self.owner_copies = collections.defaultdict(collections.Counter)
        self.tic_total = collections.Counter()
        self.tic_category = collections.defaultdict(collections.Counter)
        self.steps = 0

    def add(self, program, parents, counts, tic_base, view_filter):
        cache = {}
        stmt_cache = {}
        for (tic, sid, stmt), n in counts.items():
            if not view_filter(tic):
                continue
            key = (sid, stmt)
            got = stmt_cache.get(key)
            if got is None:
                own = program.names(stmt) if stmt >= 0 else ('<hors statements>',)
                names = own + stack_names(program, parents, cache, sid)
                owner = owner_of(names)
                got = (names[0], owner, category_of(owner), frozenset(names),
                       program.stmt_op[stmt] if stmt >= 0 else '?', program.stmt_copy[stmt] if stmt >= 0 else None)
                stmt_cache[key] = got
            flat, owner, cat, names, op, copied = got
            t = tic_base + tic if tic >= 0 else tic
            self.steps += n
            self.flat[flat] += n
            self.owner[owner] += n
            self.owner_ops[owner][op] += n
            if copied:
                self.owner_copies[owner][copied] += n
            for name in names:
                self.cumulative[name] += n
            self.tic_total[t] += n
            self.tic_category[t][cat] += n


def execute_trace(state, commands):
    args = [len(state), *state, len(commands), *commands]
    with tempfile.NamedTemporaryFile('w', suffix='.json') as f:
        json.dump([hex(x) for x in args], f)
        f.flush()
        run = P.scarb(['execute', '-p', 'doom_run', '--executable-name', 'step_tic', '--no-build',
                       '--arguments-file', f.name, '--print-program-output', '--print-resource-usage',
                       '--save-profiler-trace-data'])
    if run.returncode:
        raise RuntimeError(run.stdout[-4000:] + run.stderr[-4000:])
    trace_path = Path(re.search(r'Saving profiler trace data to: (.+)', run.stdout)[1])
    values, output = [], False
    for line in run.stdout.splitlines():
        if line.startswith('Program output:'):
            output = True
            continue
        if line.startswith('Resources:'):
            break
        if output and line.strip():
            values.append(int(line.strip(), 0) % P.PRIME)
    status, count = values[:2]
    new_state = values[2:2 + count]
    return trace_path, status, new_state, new_state[4] - state[4]


def quantile(values, q):
    return sorted(values)[max(0, math.ceil(len(values) * q) - 1)]


def summarize(name, totals, per_call_boundary, tics, status, program, top, chunks):
    per_tic = [totals.tic_total[t] for t in range(tics)]
    cats = sorted({c for t in range(tics) for c in totals.tic_category[t]})
    category = {}
    for c in cats:
        xs = [totals.tic_category[t].get(c, 0) for t in range(tics)]
        category[c] = dict(mean=statistics.fmean(xs), p99=quantile(xs, .99), max=max(xs), share=sum(xs) / sum(per_tic))
    scale = lambda counter: [(k, v / tics, v) for k, v in counter.most_common(top)]
    result = dict(
        scenario=name, profile=P.PROFILE, executable_sha256=program.executable_sha256, tics=tics, status=status,
        mean=statistics.fmean(per_tic), p50=quantile(per_tic, .5), p90=quantile(per_tic, .9),
        p99=quantile(per_tic, .99), max=max(per_tic), tic_steps=sum(per_tic),
        category_per_tic=category,
        stages_per_tic={s: totals.cumulative.get(s, 0) / tics for s in STAGES},
        owner_per_tic=scale(totals.owner), flat_per_tic=scale(totals.flat),
        cumulative_per_tic=scale(totals.cumulative),
        owner_libfuncs={k: totals.owner_ops[k].most_common(12) for k, _ in totals.owner.most_common(top)},
        owner_copies={k: totals.owner_copies[k].most_common(8) for k, _ in totals.owner.most_common(top)},
        boundary=per_call_boundary, samples=per_tic, chunks=chunks,
    )
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--scenario', action='append', choices=sorted(P.LOGS))
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--chunk', type=int, default=35)
    ap.add_argument('--tics', type=int)
    ap.add_argument('--top', type=int, default=60)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--tool', type=Path, default=P.WORKSPACE.parent / 'infra/sierra_words/target/release/sierra_words')
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    sierra = P.WORKSPACE / 'target' / P.PROFILE / 'step_tic.executable.sierra.json'
    program = Program(sierra, args.tool)
    names = sorted(P.LOGS) if args.all else (args.scenario or ['idle'])
    for name in names:
        state = P.genesis_state()
        commands = P.LOGS[name]()[:args.tics]
        tic_totals, boundary_totals = Totals(), Totals()
        chunks, boundary_steps = [], []
        done, status = 0, 0
        while state[4] < len(commands):
            start = state[4]
            trace_path, status, state, actual = execute_trace(state, commands[start:start + args.chunk])
            if not actual:
                raise RuntimeError('no progress')
            offset, pcs, fps = parse_trace(trace_path)
            trace_path.unlink()
            entry_pc = 1 + offset + program.loop_offset
            tic, frames = tic_of_rows(pcs, fps, entry_pc, actual)
            counts, parents = attribute(program, offset, pcs, fps, tic)
            tic_totals.add(program, parents, counts, done, lambda t: t >= 0)
            boundary_totals.add(program, parents, counts, done, lambda t: t < 0)
            in_tics = sum(tic_totals.tic_total[done + i] for i in range(actual))
            boundary_steps.append(len(pcs) - in_tics)
            chunks.append(dict(tic=start, tics=actual, total_steps=len(pcs), boundary_steps=len(pcs) - in_tics))
            done += actual
            print('%s tic%d +%d mean%.0f boundary%d' % (name, start, actual, in_tics / actual, len(pcs) - in_tics), flush=True)
            if status:
                break
        result = summarize(name, tic_totals, dict(
            calls=len(boundary_steps), mean=statistics.fmean(boundary_steps),
            owner=[(k, v / len(boundary_steps)) for k, v in boundary_totals.owner.most_common(args.top)],
            cumulative=[(k, v / len(boundary_steps)) for k, v in boundary_totals.cumulative.most_common(args.top)],
            flat=[(k, v / len(boundary_steps)) for k, v in boundary_totals.flat.most_common(args.top)],
        ), done, status, program, args.top, chunks)
        (args.out / f'{name}.json').write_text(json.dumps(result, indent=1) + '\n')
        print(json.dumps({k: v for k, v in result.items() if k in ('scenario', 'tics', 'mean', 'p99', 'max', 'status')}), flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

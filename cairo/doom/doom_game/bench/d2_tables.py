#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Markdown tables of an `attribute_tics.py` output directory (docs/design/d2-profile.md).

    python3 d2_tables.py /tmp/d2-profile [--top 15]

Prints, for the scenarios found: the per-tic distribution, the aggregate
over every tic, the category split (disjoint, by innermost game owner), the
sequential stages of `step_tic` (cumulative on disjoint stages), the top
owner functions per scenario and the boundary cost of a `step_tic` call.
"""
import argparse
import collections
import json
import statistics
from pathlib import Path

ORDER = ['idle', 'walk', 'door', 'fight', 'death']


def fmt(x):
    return f'{x:,.0f}'.replace(',', ' ')


def quantile(values, q):
    import math
    return sorted(values)[max(0, math.ceil(len(values) * q) - 1)]


def short(name):
    return name.replace('doom_', '').replace('::think::', '::').replace('::actions::', '::')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir', type=Path)
    ap.add_argument('--top', type=int, default=15)
    args = ap.parse_args()
    runs = {}
    for name in ORDER:
        path = args.dir / f'{name}.json'
        if path.exists():
            runs[name] = json.loads(path.read_text())
    names = list(runs)
    samples = [s for r in runs.values() for s in r['samples']]
    print('## Distribution par tic\n')
    print('| Replay | Tics | Moyenne | p50 | p90 | p99 | Max | Frontière/appel |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|')
    for n, r in runs.items():
        print(f"| {n} | {r['tics']} | {fmt(r['mean'])} | {fmt(r['p50'])} | {fmt(r['p90'])} | {fmt(r['p99'])} | {fmt(r['max'])} | {fmt(r['boundary']['mean'])} |")
    print(f"| **agrégat** | {len(samples)} | **{fmt(statistics.fmean(samples))}** | {fmt(quantile(samples,.5))} | {fmt(quantile(samples,.9))} | **{fmt(quantile(samples,.99))}** | {fmt(max(samples))} | |")

    print('\n## Répartition par poste (steps/tic, propriétaire disjoint)\n')
    cats = sorted({c for r in runs.values() for c in r['category_per_tic']})
    print('| Poste | ' + ' | '.join(names) + ' | agrégat | part |')
    print('|---|' + '---:|' * (len(names) + 2))
    total_all = sum(r['tic_steps'] for r in runs.values())
    tics_all = sum(r['tics'] for r in runs.values())
    for c in cats:
        cells = []
        agg = 0
        for n in names:
            v = runs[n]['category_per_tic'].get(c)
            cells.append(fmt(v['mean']) if v else '0')
            agg += (v['mean'] * runs[n]['tics']) if v else 0
        print(f'| {c} | ' + ' | '.join(cells) + f' | {fmt(agg / tics_all)} | {100 * agg / total_all:.1f} % |')

    print('\n## p99 par poste (steps/tic)\n')
    print('| Poste | ' + ' | '.join(names) + ' |')
    print('|---|' + '---:|' * len(names))
    for c in cats:
        print(f'| {c} | ' + ' | '.join(fmt(runs[n]['category_per_tic'][c]['p99']) if c in runs[n]['category_per_tic'] else '0' for n in names) + ' |')

    print('\n## Étapes séquentielles de step_tic (cumulatif, steps/tic)\n')
    stages = list(next(iter(runs.values()))['stages_per_tic'])
    print('| Étape | ' + ' | '.join(names) + ' | agrégat |')
    print('|---|' + '---:|' * (len(names) + 1))
    for s in stages:
        agg = sum(runs[n]['stages_per_tic'][s] * runs[n]['tics'] for n in names) / tics_all
        print(f'| `{short(s)}` | ' + ' | '.join(fmt(runs[n]['stages_per_tic'][s]) for n in names) + f' | {fmt(agg)} |')
    rest = []
    for n in names:
        rest.append(runs[n]['mean'] - sum(runs[n]['stages_per_tic'].values()))
    print('| reste (`step_tic` propre, boucle `step_tic_impl`) | ' + ' | '.join(fmt(x) for x in rest) + f" | {fmt(sum(rest[i] * runs[n]['tics'] for i, n in enumerate(names)) / tics_all)} |")

    print('\n## Top fonctions propriétaires par replay (steps/tic, disjoint)\n')
    for n in names:
        print(f'\n### {n}\n')
        print('| # | Fonction | steps/tic | part |')
        print('|---:|---|---:|---:|')
        for i, (fn, per_tic, total) in enumerate(runs[n]['owner_per_tic'][:args.top], 1):
            print(f'| {i} | `{fn}` | {fmt(per_tic)} | {100 * total / runs[n]["tic_steps"]:.1f} % |')

    print('\n## Top fonctions propriétaires, agrégat des cinq replays (steps/tic)\n')
    agg = collections.Counter()
    for n in names:
        for fn, per_tic, total in runs[n]['owner_per_tic']:
            agg[fn] += total
    print('| # | Fonction | steps/tic | part |')
    print('|---:|---|---:|---:|')
    for i, (fn, total) in enumerate(agg.most_common(args.top), 1):
        print(f'| {i} | `{fn}` | {fmt(total / tics_all)} | {100 * total / total_all:.1f} % |')

    print('\n## Cumulatif (recouvrant, steps/tic) — sélection\n')
    keys = sorted({fn for n in names for fn, _, _ in runs[n]['cumulative_per_tic']})
    print('| Fonction | ' + ' | '.join(names) + ' |')
    print('|---|' + '---:|' * len(names))
    for fn in keys:
        if fn == '?' or fn.startswith('core::'):
            continue
        row = []
        for n in names:
            v = next((p for f, p, _ in runs[n]['cumulative_per_tic'] if f == fn), 0)
            row.append(fmt(v))
        print(f'| `{fn}` | ' + ' | '.join(row) + ' |')

    print('\n## Libfuncs des postes dominants (agrégat, steps/tic)\n')
    ops = collections.defaultdict(collections.Counter)
    copies = collections.defaultdict(collections.Counter)
    for n in names:
        for fn, table in runs[n]['owner_libfuncs'].items():
            for op, c in table:
                ops[fn][op] += c
        for fn, table in runs[n]['owner_copies'].items():
            for ty, c in table:
                copies[fn][ty] += c
    for fn, total in agg.most_common(8):
        print(f'\n`{fn}` ({fmt(total / tics_all)} steps/tic) : ' + ', '.join(f'{op} {fmt(c / tics_all)}' for op, c in ops[fn].most_common(8)))
        if copies[fn]:
            print('  copies store_temp/local : ' + ', '.join(f'`{ty}` {fmt(c / tics_all)}' for ty, c in copies[fn].most_common(5)))

    print('\n## Frontière d’un appel step_tic (hors tic, steps/appel)\n')
    print('| Fonction (cumulatif) | ' + ' | '.join(names) + ' |')
    print('|---|' + '---:|' * len(names))
    keys = []
    for n in names:
        for fn, v in runs[n]['boundary']['cumulative'][:40]:
            if fn not in keys and fn != '?' and not fn.startswith('core::'):
                keys.append(fn)
    for fn in keys[:30]:
        row = [fmt(next((v for f, v in runs[n]['boundary']['cumulative'] if f == fn), 0)) for n in names]
        print(f'| `{fn}` | ' + ' | '.join(row) + ' |')
    print('\n| Fonction (propriétaire disjoint) | ' + ' | '.join(names) + ' |')
    print('|---|' + '---:|' * len(names))
    keys = []
    for n in names:
        for fn, v in runs[n]['boundary']['owner'][:25]:
            if fn not in keys:
                keys.append(fn)
    for fn in keys[:25]:
        row = [fmt(next((v for f, v in runs[n]['boundary']['owner'] if f == fn), 0)) for n in names]
        print(f'| `{fn}` | ' + ' | '.join(row) + ' |')


if __name__ == '__main__':
    main()

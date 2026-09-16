#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Read-only attribution of linked helpers and constant payloads (Scarb 2.16).

Use annotated Sierra and its matching executable, plus the pinned
infra/sierra_words tool. Words belong to the first non-core source frame;
these consumer costs are not the historical size-minus-baseline measure.
Constant extraction follows cairo-lang-sierra-to-casm 2.16.0 compiler.rs,
ConstsInfo::new / extract_const_value. Unknown constant layouts fail closed.
"""
import argparse
from collections import Counter, defaultdict
from functools import cache
import hashlib
import json
from pathlib import Path
import re
import subprocess


def clean(name):
    return re.sub(r'\[\d+-\d+\]', '', re.sub(r'::<.*>', '', re.sub(r'\{.*\}$', '', name)))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--sierra', required=True, type=Path)
    ap.add_argument('--executable', required=True, type=Path)
    ap.add_argument('--tool', required=True, type=Path)
    ap.add_argument('--json', required=True, type=Path)
    args = ap.parse_args()
    sierra = json.loads(args.sierra.read_text())
    types = {x['id']['id']: x['long_id'] for x in sierra['type_declarations']}
    libfuncs = {x['id']['id']: x['long_id'] for x in sierra['libfunc_declarations']}
    annotations = sierra['debug_info']['annotations']['github.com/software-mansion/cairo-profiler']['statements_functions']
    owners, core, box_owners, innermost = Counter(), Counter(), Counter(), Counter()
    constant_uses = defaultdict(set)
    code_words = 0
    offsets = subprocess.check_output([str(args.tool.resolve()), str(args.sierra.resolve())], text=True, timeout=120)
    for line in offsets.splitlines():
        if line.startswith('TOTAL'):
            continue
        i, lo, hi = map(int, line.split())
        words = hi - lo
        code_words += words
        stack = [clean(x) for x in annotations.get(str(i), [])]
        inner = stack[0] if stack else 'unattributed'
        owner = next((x for x in stack if not x.startswith('core::')), 'unattributed')
        owners[owner] += words
        innermost[inner.split('::')[0]] += words
        if inner.startswith('core::'):
            core[inner] += words
        if inner == 'core::box::BoxImpl::new':
            box_owners[owner] += words
        invocation = sierra['statements'][i].get('Invocation')
        if invocation:
            constant_uses[invocation['libfunc_id']['id']].update(x for x in stack if not x.startswith('core::'))

    def integer(value):
        return value[0] * sum(limb << (32 * i) for i, limb in enumerate(value[1]))

    @cache
    def constant_values(type_id):
        ty = types[type_id]
        assert ty['generic_id'] == 'Const', ty
        params = ty['generic_args']
        inner = types[params[0]['Type']['id']]
        if inner['generic_id'] in ('Struct', 'NonZero'):
            return tuple(v for p in params[1:] for v in constant_values(p['Type']['id']))
        if inner['generic_id'] == 'Enum':
            # Only bool is linked here: two empty variants, no padding.
            assert inner['generic_args'][0]['UserType']['debug_name'] == 'core::bool', inner
            assert len(inner['generic_args']) == 3 and len(params) == 3, inner
            variant = integer(params[1]['Value'])
            assert variant in (0, 1)
            assert constant_values(params[2]['Type']['id']) == ()
            return (variant,)
        assert len(params) == 2 and 'Value' in params[1], inner
        return (integer(params[1]['Value']),)

    constants = []
    unique_payloads = set()
    for ident, libfunc in libfuncs.items():
        assert libfunc['generic_id'] != 'get_circuit_descriptor', 'circuit constants need separate attribution'
        if libfunc['generic_id'] != 'const_as_box':
            continue
        values = constant_values(libfunc['generic_args'][0]['Type']['id'])
        unique_payloads.add(values)
        constants.append(dict(words=len(values), max_bits=max((abs(x).bit_length() for x in values), default=0),
                              nonnegative=all(x >= 0 for x in values),
                              owners=sorted(constant_uses[ident])))
    total = len(json.loads(args.executable.read_text())['program']['bytecode'])
    constant_words = sum(row['words'] for row in constants)
    result = dict(sierra_sha256=hashlib.sha256(args.sierra.read_bytes()).hexdigest(),
                  executable_sha256=hashlib.sha256(args.executable.read_bytes()).hexdigest(),
                  total_words=total, statement_words=code_words, constant_words=constant_words,
                  framing_words=total-code_words-constant_words,
                  duplicate_constant_payload_words=constant_words-sum(map(len, unique_payloads)),
                  innermost_source=dict(innermost.most_common()), consumer_owners=dict(owners.most_common()),
                  core_functions=dict(core.most_common()), box_owners=dict(box_owners.most_common()),
                  constants=sorted(constants, key=lambda row: row['words'], reverse=True))
    assert result['framing_words'] >= 0
    args.json.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if not isinstance(v, (dict, list))}, indent=2))


if __name__ == '__main__':
    main()

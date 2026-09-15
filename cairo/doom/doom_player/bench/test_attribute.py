#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""An unnamed consumer must retain attribution from source-stack annotations."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import attribute


class ConsumerAttributionTests(unittest.TestCase):
    def test_missing_and_null_sierra_names_keep_the_same_player_words(self):
        reports = []
        for ident in [{'id': 7, 'debug_name': 'consumer::main'},
                      {'id': 7, 'debug_name': None}, {'id': 7}]:
            with self.subTest(ident=ident), tempfile.TemporaryDirectory() as tmp:
                sierra = Path(tmp) / 'consumer.executable.sierra.json'
                report = Path(tmp) / 'result.json'
                sierra.write_text(json.dumps({
                    'debug_info': {'annotations': {'github.com/software-mansion/cairo-profiler': {
                        'statements_functions': {
                            '0': ['core::integer::Felt252TryIntoU32::try_into',
                                  'doom_player::action', 'consumer::main'],
                            '1': ['consumer::main'],
                        },
                    }}},
                    'type_declarations': [{'id': {'id': 2},
                        'long_id': {'generic_id': 'felt252', 'generic_args': []}}],
                    'libfunc_declarations': [{'id': {'id': 1},
                        'long_id': {'generic_id': 'store_temp', 'generic_args': []}}],
                    'statements': [{'Invocation': {'libfunc_id': {'id': 1}}}, {'Return': []}],
                    'funcs': [{'entry_point': 0, 'id': ident, 'params': [{'ty': {'id': 2}}],
                               'signature': {'ret_types': [{'id': 2}]}}],
                }))
                with (patch.object(attribute, 'offsets', return_value=({0: 3, 1: 2}, 5)),
                      patch('sys.argv', ['attribute.py', '--sierra', str(sierra),
                                         '--json', str(report), '--top', '0']),
                      contextlib.redirect_stdout(io.StringIO())):
                    self.assertEqual(attribute.main(), 0)
                data = json.loads(report.read_text())
                reports.append((data['crate_code_words'], data['crate_data_words'], data['crate_words']))
        self.assertEqual(reports, [(3, 0, 3)] * 3)


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""The D29 limit cannot be bypassed by re-baselining or a consumer artifact."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import measure


class BudgetGuardTests(unittest.TestCase):
    def run_guard(self, proving, consumer=None, update=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            budget = root / "budgets.json"
            original = json.dumps({"operations": [], "code_words": 20000,
                                   "code_words_proving": 20000})
            budget.write_text(original)
            argv = ["measure.py"]
            if consumer is not None:
                argv += ["--consumer-sierra", "consumer.sierra.json"]
            if update:
                argv.append("--update")
            values = [proving, proving] + ([consumer] if consumer is not None else [])
            with (patch.object(measure, "HERE", root),
                  patch.object(measure, "build"),
                  patch.object(measure, "words_of", return_value=20000),
                  patch.object(measure, "attributed_words", side_effect=values),
                  patch("sys.argv", argv), contextlib.redirect_stdout(io.StringIO())):
                result = measure.main()
            return result, budget.read_text() == original

    def test_exact_limit_is_accepted(self):
        self.assertEqual(self.run_guard(20000)[0], 0)

    def test_one_word_over_is_rejected_without_tolerance(self):
        self.assertEqual(self.run_guard(20001), (1, True))

    def test_update_cannot_raise_the_hard_limit(self):
        self.assertEqual(self.run_guard(20001, update=True), (1, True))

    def test_consumer_overage_is_not_hidden_by_small_harness(self):
        self.assertEqual(self.run_guard(19000, consumer=20001, update=True), (1, True))


if __name__ == "__main__":
    unittest.main()

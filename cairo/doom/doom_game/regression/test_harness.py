# SPDX-License-Identifier: GPL-2.0-only
"""Harness checks, separate from the actual game coverage reported by run.py."""
import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile
import time
import unittest
from unittest.mock import patch
from abi import (Failure, STATE_TAG, decode_frame, expected_d14, input_commitment, packed)
from corpus import scenarios, word
from run import check_profile, failure_artifact, invoke_genesis, replay, reproduce
from runner import HERE, Runner


def frame(tic=0, status=0, marker=0):
    state = [STATE_TAG, 2, 44, 0, tic, status] + [0] * 41
    state[10] = marker
    snapshot = [1, tic, status, 0, 0] + [0] * 31
    snapshot[35] = tic
    return decode_frame([status, len(state), *state, len(snapshot), *snapshot])


class CountRunner:
    """A tiny fake only for terminal-accounting/shrinking tests, never a gameplay fixture."""
    profile = "proving"
    identity = {}

    def __init__(self, corrupt=False):
        self.corrupt = corrupt

    def call(self, name, values):
        n = values[0]
        state = values[1:1 + n]
        count = values[n + 1]
        words = values[n + 2:n + 2 + count]
        actual = words.index(999) + 1 if 999 in words else len(words)
        status = 1 if 999 in words else state[5]
        marker = state[4] if self.corrupt and words else state[10]
        end = frame(state[4] + actual, status, marker)
        if name == "step_tic":
            return end.raw
        return expected_d14(state, end, words)


class HarnessTests(unittest.TestCase):
    def test_corpus_is_distinct_and_retains_the_five_historical_command_logs(self):
        cases = {c["name"]: c["words"] for c in scenarios()}
        self.assertGreaterEqual(len(cases), 20)
        self.assertEqual(len({tuple(w) for w in cases.values()}), len(cases))
        self.assertTrue(all(0 <= w < 2**32 for words in cases.values() for w in words))
        spec = importlib.util.spec_from_file_location("historical", HERE.parent / "bench/profile.py")
        historical = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(historical)
        for ours, original in [("idle", "idle"), ("walk_lift", "walk"), ("door_pickups", "door"),
                               ("fight_sweep", "fight"), ("death", "death")]:
            self.assertEqual(cases[ours], historical.LOGS[original]())

    def test_clean_poseidon_package_matches_existing_independent_reference_vectors(self):
        self.assertEqual(input_commitment([]),
            0x2d5e13ed7c628cddeebe8a20c5aec4389f3c922e8276979479be592bd4f963e)
        self.assertEqual(input_commitment([word(i) for i in range(9)]),
            0x5a1a00832b34d6773e3ac371ddb6dfa8fef9813b137df243faf9539da38cad2)

    def test_rejects_truncated_and_mismatched_abi_envelopes(self):
        good = frame().raw
        for broken in (good[:-1], good + [0], [0, 100000, 0]):
            with self.assertRaises(Failure):
                decode_frame(broken)

    def test_rejects_abort_and_large_state_or_render_felts(self):
        for location in (2 + 10, len(frame().raw) - 1):
            broken = frame().raw
            broken[location] = 2**72
            with self.assertRaises(Failure):
                decode_frame(broken)
        broken = frame().raw
        broken[0] = 3
        with self.assertRaises(Failure):
            decode_frame(broken)

    def test_counts_only_tics_before_terminal_and_keeps_the_empty_boundary_exact(self):
        end, public, counts = replay(CountRunner(), frame().state,
            [word()] * 3 + [999] + [word()] * 6, 20260913, many=False)
        self.assertEqual(end.tic, 4)
        self.assertEqual(public[4:6], [4, 1])
        self.assertEqual(counts["actual_tics"], 4)
        self.assertEqual(counts["terminal_unconsumed"], 6)
        self.assertEqual(sum(counts["cuts"]), 4)

    def test_split_only_divergence_is_detected_and_reduced_to_a_reproducible_suffix(self):
        runner = CountRunner(corrupt=True)
        case = dict(name="synthetic-shrinker", state=frame().state, words=[word()] * 12,
                    seed=7, many=False, d14_cuts=True, boundary=True)
        with self.assertRaises(Failure) as raised:
            replay(runner, case["state"], case["words"], 7, many=False)
        self.assertEqual(raised.exception.kind, "split_equivalence")
        with tempfile.TemporaryDirectory() as temp:
            failure_artifact(Path(temp), runner, case, raised.exception)
            repro = json.loads((Path(temp) / "repro.json").read_text())
            self.assertLess(len(repro["case"]["words"]), 12)
            with self.assertRaises(Failure) as again:
                replay(runner, case["state"], repro["case"]["words"], 7, many=False)
            self.assertEqual(again.exception.kind, raised.exception.kind)

    def test_profile_mismatch_keeps_complete_case_and_reproduces(self):
        runner = CountRunner()
        case = dict(name="synthetic-profile", state=frame().state, words=[word()] * 3,
                    seed=7, many=False, d14_cuts=True, boundary=True)
        end, public, _ = replay(runner, case["state"], case["words"], 7, many=False)
        wrong = frame(3, marker=42).raw
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(Failure):
                check_profile(runner, Path(temp), case, end, public, (wrong, public))
            saved = json.loads((Path(temp) / "repro.json").read_text())
            self.assertEqual(saved["case"]["words"], case["words"])
            self.assertEqual(saved["case"]["expected_output"], wrong)
            with self.assertRaises(Failure) as again:
                reproduce(runner, saved["case"])
            self.assertEqual(again.exception.kind, "profile_equivalence")

    def test_genesis_failure_keeps_reproducible_public_invocation(self):
        class BadGenesis:
            profile, identity = "proving", {"genesis": "test-identity"}
            def call(self, name, values):
                self.last_call = dict(name=name, arguments=values)
                return []
        runner = BadGenesis()
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(Failure):
                invoke_genesis(runner, Path(temp))
            saved = json.loads((Path(temp) / "repro.json").read_text())
            self.assertEqual(saved["identity"], runner.identity)
            self.assertEqual(saved["invocation"], dict(name="genesis", arguments=[0]))
            with self.assertRaises(Failure) as again:
                reproduce(runner, saved["case"])
            self.assertEqual(again.exception.kind, "genesis")

    def test_malformed_or_missing_subprocess_output_preserves_diagnostics(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "target/proving").mkdir(parents=True)
            for name in ("genesis", "step_tic", "run_segment"):
                (base / f"target/proving/{name}.executable.json").write_text('{"program":{"bytecode":[]}}')
            fake = base / "scarb"
            for output in ("Program output:\nnot-a-felt\nResources:\nsteps: 1", "nothing here"):
                fake.write_text("#!/bin/sh\nprintf '%s\\n' '" + output + "'\n")
                fake.chmod(0o755)
                runner = Runner("proving", base / "out", target=base / "target")
                with patch.dict(os.environ, {"PATH": str(base) + os.pathsep + os.environ["PATH"]}):
                    with self.assertRaises(Failure) as raised:
                        invoke_genesis(runner, base / "out")
                self.assertEqual(raised.exception.kind, "execution")
                saved = json.loads((base / "out/repro.json").read_text())
                self.assertEqual(saved["invocation"]["arguments"], [0])
                self.assertEqual(saved["identity"], runner.identity)
                self.assertIn(output, (base / "out/failure-stdout.txt").read_text())

    def test_runner_timeout_kills_the_process_group_and_keeps_the_exact_arguments(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "target/proving").mkdir(parents=True)
            for name in ("genesis", "step_tic", "run_segment"):
                (base / f"target/proving/{name}.executable.json").write_text('{"program":{"bytecode":[]}}')
            fake = base / "scarb"
            fake.write_text("#!/bin/sh\nsleep 5\n")
            fake.chmod(0o755)
            runner = Runner("proving", base / "out", timeout=0.1, target=base / "target")
            started = time.monotonic()
            with patch.dict(os.environ, {"PATH": str(base) + os.pathsep + os.environ["PATH"]}):
                with self.assertRaises(Failure) as raised:
                    runner.call("genesis", [0])
            self.assertEqual(raised.exception.kind, "timeout")
            self.assertLess(time.monotonic() - started, 3)
            self.assertEqual(json.loads((base / "out/last-arguments.json").read_text()), ["0x0"])


class GoldenProvenanceTests(unittest.TestCase):
    def test_new_pins_agree_with_unmodified_historical_game_hashes(self):
        pins = json.loads((HERE / "goldens.json").read_text())["cases"]
        source = (HERE.parent / "src/tests/e1m1.cairo").read_text()
        for case, symbol in [("idle", "IDLE"), ("walk_lift", "WALK"), ("door_pickups", "DOOR"),
                             ("fight_sweep", "FIGHT"), ("death", "DEATH")]:
            value = re.search(rf"const {symbol}_HASH: felt252 =\s*(\d+);", source)[1]
            self.assertEqual(int(pins[case]["d14"][2], 0), int(value))

#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Hellproof contributors
# SPDX-License-Identifier: GPL-2.0-only
"""Generate immutable real-game fixtures from the existing five replay logs.

Requires proving doom_run executables already built at the intended git revision.
Every Scarb call has a 180-second timeout; this writes only to the chosen output.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location(
        "game_profile", ROOT / "cairo/doom/doom_game/bench/profile.py")
    profile = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(profile)
    profile.NATIVE_RUNNER = None
    profile.PROFILE = "proving"

    def scarb(arguments):
        command = ["scarb", "--manifest-path", str(ROOT / "cairo/Scarb.toml"),
                   "--profile", "proving", *arguments, "--output", "none"]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(os.environ, ASDF_SCARB_VERSION="2.16.0"), start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=180)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise SystemExit("Scarb fixture generation exceeded 180 seconds")
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)

    profile.scarb = scarb
    initial = profile.genesis_state()
    cases = []
    for name, start in [("idle", 300), ("walk", 80), ("door", 230), ("fight", 450), ("death", 780)]:
        words = profile.LOGS[name]()
        _, state, _ = profile.step(initial, words[:start])
        commands = words[start:start + 80]
        final, resources = profile.execute("step_tic", [len(state), *state, len(commands), *commands])
        encoded = b"".join(x.to_bytes(32, "little") for x in final)
        cases.append(dict(name=name, ticStart=start, state=[hex(x) for x in state],
            commands=commands, expectedStatus=final[0], expectedTicEnd=final[6],
            expectedSha256=hashlib.sha256(encoded).hexdigest(), standaloneChunkSteps=resources["steps"]))
        print(name, start, final[6], final[0], flush=True)
    executable = ROOT / "cairo/target/proving/step_tic.executable.json"
    shutil.copyfile(executable, args.output / executable.name)
    (args.output / "fixtures.json").write_text(json.dumps(cases))
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    provenance = dict(reference=revision,
        programWords=len(json.loads(executable.read_text())["program"]["bytecode"]),
        programSha256=hashlib.sha256(executable.read_bytes()).hexdigest())
    (args.output / "provenance.json").write_text(json.dumps(provenance, indent=2))


if __name__ == "__main__":
    main()

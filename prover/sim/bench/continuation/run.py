#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Hellproof contributors
# SPDX-License-Identifier: Apache-2.0
"""Bounded build and equivalence run against immutable real-game fixtures."""
import argparse
import os
from pathlib import Path
import signal
import subprocess

HERE = Path(__file__).resolve().parent
SIM = HERE.parents[1]


def run(command, cwd, output, seconds, env):
    with output.open("w") as log:
        process = subprocess.Popen(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
                                   env=env, start_new_session=True)
        try:
            code = process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise SystemExit(f"Deadline {seconds}s: {command}; log {output}")
        if code:
            raise SystemExit(f"Exit {code}: {command}; log {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixtures", type=Path)
    parser.add_argument("reference_executable", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, CARGO_BUILD_JOBS="2", ASDF_SCARB_VERSION="2.16.0",
               ASDF_NODEJS_VERSION="22.22.2")
    if not args.skip_build:
        run(["scarb", "--profile", "proving", "build"], HERE / "cairo",
            args.output / "cairo-build.log", 600, env)
        run(["cargo", "build", "--release", "--locked", "--jobs", "2", "--bin", "continuation"],
            SIM, args.output / "native-build.log", 600, env)
        run(["wasm-pack", "build", "--release", "--target", "web", "--out-dir", "pkg",
             "--", "--locked", "--jobs", "2"], SIM, args.output / "wasm-build.log", 600, env)
    # Keep stdout machine-readable and stderr in the same run log.
    native = args.output / "native-combined.log"
    run([str(SIM / "target/release/continuation"),
         str(HERE / "cairo/target/proving/session.executable.json"),
         str(args.reference_executable.resolve()), str(args.fixtures.resolve())],
        SIM, native, 180, env)
    lines = native.read_text().splitlines()
    (args.output / "native.json").write_text(lines[-1] + "\n")
    run(["node", str(HERE / "browser.mjs"), str(args.fixtures.resolve()),
         str(args.output / "native.json"), str(args.output / "chromium.json")],
        HERE, args.output / "browser.log", 240, env)
    print(args.output / "chromium.json")


if __name__ == "__main__":
    main()

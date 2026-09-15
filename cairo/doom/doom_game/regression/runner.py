# SPDX-License-Identifier: GPL-2.0-only
"""Bounded Scarb 2.16 standalone runner. No native probing, proof, or artifact rebuilding."""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
from abi import Failure, PRIME

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[2]
ROOT = WORKSPACE.parent
NAMES = ("genesis", "step_tic", "run_segment")
RESOURCE = re.compile(r"^\s*([a-z_0-9 ]+):\s*([0-9,]+)\s*$")


class Runner:
    def __init__(self, profile, out, timeout=120, target=None):
        self.profile = profile
        self.out = Path(out).resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        self.timeout = timeout
        self.deadline = None
        self.last_call = None
        self.target = Path(target or WORKSPACE / "target").resolve()
        self.metrics = {name: dict(calls=0, steps=0, seconds=0.0, executed_tics=0) for name in NAMES}
        self.identity = {}
        for name in NAMES:
            path = self.target / profile / f"{name}.executable.json"
            raw = path.read_bytes()
            bytecode = json.loads(raw)["program"]["bytecode"]
            self.identity[name] = dict(words=len(bytecode), executable_sha256=hashlib.sha256(raw).hexdigest(),
                                      bytecode_sha256=hashlib.sha256(json.dumps(bytecode).encode()).hexdigest())

    def call(self, name, values):
        args = self.out / "last-arguments.json"
        args.write_text(json.dumps([hex(x) for x in values]))
        command = ["scarb", "--manifest-path", str(WORKSPACE / "Scarb.toml"), "--profile", self.profile,
                   "execute", "-p", "doom_run", "--executable-name", name, "--no-build", "--output", "none",
                   "--print-program-output", "--print-resource-usage", "--arguments-file", str(args)]
        env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0", SCARB_TARGET_DIR=str(self.target),
                   RAYON_NUM_THREADS="2", CARGO_BUILD_JOBS="2")
        (self.out / "last-command.json").write_text(json.dumps(dict(command=command, profile=self.profile), indent=2))
        self.last_call = dict(name=name, arguments=values, command=command, profile=self.profile,
                              identity=self.identity)
        (self.out / "last-stdout.txt").write_text("")
        (self.out / "last-stderr.txt").write_text("")
        started = time.monotonic()
        try:
            return self._execute(name, values, command, env, started)
        except (Failure, OSError, ValueError) as error:
            failure = error if isinstance(error, Failure) else Failure("execution", f"{name}: {error}")
            (self.out / "execution-failure.json").write_text(json.dumps(
                dict(**self.last_call, kind=failure.kind, error=str(failure)), indent=2) + "\n")
            raise failure from None

    def _execute(self, name, values, command, env, started):
        remaining = self.timeout if self.deadline is None else min(self.timeout, self.deadline - started)
        if remaining <= 0:
            raise Failure("campaign_timeout", "execution deadline reached")
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env=env, start_new_session=True)
        try:
            stdout, stderr = proc.communicate(timeout=remaining)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass  # The process may have exited between the deadline and the signal.
            stdout, stderr = proc.communicate()
            (self.out / "last-stdout.txt").write_text(stdout)
            (self.out / "last-stderr.txt").write_text(stderr)
            raise Failure("timeout", f"{name} exceeded {remaining:.3f}s") from None
        # Preserve diagnostics for malformed stdout too, not only nonzero exits/timeouts.
        (self.out / "last-stdout.txt").write_text(stdout)
        (self.out / "last-stderr.txt").write_text(stderr)
        if proc.returncode:
            (self.out / "failure-stdout.txt").write_text(stdout)
            (self.out / "failure-stderr.txt").write_text(stderr)
            raise Failure("execution", f"{name} exit {proc.returncode}: {(stdout + stderr)[-2000:]}")
        output, steps, in_output = [], None, False
        for line in stdout.splitlines():
            if line.startswith("Program output:"):
                in_output = True
                continue
            if line.startswith("Resources:"):
                in_output = False
                continue
            match = RESOURCE.match(line)
            if match:
                in_output = False
                if match[1].strip() == "steps":
                    steps = int(match[2].replace(",", ""))
            elif in_output and line.strip():
                output.append(int(line.strip(), 0) % PRIME)
        if steps is None or not output:
            raise Failure("execution", f"{name}: missing Scarb output/resources")
        metrics = self.metrics[name]
        metrics["calls"] += 1
        metrics["steps"] += steps
        metrics["seconds"] += time.monotonic() - started
        if name == "step_tic" and len(output) > 6 and output[1] > 4:
            metrics["executed_tics"] += max(0, output[6] - values[5])
        elif name == "run_segment" and len(output) == 10:
            metrics["executed_tics"] += max(0, output[4] - output[3])
        return output

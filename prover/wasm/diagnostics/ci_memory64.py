#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Hellproof contributors
"""Bounded CI runner for the existing Memory64 regression, without a proof/build.

Run `runtime` after building the locked native tool; run `artifacts` on the two
outputs of the existing Docker build. Inputs and checksum references are read-only.
Command metadata and raw stdout/stderr survive failures for CI artifact upload.
"""

import argparse
import filecmp
import hashlib
import json
import subprocess
import tempfile
import time
from pathlib import Path


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def run(results, name, command, timeout):
    record = {"command": [str(arg) for arg in command], "timeout_seconds": timeout}
    stdout = results / f"{name}.stdout.log"
    stderr = results / f"{name}.stderr.log"
    started = time.monotonic()
    try:
        with stdout.open("w") as out, stderr.open("w") as err:
            completed = subprocess.run(command, stdout=out, stderr=err, timeout=timeout)
        record["returncode"] = completed.returncode
        if completed.returncode:
            raise RuntimeError(f"{name} exited {completed.returncode}; see {stderr}")
        return stdout.read_text()
    except subprocess.TimeoutExpired as error:
        record["timed_out"] = True
        raise RuntimeError(f"{name} exceeded {timeout}s; see {stderr}") from error
    finally:
        record["elapsed_seconds"] = round(time.monotonic() - started, 3)
        write_json(results / f"{name}.command.json", record)
        print(json.dumps({"name": name, **record}), flush=True)


def runtime(args):
    harness = Path(__file__).with_name("memory64-splats.mjs")
    results = {}
    for name, flags in [
        ("default", []),
        ("liftoff-only", ["--liftoff-only"]),
        ("no-liftoff", ["--no-liftoff"]),
    ]:
        result = json.loads(
            run(args.results, f"runtime-{name}", [args.node, *flags, harness, args.tool], 45)
        )
        results[name] = result
        # Check completeness too: a harness that stopped exercising a tier must fail CI.
        write_json(args.results / "runtime.json", results)
        if not result["node"].startswith("24.") or result["flags"] != flags:
            raise RuntimeError(f"{name}: expected Node 24 and flags {flags}, got {result}")
        lowered = result["lowered"]
        if lowered != {"checks": 400024, "failures": [], "memoryBytes": 4295163904}:
            raise RuntimeError(f"{name}: incomplete or failed lowered runtime checks: {lowered}")
        # Original failures are observations, never required: a fixed V8 must also pass.
        print(f"{name}: {lowered['checks']} corrected checks passed", flush=True)


def artifacts(args):
    results = {}
    for name in ["hellproof_prover_wasm.wasm", "hellproof_prover_wasm.threads.wasm"]:
        source = (args.artifacts / name).resolve(strict=True)
        # Only temporary files are rewritten; do not replace the release artifacts or hashes.
        with tempfile.TemporaryDirectory(prefix="memory64-idempotence-") as temporary:
            output = Path(temporary) / name
            log = run(args.results, f"idempotence-{name}", [args.tool, source, output], 60)
            # Compare every byte, not metadata or just a scan for opcode byte patterns.
            identical = filecmp.cmp(source, output, shallow=False)
            with source.open("rb") as data:
                digest = hashlib.file_digest(data, "sha256").hexdigest()
            results[name] = {"bytes": source.stat().st_size, "sha256": digest, "identical": identical}
            write_json(args.results / "artifacts.json", results)
            if not identical or not log.startswith("lowered 0 Memory64 SIMD splat loads;"):
                raise RuntimeError(f"{name}: affected loads remain or lowering changed the binary")
            print(f"{name}: byte-identical, zero affected loads, SHA256 {digest}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["runtime", "artifacts"])
    parser.add_argument("--tool", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--node", default="node")
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    args.tool = args.tool.resolve(strict=True)
    if args.phase == "artifacts" and args.artifacts is None:
        parser.error("artifacts phase requires --artifacts")
    args.results.mkdir(parents=True, exist_ok=True)
    if args.phase == "runtime":
        runtime(args)
    else:
        artifacts(args)


if __name__ == "__main__":
    main()

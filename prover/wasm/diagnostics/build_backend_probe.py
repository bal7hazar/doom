#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Hellproof contributors
"""Link the bounded diagnostic against an existing pinned WASM64 dependency cache.

This does not rebuild or mutate the dependency cache. The caller names exact rlibs
because different single/threaded builds can coexist in one cache.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--wasm-deps", type=Path, required=True)
parser.add_argument("--host-deps", type=Path, required=True)
parser.add_argument("--stwo", required=True, help="exact libstwo-*.rlib filename")
parser.add_argument("--std", required=True, help="exact libstd-*.rlib filename")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
for name in [args.stwo, args.std]:
    if Path(name).name != name or not (args.wasm_deps / name).is_file():
        parser.error(f"not a dependency rlib filename: {name}")
command = [
    "rustc", "+nightly-2026-01-15", "--edition", "2024", "--target",
    "wasm64-unknown-unknown", "--crate-type", "cdylib", "-C", "opt-level=3",
    "-C", "panic=abort", "-C",
    "target-feature=+bulk-memory,+nontrapping-fptoint,+sign-ext,+mutable-globals,+simd128",
    "-C", "link-arg=-zstack-size=16777216", "-C", "link-arg=--max-memory=17179869184",
    "-L", f"all={args.wasm_deps}", "-L", f"all={args.host_deps}",
    "--extern", f"std={args.wasm_deps / args.std}",
    "--extern", f"stwo={args.wasm_deps / args.stwo}",
    str(Path(__file__).with_name("backend_probe.rs")), "-o", str(args.output),
]
subprocess.run(command, check=True, timeout=120)
print(hashlib.sha256(args.output.read_bytes()).hexdigest(), args.output)

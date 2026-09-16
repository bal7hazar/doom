#!/usr/bin/env python3
"""Stage the pinned R5 VM (SHA-256 from src/prove/doomArtifacts.ts) and build the real Cairo adapters at this checkout.

Usage: python3 scripts/prepare-sim.py /path/to/prover/sim/pkg
Generated files stay in ignored public/sim; no Rust rebuild or download.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess

ROOT = Path(__file__).resolve().parents[2]
# The R5 VM pin lives in doomArtifacts.ts only (client/scripts/migrate-identity.mjs --sim --pin-sim moves it).
WASM_SHA = re.search(r'\bwasm: "([0-9a-f]{64})"', (ROOT / "client/src/prove/doomArtifacts.ts").read_text()).group(1)


def build(cwd, extra):
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0", CARGO_BUILD_JOBS="2")
    child = subprocess.Popen(["scarb", "--profile", "proving", "build", *extra],
                             cwd=cwd, env=env, start_new_session=True)
    try:
        if child.wait(timeout=600):
            raise SystemExit("Scarb build failed")
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()
        raise SystemExit("Scarb build exceeded 600 seconds")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pkg", type=Path)
    args = parser.parse_args()
    wasm = args.pkg / "hellproof_sim_bg.wasm"
    if hashlib.sha256(wasm.read_bytes()).hexdigest() != WASM_SHA:
        raise SystemExit("The simulation VM is not the pinned R5 artifact")
    harness = ROOT / "prover/sim/bench/continuation/cairo"
    build(ROOT / "cairo", ["-p", "doom_run"])
    build(harness, [])
    out = ROOT / "client/public/sim"
    out.mkdir(parents=True, exist_ok=True)
    for name in ["hellproof_sim.js", "hellproof_sim_bg.wasm"]:
        shutil.copyfile(args.pkg / name, out / name)
    shutil.copytree(args.pkg / "snippets", out / "snippets", dirs_exist_ok=True)
    programs = {
        "session": harness / "target/proving/session.executable.json",
        "genesis": ROOT / "cairo/target/proving/genesis.executable.json",
        "step": ROOT / "cairo/target/proving/step_tic.executable.json",
    }
    hashes = {}
    for name, source in programs.items():
        target = out / f"{name}.json"
        shutil.copyfile(source, target)
        hashes[name] = hashlib.sha256(target.read_bytes()).hexdigest()
    hashes["wasm"] = WASM_SHA
    manifest = dict(version=1, stateSchema=2, snapshotSchema=2,
                    revision=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                    hashes=hashes)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()

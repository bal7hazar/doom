#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Bytecode (and a few step costs) under each compiler-level configuration
(docs/spikes/S7.md §3): `unsafe-panic`, `inlining-strategy` thresholds and
the other `[cairo]` keys, for the crates' size benches and for the whole
`doom_run` program.

For every configuration the script appends a temporary
`[profile.s7-<cfg>.cairo]` table to the manifests involved (the standalone
bench packages, and the workspace manifest for `doom_run`), builds with
`scarb --profile s7-<cfg>`, reads `program.bytecode` of the executables,
and — for the physics bench — measures `try_move` and `check_sight` steps
differentially. The manifests are restored afterwards, whatever happens.

Usage:
    python3 infra/bytecode_matrix.py [--configs default,unsafe,...] [--no-steps]
    python3 infra/bytecode_matrix.py --json out.json
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CAIRO = REPO / "cairo"
WORKSPACE_MANIFEST = CAIRO / "Scarb.toml"
PHYS = CAIRO / "doom" / "doom_physics" / "bench"
MONS = CAIRO / "doom" / "doom_monsters" / "bench"
RE_RESOURCE = re.compile(r"^\s*([a-z_0-9 ]+):\s*([0-9,]+)\s*$")

# name -> [cairo] keys of the profile
CONFIGS: dict[str, dict[str, object]] = {
    "default": {},
    "unsafe": {"unsafe-panic": True},
    "inl0": {"inlining-strategy": 0},
    "inl5": {"inlining-strategy": 5},
    "inl20": {"inlining-strategy": 20},
    "inl50": {"inlining-strategy": 50},
    "avoid": {"inlining-strategy": "avoid"},
    "unsafe_inl20": {"unsafe-panic": True, "inlining-strategy": 20},
    "unsafe_inl50": {"unsafe-panic": True, "inlining-strategy": 50},
    "unsafe_avoid": {"unsafe-panic": True, "inlining-strategy": "avoid"},
    "backtrace": {"panic-backtrace": True},
    "replace_ids": {"sierra-replace-ids": True},
    "gas": {"enable-gas": True},
}

# (label, manifest dir of the executable package, manifest that carries the
# profile table for it, member flag for the workspace build)
TARGETS = [
    ("physics size", PHYS / "size", PHYS / "size" / "Scarb.toml", None),
    ("physics baseline", PHYS / "baseline", PHYS / "baseline" / "Scarb.toml", None),
    ("physics bench", PHYS, PHYS / "Scarb.toml", None),
    ("monsters size", MONS / "size", MONS / "size" / "Scarb.toml", None),
    ("monsters baseline", MONS / "baseline", MONS / "baseline" / "Scarb.toml", None),
    ("doom_run", CAIRO, WORKSPACE_MANIFEST, "doom_run"),
]


def toml_value(v: object) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    return '"%s"' % v


def profile_name(cfg: str) -> str:
    # Scarb profile names: alphanumeric and dashes only.
    return "s7-%s" % cfg.replace("_", "-")


def profile_table(cfg: str, keys: dict[str, object]) -> str:
    merged: dict[str, object] = {"enable-gas": False}
    merged.update(keys)
    body = "".join("%s = %s\n" % (k, toml_value(v)) for k, v in merged.items())
    name = profile_name(cfg)
    return (
        "\n# --- temporary, written by infra/bytecode_matrix.py ---\n[profile.%s]\ninherits = \"dev\"\n"
        "[profile.%s.cairo]\n%s" % (name, name, body)
    )


def scarb(args: list[str], cwd: Path) -> subprocess.CompletedProcess:
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    return subprocess.run(["scarb", *args], cwd=str(cwd), capture_output=True, text=True, env=env)


def words_of(target_dir: Path) -> int | None:
    files = sorted(target_dir.glob("*.executable.json"))
    if not files:
        return None
    return len(json.loads(files[0].read_text())["program"]["bytecode"])


def steps(op: int, n: int, cwd: Path, profile: str) -> dict[str, int] | None:
    p = scarb(
        ["--profile", profile, "execute", "--no-build", "--output", "none",
         "--print-resource-usage", "--arguments", "%d,%d" % (op, n)],
        cwd,
    )
    if p.returncode != 0:
        return None
    out: dict[str, int] = {}
    for line in p.stdout.splitlines():
        m = RE_RESOURCE.match(line)
        if m:
            out[m.group(1).strip()] = int(m.group(2).replace(",", ""))
    return out if "steps" in out else None


def net_steps(op: int, base: int, cwd: Path, profile: str, n: int = 20) -> float | None:
    vals = []
    for o in (op, base):
        lo, hi = steps(o, n, cwd, profile), steps(o, 2 * n, cwd, profile)
        if lo is None or hi is None:
            return None
        vals.append((hi["steps"] - lo["steps"]) / n)
    return round(vals[0] - vals[1], 1)


def main() -> int:
    args = sys.argv[1:]
    configs = list(CONFIGS)
    with_steps = True
    out_json = None
    while args:
        a = args.pop(0)
        if a == "--configs":
            configs = args.pop(0).split(",")
        elif a == "--no-steps":
            with_steps = False
        elif a == "--json":
            out_json = Path(args.pop(0))
        else:
            raise SystemExit(__doc__)

    manifests = {m for _, _, m, _ in TARGETS}
    originals = {m: m.read_text() for m in manifests}
    results: dict[str, dict[str, object]] = {}
    try:
        for cfg in configs:
            keys = CONFIGS[cfg]
            profile = profile_name(cfg)
            for m in manifests:
                m.write_text(originals[m] + profile_table(cfg, keys))
            row: dict[str, object] = {}
            for label, pkg, _, member in TARGETS:
                cmd = ["--profile", profile, "build"] + (["-p", member] if member else [])
                p = scarb(cmd, pkg)
                if p.returncode != 0:
                    err = (p.stdout + p.stderr).strip().splitlines()
                    row[label] = "FAIL: " + (err[-1][:80] if err else "?")
                    continue
                tdir = pkg / "target" / profile
                w = words_of(tdir)
                row[label] = w if w is not None else "FAIL: no executable"
            if isinstance(row.get("physics size"), int) and isinstance(row.get("physics baseline"), int):
                row["physics code"] = row["physics size"] - row["physics baseline"]
            if isinstance(row.get("monsters size"), int) and isinstance(row.get("monsters baseline"), int):
                row["monsters code"] = row["monsters size"] - row["monsters baseline"]
            if with_steps and isinstance(row.get("physics bench"), int):
                row["try_move steps"] = net_steps(3, 2, PHYS, profile)
                row["check_sight 300u steps"] = net_steps(7, 1, PHYS, profile)
            results[cfg] = row
            print("%-13s %s" % (cfg, "  ".join("%s=%s" % (k, v) for k, v in row.items())), flush=True)
    finally:
        for m, text in originals.items():
            m.write_text(text)

    cols = ["physics code", "monsters code", "doom_run", "try_move steps", "check_sight 300u steps"]
    print("\n| config | " + " | ".join(cols) + " |")
    print("|---|" + "---:|" * len(cols))
    for cfg, row in results.items():
        keys = CONFIGS[cfg]
        name = cfg if not keys else "`%s`" % ", ".join("%s = %s" % (k, toml_value(v)) for k, v in keys.items())
        print("| %s | %s |" % (name, " | ".join(str(row.get(c, "")) for c in cols)))
    if out_json:
        out_json.write_text(json.dumps(results, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

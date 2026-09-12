#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check the Hellproof Cairo workspace's crate dependency graph.

Runs `scarb metadata --format-version 1` against the `cairo/` workspace
(the parent-parent directory of this script, i.e. `<repo>/cairo`) and
fails (non-zero exit code) if either of the two rules from PLAN.md §3.1
(decision A10, rule 2) is violated:

  1. No package under `cairo/crates/*` (a generic, Doom-agnostic crate) may
     depend, directly or transitively, on any package under `cairo/doom/*`
     (the Doom-specific crates). Dependencies only flow the other way.
  2. The workspace's package dependency graph must be acyclic.

Only the workspace's own member packages are considered; external
dependencies (`core`, `cairo_test`, `cairo_execute`, ...) and dev-only
dependencies are ignored, since they are irrelevant to both rules and
never form part of a cycle in practice.

Usage: `python3 infra/check_crate_graph.py` (stdlib only, no third-party
dependencies; requires `scarb` on PATH).
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

GENERIC_PREFIX = "/cairo/crates/"
DOOM_PREFIX = "/cairo/doom/"


def run_scarb_metadata(cairo_dir: Path) -> dict:
    try:
        result = subprocess.run(
            ["scarb", "metadata", "--format-version", "1"],
            cwd=str(cairo_dir),
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        print("error: `scarb` was not found on PATH", file=sys.stderr)
        sys.exit(2)

    if result.returncode != 0:
        print("error: `scarb metadata` failed:", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        sys.exit(2)

    return json.loads(result.stdout)


def classify(manifest_path: str) -> str | None:
    """Return "generic", "doom", or None (neither) for a package manifest."""
    normalized = manifest_path.replace("\\", "/")
    if GENERIC_PREFIX in normalized:
        return "generic"
    if DOOM_PREFIX in normalized:
        return "doom"
    return None


def build_graph(metadata: dict) -> tuple[dict[str, str], dict[str, set[str]]]:
    """Return (package_id -> kind, package_id -> set of dependency ids),
    restricted to workspace member packages and non-dev dependencies."""
    member_ids: set[str] = set(metadata["workspace"]["members"])
    packages_by_id = {p["id"]: p for p in metadata["packages"] if p["id"] in member_ids}
    packages_by_name = {p["name"]: p for p in packages_by_id.values()}

    kinds: dict[str, str] = {}
    graph: dict[str, set[str]] = {}

    for pkg_id, pkg in packages_by_id.items():
        kind = classify(pkg["manifest_path"])
        if kind is not None:
            kinds[pkg_id] = kind
        graph[pkg_id] = set()

        for dep in pkg.get("dependencies", []):
            if dep.get("kind") is not None:
                # Skip dev-only dependencies (e.g. cairo_test): they are
                # test-time only and out of scope for both graph rules.
                continue
            dep_pkg = packages_by_name.get(dep["name"])
            if dep_pkg is None:
                # External dependency (core, cairo_execute, starknet, ...),
                # not a workspace member: irrelevant to both rules.
                continue
            graph[pkg_id].add(dep_pkg["id"])

    return kinds, graph


def find_forbidden_edges(kinds: dict[str, str], graph: dict[str, set[str]]) -> list[tuple[str, str]]:
    violations = []
    for pkg_id, deps in graph.items():
        if kinds.get(pkg_id) != "generic":
            continue
        for dep_id in deps:
            if kinds.get(dep_id) == "doom":
                violations.append((pkg_id, dep_id))
    return violations


def find_cycle(graph: dict[str, set[str]]) -> list[str] | None:
    """DFS-based cycle detection. Returns one offending cycle (as a list of
    package ids) if the graph has one, otherwise None."""
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {node: WHITE for node in graph}
    stack: list[str] = []

    def visit(node: str) -> list[str] | None:
        color[node] = GRAY
        stack.append(node)
        for neighbor in sorted(graph.get(node, ())):
            if color[neighbor] == GRAY:
                cycle_start = stack.index(neighbor)
                return stack[cycle_start:] + [neighbor]
            if color[neighbor] == WHITE:
                found = visit(neighbor)
                if found is not None:
                    return found
        stack.pop()
        color[node] = BLACK
        return None

    for node in sorted(graph):
        if color[node] == WHITE:
            found = visit(node)
            if found is not None:
                return found
    return None


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    cairo_dir = script_dir.parent / "cairo"
    if not cairo_dir.is_dir():
        print(f"error: expected a `cairo/` workspace at {cairo_dir}", file=sys.stderr)
        return 2

    metadata = run_scarb_metadata(cairo_dir)
    kinds, graph = build_graph(metadata)

    ok = True

    violations = find_forbidden_edges(kinds, graph)
    if violations:
        ok = False
        print("error: forbidden dependency from a generic crate onto a doom crate:")
        for src, dst in sorted(violations):
            print(f"  - {src} -> {dst}")

    cycle = find_cycle(graph)
    if cycle is not None:
        ok = False
        print("error: dependency cycle detected:")
        print("  " + " -> ".join(cycle))

    if ok:
        generic_count = sum(1 for k in kinds.values() if k == "generic")
        doom_count = sum(1 for k in kinds.values() if k == "doom")
        print(
            f"ok: {len(graph)} workspace package(s) checked "
            f"({generic_count} generic, {doom_count} doom) -- "
            "no crates/* -> doom/* edge, no cycle.",
        )
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The **real** ten-felt batch: reads one `spikes/s4/scripts/run_pipeline10.sh` run and turns
it into everything the consumer side needs (P4.2b).

`doomruns_model.py` builds *synthetic* batches — the right shape, invented values. This module
builds the same structure from a batch that was actually **proved**: the leaves are the output
preimages the leaf bootloader dumped, the circuit hashes are the ones the recursive tree used,
and the `output_hash` is the one `stwo_circuit_verifier` returned for the root proof. That is
what closes the first gap of `docs/design/doomruns.md`: until now nothing bound `DoomRuns` to a
root whose leaves carry the ten felts of D14.

What it checks while loading (every one of these is an assertion, not a print):

* each leaf preimage is `[program_hash, out_0 … out_9]` — 11 felts, one program hash for all;
* the preimages dumped per leaf are the ones the tree folded (`packed_output.json`);
* the blake2s recomposition of those preimages reproduces the root's `program_output`;
* and `verification_output_hash(root)` is the verifier's own `output_hash`.

Then `fact = poseidon(multiverifier_hash ‖ output_hash)` is the fact P4.0's router registers.

    tools/real_batch.py ../../spikes/s4/results/B2_doom            # print and check
    tools/real_batch.py ../../spikes/s4/results/B2_doom --json out.json
    tools/real_batch.py <dirs…> --emit-fixtures                    # Cairo test fixtures
    tools/real_batch.py <dirs…> --install                          # copy artifacts into fixtures/
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

from doomruns_model import (
    EXIT,
    Leaf,
    compute_fact,
    fold_tree,
    leaf_output,
    run_id_of,
    short_string,
    verification_output_hash,
)

HERE = Path(__file__).resolve().parent
PACKAGE_DIR = HERE.parent

FIELDS = ["version", "h_in", "h_out", "tic_start", "tic_end", "status",
          "inputs_commitment", "kills", "items", "secrets"]


def walk(node: dict, leaves: list, leaf_hashes: list, mv_hashes: list) -> None:
    """`packed_output.json` -> the leaf preimages in fold order and the two circuit hashes."""
    comp = node["Composite"]
    subs = comp["subtasks"]
    if len(subs) == 1 and "Plain" in subs[0]:
        leaf_hashes.append(tuple(comp["circuit_hash"]))
        leaves.append([int(x) for x in subs[0]["Plain"]["output_preimage"]])
        return
    mv_hashes.append(tuple(comp["circuit_hash"]))
    for sub in subs:
        walk(sub, leaves, leaf_hashes, mv_hashes)


def load(results: Path) -> dict:
    """One `run_pipeline10.sh` results directory -> the checked batch."""
    plan = json.loads((results / "batch.json").read_text())
    packed = json.loads((results / "packed_output.json").read_text())
    program_output = json.loads((results / "program_output.json").read_text())

    preimages: list[list[int]] = []
    leaf_hashes: list[tuple] = []
    mv_hashes: list[tuple] = []
    walk(packed, preimages, leaf_hashes, mv_hashes)
    assert len(set(leaf_hashes)) == 1, "all leaves share one leaf circuit hash"
    assert len(set(mv_hashes)) == 1, "all folds share one multiverifier circuit hash"
    leaf_circuit_hash, multiverifier_hash = list(leaf_hashes[0]), list(mv_hashes[0])

    # The per-leaf dumps must be the preimages the tree folded, in the same order.
    dumped = [[int(h, 16) for h in json.loads((results / f"preimage_{i}.json").read_text())]
              for i in range(len(preimages))]
    assert dumped == preimages, "preimage dumps disagree with the folded tree"

    program_hashes = {p[0] for p in preimages}
    assert len(program_hashes) == 1, f"several program hashes: {program_hashes}"
    program_hash = program_hashes.pop()
    for p in preimages:
        assert len(p) == 11, f"leaf preimage is {len(p)} felts, expected 1 + 10 (D14)"

    leaves = [Leaf(zip(FIELDS, p[1:])) for p in preimages]
    for leaf, planned in zip(leaves, plan["leaves"]):
        assert leaf.felts == [int(x) for x in planned["output"]], "proved leaf != planned leaf"

    # The recomposition, against the folder's own root output and against the verifier's hash.
    nodes = [(leaf_circuit_hash, leaf_output(p)) for p in preimages]
    root = fold_tree(nodes, multiverifier_hash)
    assert list(root[1]) == program_output, "recomposed root output != program_output.json"
    output_hash = verification_output_hash(root)
    verifier_path = results / "verifier_output.json"
    verifier_output = None
    if verifier_path.exists():
        verifier_output = json.loads(verifier_path.read_text())
        assert output_hash == verifier_output, "recomposed output_hash != the verifier's"

    genesis = int(plan["genesis"], 16)
    members = []
    for m in plan["members"]:
        own = leaves[m["leaf_start"]: m["leaf_start"] + m["leaf_len"]]
        assert own[-1]["status"] == EXIT, "the last segment of a game must be EXIT here"
        members.append({**m, "run_id": run_id_of(plan["version_id"], m["level_id"],
                                                 genesis, own)})
    return {
        "name": results.name,
        "shape": plan["shape"],
        "version_id": plan["version_id"],
        "level_id": plan["level_id"],
        "genesis": genesis,
        "program_hash": program_hash,
        "program_hash_function": short_string("blake"),
        "registry_name": short_string(results.name.split("_", 1)[1]),
        "leaf_circuit_hash": leaf_circuit_hash,
        "multiverifier_hash": multiverifier_hash,
        "leaves": leaves,
        "logs": [[int(w) for w in leaf["packed"]] for leaf in plan["leaves"]],
        "members": members,
        "root_output": program_output,
        "output_hash": output_hash,
        "verifier_output": verifier_output,
        "fact": compute_fact(multiverifier_hash, output_hash),
    }


def as_json(batch: dict) -> dict:
    """The batch as a client would receive it from `GET /v1/batches/{id}` (+ the identities the
    version table pins), hex for every felt-sized value."""
    return {
        "name": batch["name"],
        "shape": batch["shape"],
        "version_id": batch["version_id"],
        "level_id": batch["level_id"],
        "genesis": hex(batch["genesis"]),
        "program_hash": hex(batch["program_hash"]),
        "program_hash_function": "blake",
        "registry_name": "doom",
        "leaf_circuit_hash": batch["leaf_circuit_hash"],
        "multiverifier_hash": batch["multiverifier_hash"],
        "root_output": batch["root_output"],
        "output_hash": batch["output_hash"],
        "fact": hex(batch["fact"]),
        "leaves": [{k: hex(v) if k in ("h_in", "h_out", "inputs_commitment", "version") else v
                    for k, v in leaf.items()} for leaf in batch["leaves"]],
        "logs": [[hex(w) for w in log] for log in batch["logs"]],
        "members": [{**m, "run_id": hex(m["run_id"])} for m in batch["members"]],
    }


# --- Cairo fixture emission -------------------------------------------------

def words(ws) -> str:
    return "[" + ", ".join(str(w) for w in ws) + "]"


def cairo_leaf(leaf: Leaf) -> str:
    return ("        LeafOutput {{ version: {version}, h_in: {h_in}, h_out: {h_out}, "
            "tic_start: {tic_start}, tic_end: {tic_end}, status: {status}, "
            "inputs_commitment: {ic}, kills: {kills}, items: {items}, secrets: {secrets} }},"
            ).format(ic=leaf["inputs_commitment"], **{k: leaf[k] for k in FIELDS
                                                      if k != "inputs_commitment"})


def emit_recursion_fixtures(batches: list[dict], path: Path) -> None:
    """`recursion_outputs/tests/fixtures_10felt.cairo`: the recomposition of the real ten-felt
    roots, against the folder's root output and the on-chain verifier's `output_hash`."""
    lines = [
        "// SPDX-License-Identifier: Apache-2.0",
        "//! GENERATED by `tools/real_batch.py --emit-fixtures` — do not edit.",
        "//!",
        "//! The **ten-felt** root proofs of P4.2b: `spikes/s4/programs/segment_stub10` returns",
        "//! the full D14 segment output, so each leaf preimage below is",
        "//! `[program_hash, version, h_in, h_out, tic_start, tic_end, status,",
        "//! inputs_commitment, kills, items, secrets]` — exactly what",
        "//! `doom_runs::segment::to_preimage` builds from a `LeafOutput`. `root.output` is the",
        "//! `program_output.json` the recursive tree wrote and",
        "//! `verification_output_hash` is the `output_hash` `stwo_circuit_verifier` returned",
        "//! for that root proof (fixtures/, and `cairo/doom_contracts/README.md`).",
        "use recursion_outputs::tree::{fold_tree, leaf_node, verification_output_hash};",
        "",
    ]
    for batch in batches:
        name = batch["name"].lower().replace("-", "_")
        lines += [
            f"/// {len(batch['leaves'])} leaves, {len(batch['shape'])} game(s) "
            f"{batch['shape']}, from spikes/s4/results/{batch['name']}/.",
            "#[test]",
            f"fn fixture_{name}_10felt() {{",
            f"    let leaf_hash: [u32; 8] = {words(batch['leaf_circuit_hash'])};",
            f"    let mv_hash: [u32; 8] = {words(batch['multiverifier_hash'])};",
            "    let leaves = array![",
        ]
        for leaf in batch["leaves"]:
            preimage = [batch["program_hash"]] + leaf.felts
            lines.append("        leaf_node(leaf_hash, array![" +
                         ", ".join(str(x) for x in preimage) + "].span()),")
        lines += [
            "    ];",
            "    let root = fold_tree(leaves.span(), mv_hash);",
            f"    assert_eq!(root.output, {words(batch['root_output'])});",
            f"    assert_eq!(verification_output_hash(@root), {words(batch['output_hash'])});",
            "}",
            "",
        ]
    path.write_text("\n".join(lines))
    print("->", path)


def emit_doomruns_fixtures(batches: list[dict], path: Path) -> None:
    """`doom_runs/tests/fixtures_real.cairo`: the same batches as `LeafOutput`s, with the fact
    the router registers, the packed logs and the run ids."""
    lines = [
        "// SPDX-License-Identifier: Apache-2.0",
        "//! GENERATED by `tools/real_batch.py --emit-fixtures` — do not edit.",
        "//!",
        "//! The **proved** batches of P4.2b. Every leaf below is the tail of a leaf",
        "//! bootloader's output preimage from a real `leaf-prover` run over",
        "//! `spikes/s4/programs/segment_stub10` (ten felts, D14); `OUTPUT_HASH` is what",
        "//! `stwo_circuit_verifier` returned for the folded root proof and `FACT` is",
        "//! `poseidon(multiverifier_hash ‖ output_hash)`, the fact P4.0's router registers.",
        "//! The run ids come from the independent Python model.",
        "//!",
        "//! Artifacts (preimages, packed/program/verifier output, batch plan):",
        "//! `crates/recursion_outputs/fixtures/` and `crates/doom_runs/fixtures/`.",
        "use doom_runs::segment::LeafOutput;",
        "",
    ]
    for batch in batches:
        name = batch["name"].lower().replace("-", "_")
        up = name.upper()
        lines += [
            f"/// {len(batch['leaves'])} leaves, {len(batch['shape'])} game(s) "
            f"{batch['shape']}, registry `doom`, blake program hash.",
            f"pub const {up}_PROGRAM_HASH: felt252 = {batch['program_hash']};",
            f"pub const {up}_GENESIS: felt252 = {batch['genesis']};",
            f"pub const {up}_FACT: felt252 = {batch['fact']};",
            "",
            f"pub fn {name}_leaf_circuit_hash() -> [u32; 8] {{",
            f"    {words(batch['leaf_circuit_hash'])}",
            "}",
            "",
            f"pub fn {name}_multiverifier_hash() -> [u32; 8] {{",
            f"    {words(batch['multiverifier_hash'])}",
            "}",
            "",
            "/// The `output_hash` the on-chain verifier returned for this root proof.",
            f"pub fn {name}_output_hash() -> [u32; 8] {{",
            f"    {words(batch['output_hash'])}",
            "}",
            "",
            "/// The batch's leaves, in fold order.",
            f"pub fn {name}_leaves() -> Array<LeafOutput> {{",
            "    array![",
        ]
        lines += [cairo_leaf(leaf) for leaf in batch["leaves"]]
        lines += [
            "    ]",
            "}",
            "",
            "/// `(leaf_start, leaf_len, level_id, run_id)` of each game.",
            f"pub fn {name}_members() -> Array<(u32, u32, u32, felt252)> {{",
            "    array![",
        ]
        lines += [f"        ({m['leaf_start']}, {m['leaf_len']}, {m['level_id']}, "
                  f"{m['run_id']})," for m in batch["members"]]
        lines += [
            "    ]",
            "}",
            "",
            "/// The packed input log of each leaf (7 tics per felt), as the program folded it.",
            f"pub fn {name}_logs() -> Array<Array<felt252>> {{",
            "    array![",
        ]
        for log in batch["logs"]:
            lines.append("        array![" + ", ".join(str(w) for w in log) + "],")
        lines += ["    ]", "}", ""]
    path.write_text("\n".join(lines))
    print("->", path)


# --- artifact installation --------------------------------------------------

RECURSION_ARTIFACTS = ["batch.json", "packed_output.json", "program_output.json",
                       "verifier_output.json", "verify.log", "registry.json", "times.txt",
                       "tree_info.log"]
MAX_COMMITTED_BYTES = 1_000_000


def install(results: Path, batch: dict) -> list[str]:
    """Copies the small artifacts of one run into the two crates' `fixtures/` directories."""
    notes = []
    dst = PACKAGE_DIR / "crates/recursion_outputs/fixtures" / results.name
    dst.mkdir(parents=True, exist_ok=True)
    for name in RECURSION_ARTIFACTS:
        src = results / name
        if src.exists():
            shutil.copy2(src, dst / name)
    for i in range(len(batch["leaves"])):
        shutil.copy2(results / f"preimage_{i}.json", dst / f"preimage_{i}.json")
    proof = results / "root.proof.gz"
    if proof.exists():
        size = proof.stat().st_size
        if size < MAX_COMMITTED_BYTES:
            shutil.copy2(proof, dst / "root.proof.gz")
            notes.append(f"{results.name}: root.proof.gz committed ({size:,} bytes)")
        else:
            notes.append(f"{results.name}: root.proof.gz NOT committed ({size:,} bytes > "
                         f"{MAX_COMMITTED_BYTES:,}); regenerate with "
                         f"`spikes/s4/scripts/run_pipeline10.sh {','.join(map(str, batch['shape']))} doom`")
    runs_dst = PACKAGE_DIR / "crates/doom_runs/fixtures"
    runs_dst.mkdir(parents=True, exist_ok=True)
    out = runs_dst / f"{results.name.lower().replace('-', '_')}.json"
    out.write_text(json.dumps(as_json(batch), indent=1))
    notes.append(f"-> {out}")
    notes.append(f"-> {dst}")
    return notes


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("results", nargs="+", type=Path,
                    help="spikes/s4/results/B<shape>_<registry> directories")
    ap.add_argument("--json", type=Path, help="dump the first batch as JSON")
    ap.add_argument("--emit-fixtures", action="store_true")
    ap.add_argument("--install", action="store_true", help="copy artifacts into fixtures/")
    cfg = ap.parse_args()

    batches = [load(path.resolve()) for path in cfg.results]
    for batch in batches:
        print(f"{batch['name']}: {len(batch['leaves'])} leaves, shape {batch['shape']}, "
              f"program_hash {hex(batch['program_hash'])}")
        print(f"  output_hash {batch['output_hash']}")
        print(f"  fact        {hex(batch['fact'])}"
              f"{'' if batch['verifier_output'] else '   (no verifier output recorded)'}")
        for m, leaf_range in zip(batch["members"], batch["shape"]):
            own = batch["leaves"][m["leaf_start"]: m["leaf_start"] + m["leaf_len"]]
            last = own[-1]
            print(f"  game {m['game']}: leaves {m['leaf_start']}..{m['leaf_start'] + leaf_range}"
                  f"  tics {last['tic_end']}  kills {last['kills']}  run_id {hex(m['run_id'])}")
    if cfg.json:
        cfg.json.write_text(json.dumps(as_json(batches[0]), indent=1))
        print("->", cfg.json)
    if cfg.emit_fixtures:
        emit_recursion_fixtures(
            batches, PACKAGE_DIR / "crates/recursion_outputs/tests/fixtures_10felt.cairo")
        emit_doomruns_fixtures(
            batches, PACKAGE_DIR / "crates/doom_runs/tests/fixtures_real.cairo")
    if cfg.install:
        for path, batch in zip(cfg.results, batches):
            for note in install(path.resolve(), batch):
                print(" ", note)


if __name__ == "__main__":
    main()

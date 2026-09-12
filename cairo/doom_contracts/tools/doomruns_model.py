#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent Python model of what `DoomRuns` computes, and the batch builder
both the snforge fixtures and the devnet drive use.

Nothing here shares code with the Cairo side:

* the segment output layout and the input-log commitment come from
  `cairo/crates/segment/bench/reference.py` (D13/D14);
* the leaf output, the fold and `VerificationOutput.output_hash` are
  re-implemented from `docs/spikes/S4.md` §4 with `hashlib.blake2s`;
* `fact = poseidon(circuit_hash ‖ output_hash)` as in
  `docs/design/onchain-verifier.md` §6.

`python3 doomruns_model.py --emit-fixtures` regenerates
`crates/doom_runs/tests/fixtures.cairo` (follow it with `scarb fmt` in
`crates/doom_runs`); with no flag it only prints the vectors.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from poseidon_py.poseidon_hash import poseidon_hash, poseidon_hash_many

# --- the segment public output (D14) ---------------------------------------

VERSION = 1
OUTPUT_LEN = 10
SCHEMA_VERSION = 1
TICS_PER_FELT = 7

RUNNING, DEAD, EXIT, ABORT = 0, 1, 2, 3


def short_string(text: str) -> int:
    return int.from_bytes(text.encode("ascii"), "big")


TAG_INPUT_LOG = short_string("HP.INPUTS")
TAG_RUN = short_string("HP.RUN")

# Real S4 identities (registry `doom`, blake program hash of `segment_stub`), so the
# synthetic batches below have production-shaped circuit hashes.
LEAF_CIRCUIT_HASH = [718614224, 1263822076, 56819575, 3833232560,
                     2918774728, 3404701363, 2340910266, 2665138146]
MULTIVERIFIER_HASH = [0xA5989715, 0x2377C07A, 0xC6D1E844, 0x54F0A04D,
                      0x8BE65A7D, 0xFD73C261, 0x9078E728, 0x973F680F]
PROGRAM_HASH = 2784737126826178369939993031080194949960354326733421464854849544232566095676
PROGRAM_HASH_FUNCTION = short_string("blake")
REGISTRY_NAME = short_string("doom")


def inputs_seed() -> int:
    return poseidon_hash_many([TAG_INPUT_LOG, SCHEMA_VERSION, 0])


def commit_log(packed: list[int]) -> int:
    commitment = inputs_seed()
    for felt in packed:
        commitment = poseidon_hash(commitment, felt)
    return commitment


def pack_log(words: list[int]) -> list[int]:
    return [
        sum(w << (32 * i) for i, w in enumerate(words[g: g + TICS_PER_FELT]))
        for g in range(0, len(words), TICS_PER_FELT)
    ]


def packed_len(tics: int) -> int:
    return (tics + TICS_PER_FELT - 1) // TICS_PER_FELT


# --- the recursive tree's output hashing (S4 §4) ---------------------------

def encode_felt(x: int) -> list[int]:
    """Cairo0 `encode_felt252_data`: small felts as 2 big-endian words, others as
    8 with the MSB of the first set."""
    limbs = [(x >> (32 * i)) & 0xFFFFFFFF for i in range(8)]
    if x < (1 << 63):
        return [limbs[1], limbs[0]]
    return [limbs[7] + 0x80000000] + limbs[6::-1]


def encode_felts(felts: list[int]) -> list[int]:
    out: list[int] = []
    for x in felts:
        out += encode_felt(x)
    return out


def hash_u32s(words: list[int]) -> list[int]:
    data = b"".join(w.to_bytes(4, "little") for w in words)
    digest = hashlib.blake2s(data, digest_size=32).digest()
    return [int.from_bytes(digest[i: i + 4], "little") for i in range(0, 32, 4)]


def leaf_output(preimage: list[int]) -> list[int]:
    return hash_u32s(encode_felts(preimage))


def fold_pair(left: tuple, right: tuple, mv: list[int]) -> tuple:
    words = list(left[0]) + list(left[1]) + list(right[0]) + list(right[1])
    return (mv, hash_u32s(words))


def fold_tree(leaves: list[tuple], mv: list[int]) -> tuple:
    assert leaves
    if len(leaves) == 1:
        return fold_pair(leaves[0], leaves[0], mv)
    layer = list(leaves)
    while len(layer) > 1:
        nxt = []
        for i in range(0, len(layer) - 1, 2):
            nxt.append(fold_pair(layer[i], layer[i + 1], mv))
        if len(layer) % 2:
            nxt.append(layer[-1])
        layer = nxt
    return layer[0]


def verification_output_hash(node: tuple) -> list[int]:
    return hash_u32s(list(node[0]) + list(node[1]))


def root_output_hash(preimages: list[list[int]], leaf_hash: list[int], mv: list[int]) -> list[int]:
    nodes = [(leaf_hash, leaf_output(p)) for p in preimages]
    return verification_output_hash(fold_tree(nodes, mv))


def compute_fact(circuit_hash: list[int], output_hash: list[int]) -> int:
    return poseidon_hash_many(list(circuit_hash) + list(output_hash))


# --- batch construction -----------------------------------------------------

def genesis_of(version_id: int, level_id: int) -> int:
    """The per-(version, level) genesis state hash the owner pins. In production it
    is the Poseidon hash of the level's initial `GameState`; here it is a fixed
    derived constant (docs/design/doomruns.md §3)."""
    return poseidon_hash_many([short_string("HP.GENESIS"), version_id, level_id])


class Leaf(dict):
    """The ten public felts of one segment."""

    @property
    def felts(self) -> list[int]:
        return [self["version"], self["h_in"], self["h_out"], self["tic_start"],
                self["tic_end"], self["status"], self["inputs_commitment"],
                self["kills"], self["items"], self["secrets"]]

    def preimage(self, program_hash: int = PROGRAM_HASH) -> list[int]:
        return [program_hash] + self.felts


def state_hash(seed: int, index: int) -> int:
    return poseidon_hash_many([short_string("HP.STATE"), seed, index])


def make_run(seed: int, n_segments: int, *, version_id: int = 1, level_id: int = 1,
             tics_per_segment: int = 35, final_status: int = EXIT,
             kills0: int = 2, tic_start: int = 0) -> tuple[list[Leaf], list[list[int]]]:
    """One game as `n_segments` chained segments, with its per-segment packed input
    logs. Returns (leaves, packed logs)."""
    leaves, logs = [], []
    h = genesis_of(version_id, level_id)
    t = tic_start
    for i in range(n_segments):
        words = [(0x00808080 + seed + 7 * i + j) & 0xFFFFFFFF for j in range(tics_per_segment)]
        packed = pack_log(words)
        h_out = state_hash(seed, i + 1)
        status = (final_status if i == n_segments - 1 else RUNNING)
        leaves.append(Leaf(
            version=VERSION, h_in=h, h_out=h_out,
            tic_start=t, tic_end=t + tics_per_segment, status=status,
            inputs_commitment=commit_log(packed),
            kills=kills0 * (i + 1), items=i, secrets=i // 2,
        ))
        logs.append(packed)
        h = h_out
        t += tics_per_segment
    return leaves, logs


def build_batch(shape: list[int], *, level_id: int = 1, version_id: int = 1,
                final_status: int = EXIT, tics_per_segment: int = 35, salt: int = 0) -> dict:
    """A batch of `len(shape)` games with `shape[i]` segments each, in fold order. `salt`
    makes two batches of the same shape distinct (distinct input logs, so distinct
    commitments, run ids and fact)."""
    leaves: list[Leaf] = []
    logs: list[list[int]] = []
    members = []
    for game, n in enumerate(shape):
        start = len(leaves)
        run_leaves, run_logs = make_run(1000 * (game + 1) + salt, n, version_id=version_id,
                                        level_id=level_id, final_status=final_status,
                                        tics_per_segment=tics_per_segment)
        leaves += run_leaves
        logs += run_logs
        members.append({"game": game, "leaf_start": start, "leaf_len": n,
                        "level_id": level_id})
    preimages = [leaf.preimage() for leaf in leaves]
    output_hash = root_output_hash(preimages, LEAF_CIRCUIT_HASH, MULTIVERIFIER_HASH)
    fact = compute_fact(MULTIVERIFIER_HASH, output_hash)
    for member in members:
        own = leaves[member["leaf_start"]: member["leaf_start"] + member["leaf_len"]]
        member["run_id"] = run_id_of(version_id, member["level_id"],
                                     genesis_of(version_id, member["level_id"]), own)
    return {"version_id": version_id, "leaves": leaves, "logs": logs, "members": members,
            "output_hash": output_hash, "fact": fact,
            "genesis": genesis_of(version_id, level_id)}


def run_id_of(version_id: int, level_id: int, genesis: int, own: list[Leaf]) -> int:
    words = [TAG_RUN, version_id, level_id, genesis, len(own)]
    words += [leaf["inputs_commitment"] for leaf in own]
    if own:
        words += [own[-1]["h_out"], own[-1]["tic_end"]]
    return poseidon_hash_many(words)


# --- fixture emission -------------------------------------------------------

def cairo_leaf(leaf: Leaf) -> str:
    return ("        LeafOutput {{ version: {version}, h_in: {h_in}, h_out: {h_out}, "
            "tic_start: {tic_start}, tic_end: {tic_end}, status: {status}, "
            "inputs_commitment: {ic}, kills: {kills}, items: {items}, secrets: {secrets} }},"
            ).format(version=leaf["version"], h_in=leaf["h_in"], h_out=leaf["h_out"],
                     tic_start=leaf["tic_start"], tic_end=leaf["tic_end"],
                     status=leaf["status"], ic=leaf["inputs_commitment"],
                     kills=leaf["kills"], items=leaf["items"], secrets=leaf["secrets"])


def emit_fixtures(path: Path) -> None:
    batch = build_batch([2, 1, 3])
    single = build_batch([1])
    lines = [
        "// SPDX-License-Identifier: Apache-2.0",
        "//! GENERATED by `tools/doomruns_model.py --emit-fixtures` — do not edit.",
        "//!",
        "//! A synthetic batch of three games (2 + 1 + 3 segments) with the **10-felt**",
        "//! segment outputs of D14, plus the single-leaf (self-fold) batch. Every value",
        "//! below — the input-log commitments, the recomposed `output_hash`, the fact and",
        "//! the run ids — is computed by the independent Python model in",
        "//! `tools/doomruns_model.py` (`poseidon_py` + `hashlib.blake2s`), never by the",
        "//! Cairo code these fixtures test. The circuit hashes and the program hash are the",
        "//! real ones of the S4 `doom` registry.",
        "use doom_runs::segment::LeafOutput;",
        "",
        f"pub const PROGRAM_HASH: felt252 = {PROGRAM_HASH};",
        f"pub const PROGRAM_HASH_FUNCTION: felt252 = '{'blake'}';",
        f"pub const REGISTRY_NAME: felt252 = '{'doom'}';",
        f"pub const GENESIS: felt252 = {batch['genesis']};",
        f"pub const FACT: felt252 = {batch['fact']};",
        f"pub const SINGLE_FACT: felt252 = {single['fact']};",
        f"pub const INPUTS_SEED: felt252 = {inputs_seed()};",
        "",
        "pub fn leaf_circuit_hash() -> [u32; 8] {",
        f"    {LEAF_CIRCUIT_HASH}".replace("[", "[").replace("]", "]"),
        "}",
        "",
        "pub fn multiverifier_hash() -> [u32; 8] {",
        f"    {[hex(w) for w in MULTIVERIFIER_HASH]}".replace("'", ""),
        "}",
        "",
        "pub fn output_hash() -> [u32; 8] {",
        f"    {batch['output_hash']}",
        "}",
        "",
        "/// The three games of the batch, in fold order: 2 + 1 + 3 segments.",
        "pub fn batch_leaves() -> Array<LeafOutput> {",
        "    array![",
    ]
    lines += [cairo_leaf(leaf) for leaf in batch["leaves"]]
    lines += [
        "    ]",
        "}",
        "",
        "/// `(leaf_start, leaf_len, run_id)` of each game.",
        "pub fn batch_members() -> Array<(u32, u32, felt252)> {",
        "    array![",
    ]
    lines += [f"        ({m['leaf_start']}, {m['leaf_len']}, {m['run_id']})," for m in batch["members"]]
    lines += [
        "    ]",
        "}",
        "",
        "/// The packed input log of each leaf of the batch (7 tics per felt).",
        "pub fn batch_logs() -> Array<Array<felt252>> {",
        "    array![",
    ]
    for log in batch["logs"]:
        lines.append("        array![" + ", ".join(str(w) for w in log) + "],")
    lines += [
        "    ]",
        "}",
        "",
        "/// A one-leaf batch: the tree folds the single leaf with itself.",
        "pub fn single_leaf() -> Array<LeafOutput> {",
        "    array![",
        cairo_leaf(single["leaves"][0]),
        "    ]",
        "}",
        "",
        "pub fn single_log() -> Array<felt252> {",
        "    array![" + ", ".join(str(w) for w in single["logs"][0]) + "]",
        "}",
        "",
        f"pub const SINGLE_RUN_ID: felt252 = {single['members'][0]['run_id']};",
        "",
        "/// `commit_log` of a nine-tic segment — the vector pinned by",
        "/// `cairo/crates/segment`'s `test_inputs_commitment_reference_vector`.",
        f"pub const NINE_TIC_COMMITMENT: felt252 = {commit_log(pack_log([0x00808080 + i for i in range(9)]))};",
        "pub fn nine_tic_log() -> Array<felt252> {",
        "    array![" + ", ".join(str(w) for w in pack_log([0x00808080 + i for i in range(9)])) + "]",
        "}",
        "",
    ]
    path.write_text("\n".join(lines))
    print(f"-> {path}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--emit-fixtures", action="store_true")
    ap.add_argument("--json", type=Path, help="dump the 2+1+3 batch as JSON")
    cfg = ap.parse_args()
    here = Path(__file__).resolve().parent
    if cfg.emit_fixtures:
        emit_fixtures(here.parent / "crates/doom_runs/tests/fixtures.cairo")
    batch = build_batch([2, 1, 3])
    print("inputs_seed        ", hex(inputs_seed()))
    print("nine-tic commitment", hex(commit_log(pack_log([0x00808080 + i for i in range(9)]))))
    print("genesis            ", hex(batch["genesis"]))
    print("output_hash        ", batch["output_hash"])
    print("fact               ", hex(batch["fact"]))
    for member in batch["members"]:
        print(f"  game {member['game']}: leaves {member['leaf_start']}"
              f"..{member['leaf_start'] + member['leaf_len']}  run_id {hex(member['run_id'])}")
    if cfg.json:
        cfg.json.write_text(json.dumps({
            "fact": hex(batch["fact"]),
            "output_hash": batch["output_hash"],
            "members": [{k: (hex(v) if k == "run_id" else v) for k, v in m.items()}
                        for m in batch["members"]],
        }, indent=1))


if __name__ == "__main__":
    main()

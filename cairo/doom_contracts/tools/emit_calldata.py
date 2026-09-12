#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Calldata emitter: splits a cairo-serde `CircuitProof` felt stream (the `root.proof` JSON
written by `stwo_run_and_prove_recursive_tree`, or the one-felt-per-line `.txt` fixture) into the
per-transaction calldata of the resumable verifier (`StwoCircuitRouter`, see
docs/design/onchain-verifier.md §4).

Sections are packed 7 little-endian u32 limbs per felt252 (`stwo_circuit_phases::pack`), each
section independently (its own zero-padded last slot). The head — the only section carrying u64
values (the two proof-of-work nonces) — uses the escaped encoding (a limb of 0xFFFFFFFF escapes
a (low, high) pair; a plain value >= 0xFFFFFFFF is escaped too); every other section uses the
fast-path encoding (one u32 per limb, no escapes: `unpack_u32`).

Output (`--out calls.json`): the ordered transactions with their entrypoint and arguments. The
checkpoint state echoed by every transaction after the first is NOT in the file: the driver
takes it from the previous transaction's return value (`tools/devnet_drive.py`).

Usage:
  tools/emit_calldata.py fixtures/n4_root_proof.txt --out calls.json [--fri-split 2]
      [--max-calldata 4990] [--proof-id 0x1]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ESCAPE = 0xFFFFFFFF
LIMBS_PER_SLOT = 7
QM31_FELTS = 4
HASH_FELTS = 8
N_TREES = 4
# Usable calldata felts of one invoke (5 000 minus the `__execute__` envelope, S5 / lane 1).
DEFAULT_MAX_CALLDATA = 4_990
# Serialized checkpoint sizes on the S4 fixture (`checkpoint_sizes_n4` test), used to size the
# echo of transactions 2..N: MerkleState and FriState (70 queries).
MERKLE_STATE_FELTS = 228
FRI_STATE_FELTS = 576


# ----------------------------------------------------------------------------- stream parsing


class Stream:
    def __init__(self, values: list[int]):
        self.v = values
        self.pos = 0

    def take(self, n: int) -> list[int]:
        r = self.v[self.pos : self.pos + n]
        if len(r) != n:
            sys.exit("truncated proof stream")
        self.pos += n
        return r

    def u(self) -> int:
        return self.take(1)[0]

    def array(self, elem_felts: int) -> list[int]:
        n = self.u()
        return [n] + self.take(n * elem_felts)

    def layer(self) -> list[int]:
        """`FriLayerProof`: fri_witness (Span<QM31>) ‖ decommitment (Span<Hash>) ‖ commitment."""
        return self.array(QM31_FELTS) + self.array(HASH_FELTS) + self.take(HASH_FELTS)


def parse(values: list[int]) -> dict:
    s = Stream(values)
    claim = s.array(QM31_FELTS)
    interaction_pow = s.take(1)
    interaction_claim = s.take(11 * QM31_FELTS)
    pcs_config = s.take(5)
    commitments = s.array(HASH_FELTS)
    # sampled_values: Span<Span<Span<QM31>>>
    start = s.pos
    n_trees = s.u()
    for _ in range(n_trees):
        n_cols = s.u()
        for _ in range(n_cols):
            s.array(QM31_FELTS)
    sampled = values[start : s.pos]
    n = s.u()
    decommitments = [s.array(HASH_FELTS) for _ in range(n)]
    n = s.u()
    queried_values = [s.array(1) for _ in range(n)]
    pow_nonce = s.take(1)
    first_layer = s.layer()
    n_inner = s.u()
    inner_layers = [s.layer() for _ in range(n_inner)]
    last_layer_poly = s.array(QM31_FELTS) + s.take(1)
    salt = s.take(1)
    if s.pos != len(values):
        sys.exit(f"trailing proof data: {len(values) - s.pos} felts")
    assert len(decommitments) == N_TREES and len(queried_values) == N_TREES
    layers = [first_layer] + inner_layers
    fri_head = layers[0][-HASH_FELTS:] + [n_inner]
    for l in inner_layers:
        fri_head += l[-HASH_FELTS:]
    fri_head += last_layer_poly
    head = (claim + interaction_pow + interaction_claim + pcs_config + commitments + sampled
            + pow_nonce + fri_head + salt)
    return {
        "head": head,
        "sampled": sampled,
        "queried_values": queried_values,
        "decommitments": decommitments,
        "layers": layers,
        "pcs_config": pcs_config,
    }


# ------------------------------------------------------------------------------------ packing


def pack(values: list[int]) -> list[int]:
    """Escaped encoding (the head)."""
    limbs: list[int] = []
    for v in values:
        if v < ESCAPE:
            limbs.append(v)
        else:
            if v >= 1 << 64:
                sys.exit(f"value {v:#x} does not fit the u64 escape")
            limbs += [ESCAPE, v & 0xFFFFFFFF, v >> 32]
    return pack_limbs(limbs)


def pack_u32(values: list[int]) -> list[int]:
    """Fast-path encoding: every value must be a u32."""
    for v in values:
        if v >= 1 << 32:
            sys.exit(f"pack_u32: value {v:#x} is not a u32")
    return pack_limbs(list(values))


def pack_limbs(limbs: list[int]) -> list[int]:
    while len(limbs) % LIMBS_PER_SLOT:
        limbs.append(0)
    slots = []
    for i in range(0, len(limbs), LIMBS_PER_SLOT):
        slot = 0
        for j, limb in enumerate(limbs[i : i + LIMBS_PER_SLOT]):
            slot += limb << (32 * j)
        slots.append(slot)
    return slots


def unpack(slots: list[int], n_values: int) -> list[int]:
    limbs = []
    for slot in slots:
        for j in range(LIMBS_PER_SLOT):
            limbs.append((slot >> (32 * j)) & 0xFFFFFFFF)
    out, i = [], 0
    while len(out) != n_values:
        if limbs[i] == ESCAPE:
            out.append(limbs[i + 1] + (limbs[i + 2] << 32))
            i += 3
        else:
            out.append(limbs[i])
            i += 1
    return out


def slots_of(n_felts: int) -> int:
    return -(-n_felts // LIMBS_PER_SLOT)


# ------------------------------------------------------------------------------- transactions


def hexs(values: list[int]) -> list[str]:
    return [hex(v) for v in values]


def pack_sections(sections: list[list[int]]) -> list[int]:
    """Concatenation of the independently fast-path-packed sections."""
    return [slot for s in sections for slot in pack_u32(s)]


def tx_begin(sec: dict, trees: list[int], proof_id: int) -> dict:
    head = pack(sec["head"])
    sections = []
    for t in trees:
        sections += [sec["queried_values"][t], sec["decommitments"][t]]
    payload = pack_sections(sections)
    args = {"proof_id": proof_id, "head": head, "head_n": len(sec["head"]), "payload": payload,
            "lens": [len(s) for s in sections], "trees": trees}
    # proof_id, head (len + slots), head_n, payload (len + slots), lens (len + n), trees (len + n)
    felts = 1 + 1 + len(head) + 1 + 1 + len(payload) + 1 + len(sections) + 1 + len(trees)
    return {"label": "begin", "entrypoint": "begin", "echo": None, "calldata_felts": felts,
            "payload_slots": len(head) + len(payload), "args": args,
            "meta": {"sections": ["head"] + [f"qv{t}/dec{t}" for t in trees]}}


def tx_merkle(sec: dict, trees: list[int], proof_id: int) -> dict:
    sections = []
    for t in trees:
        sections += [sec["queried_values"][t], sec["decommitments"][t]]
    payload = pack_sections(sections)
    args = {"proof_id": proof_id, "payload": payload, "lens": [len(s) for s in sections],
            "trees": trees}
    felts = 1 + 1 + MERKLE_STATE_FELTS + 1 + len(payload) + 1 + len(sections) + 1 + len(trees)
    return {"label": "merkle", "entrypoint": "merkle", "echo": "merkle_state",
            "calldata_felts": felts, "payload_slots": len(payload), "args": args,
            "meta": {"sections": [f"qv{t}/dec{t}" for t in trees]}}


def tx_answers(sec: dict, proof_id: int) -> dict:
    sections = [sec["sampled"]] + sec["queried_values"]
    payload = pack_sections(sections)
    args = {"proof_id": proof_id, "payload": payload, "lens": [len(s) for s in sections]}
    felts = 1 + 1 + MERKLE_STATE_FELTS + 1 + len(payload) + 1 + len(sections)
    return {"label": "answers", "entrypoint": "answers", "echo": "merkle_state",
            "calldata_felts": felts, "payload_slots": len(payload), "args": args,
            "meta": {"sections": ["sampled", "qv0", "qv1", "qv2", "qv3"]}}


def tx_fri(sec: dict, first: int, last: int, proof_id: int, idx: int) -> dict:
    layers = sec["layers"][first:last]
    flat = [len(layers)] + [v for l in layers for v in l]
    payload = pack_u32(flat)
    args = {"proof_id": proof_id, "payload": payload, "n_values": len(flat)}
    felts = 1 + 1 + FRI_STATE_FELTS + 1 + len(payload) + 1
    return {"label": f"fri{idx}", "entrypoint": "fri", "echo": "fri_state",
            "calldata_felts": felts, "payload_slots": len(payload), "args": args,
            "meta": {"layers": list(range(first, last))}}


def plan(sec: dict, proof_id: int, fri_split: str, max_calldata: int) -> list[dict]:
    txs = [
        tx_begin(sec, [0, 1], proof_id),
        tx_merkle(sec, [2, 3], proof_id),
        tx_answers(sec, proof_id),
    ]
    n_layers = len(sec["layers"])
    inner_cuts = sorted({int(c) for c in fri_split.split(",") if 0 < int(c) < n_layers})
    cuts = [0] + inner_cuts + [n_layers]
    for i in range(len(cuts) - 1):
        txs.append(tx_fri(sec, cuts[i], cuts[i + 1], proof_id, i + 1))
    for tx in txs:
        if tx["calldata_felts"] > max_calldata:
            sys.exit(f"{tx['label']}: {tx['calldata_felts']} calldata felts > {max_calldata}; "
                     f"re-plan (e.g. --fri-split, or split the Merkle trees differently)")
    return txs


# --------------------------------------------------------------------------------------- main


def load(path: Path) -> list[int]:
    text = path.read_text()
    if path.suffix == ".json" or text.lstrip().startswith("["):
        raw = json.loads(text)
        return [int(x, 16) if isinstance(x, str) else int(x) for x in raw]
    return [int(l, 0) for l in text.split()]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("proof", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--proof-id", type=lambda s: int(s, 0), default=1)
    ap.add_argument("--fri-split", default="2",
                    help="comma-separated layer indices where the FRI walk is cut into "
                         "transactions (default '2': {first, inner 0} then {inner 1..4}; "
                         "'1,3' = 3 transactions; '6' = the whole walk in one transaction)")
    ap.add_argument("--max-calldata", type=int, default=DEFAULT_MAX_CALLDATA)
    a = ap.parse_args()

    values = load(a.proof)
    sec = parse(values)
    # Round-trip checks: the escaped encoding on the whole stream, the fast path on a section.
    assert unpack(pack(values), len(values)) == values
    assert unpack(pack_u32(sec["queried_values"][0]), len(sec["queried_values"][0])) == sec["queried_values"][0]
    txs = plan(sec, a.proof_id, a.fri_split, a.max_calldata)

    summary = {
        "proof": str(a.proof), "n_felts": len(values), "n_slots": slots_of(len(values)),
        "sections_felts": {
            "head": len(sec["head"]), "sampled": len(sec["sampled"]),
            "queried_values": [len(q) for q in sec["queried_values"]],
            "decommitments": [len(d) for d in sec["decommitments"]],
            "fri_layers": [len(l) for l in sec["layers"]],
        },
        "txs": [{**tx, "args": {k: (hexs(v) if isinstance(v, list) and k in ("payload", "head") else v)
                                for k, v in tx["args"].items()}} for tx in txs],
    }
    a.out.write_text(json.dumps(summary, indent=1))
    print(f"{len(values)} felts -> {slots_of(len(values))} packed slots, {len(txs)} transactions:")
    for tx in txs:
        print(f"  {tx['label']:<8} {tx['entrypoint']:<8} payload {tx['payload_slots']:>5} slots, "
              f"calldata ~{tx['calldata_felts']:>5} felts  {tx['meta']}")
    print("->", a.out)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Build the 3 per-fact transactions' calldata from the modeofO fixture.

Reads the packed `poseidon_chain(100)` multiverifier proof (5,147 slots of
7 little-endian u32 limbs, 36,022 felt values) and emits `calls.json`:

    stage_proof(proof_id, 0, tail)                 156 slots
    verify_phase1(proof_id, head, n_tail, n_vals)  4,991 slots of head
    verify_phase2(proof_id, fri_slots, n_fri)      FRI section, calldata

The calldata split is the one that shipped on Sepolia (docs/lane1-results.md):
the invoke calldata cap is 5,000 felts including the account `__execute__`
envelope (~4 felts) and the entrypoint's own non-span arguments, so the
phase-1 head carries 4,991 slots and the remaining 156 are staged.

Usage:
  prepare_calls.py <packed_proof.txt> <out.json> [--proof-id 0x...]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

U32_MAX = 0xFFFFFFFF

N_SLOTS = 5_147
N_VALUES = 36_022
HEAD_LEN = 4_991
# `resumable::Checkpoint.fri_value_offset` for this fixture; asserted against
# the value phase 1 actually returns during the devnet drive.
FRI_VALUE_OFFSET = 23_130


def pack(values: list[int]) -> list[int]:
    """Mirror of scripts/pack_proof.py (v1 format)."""
    limbs: list[int] = []
    for v in values:
        if v < U32_MAX:
            limbs.append(v)
        else:
            assert v < 2**64, f"value {v:#x} exceeds u64"
            limbs += [U32_MAX, v & U32_MAX, (v >> 32) & U32_MAX]
    return [
        sum(limb << (32 * i) for i, limb in enumerate(limbs[j : j + 7]))
        for j in range(0, len(limbs), 7)
    ]


def unpack(slots: list[int], n_values: int) -> list[int]:
    """Mirror of stwo_verifier_phases::unpack_proof."""
    limbs: list[int] = []
    for s in slots:
        for i in range(7):
            limbs.append((s >> (32 * i)) & U32_MAX)
    out: list[int] = []
    i = 0
    while len(out) != n_values:
        limb = limbs[i]
        if limb == U32_MAX:
            out.append(limbs[i + 1] | (limbs[i + 2] << 32))
            i += 3
        else:
            out.append(limb)
            i += 1
    return out


def build(packed: list[int], proof_id: int) -> dict:
    assert len(packed) == N_SLOTS, f"fixture is {len(packed)} slots, expected {N_SLOTS}"
    head, tail = packed[:HEAD_LEN], packed[HEAD_LEN:]

    values = unpack(packed, N_VALUES)
    n_fri = N_VALUES - FRI_VALUE_OFFSET - 1
    fri_slots = pack(values[FRI_VALUE_OFFSET : FRI_VALUE_OFFSET + n_fri])

    def hexes(xs):
        return [hex(x) for x in xs]

    calls = [
        {
            "label": "stage_proof",
            "entrypoint": "stage_proof",
            # proof_id, offset, Span<felt252> { len, ...slots }
            "calldata": hexes([proof_id, 0, len(tail)] + tail),
            "meta": {"staged_slots": len(tail)},
        },
        {
            "label": "verify_phase1",
            "entrypoint": "verify_phase1",
            # proof_id, Span<felt252> head, n_tail_slots, n_values
            "calldata": hexes([proof_id, len(head)] + head + [len(tail), N_VALUES]),
            "meta": {"head_slots": len(head), "tail_slots": len(tail)},
        },
        {
            "label": "verify_phase2",
            "entrypoint": "verify_phase2",
            # proof_id, Span<felt252> fri_slots, n_fri_values
            "calldata": hexes([proof_id, len(fri_slots)] + fri_slots + [n_fri]),
            "meta": {"fri_slots": len(fri_slots), "fri_values": n_fri},
        },
    ]
    for c in calls:
        c["calldata_felts"] = len(c["calldata"])
    return {
        "proof_id": hex(proof_id),
        "n_slots": N_SLOTS,
        "n_values": N_VALUES,
        "fri_value_offset": FRI_VALUE_OFFSET,
        "calls": calls,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("packed", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--proof-id", default=hex(int.from_bytes(b"s5_drive", "big")))
    args = ap.parse_args()

    packed = [int(l.strip(), 16) for l in args.packed.read_text().split() if l.strip()]
    doc = build(packed, int(args.proof_id, 16))
    args.out.write_text(json.dumps(doc, indent=1))
    for c in doc["calls"]:
        print(f"{c['label']:<15} calldata {c['calldata_felts']:>5} felts  {c['meta']}")
    print("->", args.out)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent model of the segment public output, for the on-chain
consumer and the replay tool.

Everything a verifier needs to do with a segment output is here: read the
ten felts, check the chain, and recompute the input-log commitment from the
packed log published as an event. Poseidon comes from `poseidon_py`, so
this agrees with the Cairo crate without sharing any code with it.

Run: `python3 reference.py`
"""

from poseidon_py.poseidon_hash import poseidon_hash, poseidon_hash_many

VERSION = 1
OUTPUT_LEN = 10
SCHEMA_VERSION = 1
TICS_PER_FELT = 7
WORD_SHIFT = 1 << 32

RUNNING, DEAD, EXIT, ABORT = 0, 1, 2, 3
STATUS_NAMES = {RUNNING: "RUNNING", DEAD: "DEAD", EXIT: "EXIT", ABORT: "ABORT"}

FIELDS = [
    "version", "h_in", "h_out", "tic_start", "tic_end",
    "status", "inputs_commitment", "kills", "items", "secrets",
]


def short_string(text: str) -> int:
    return int.from_bytes(text.encode("ascii"), "big")


TAG_INPUT_LOG = short_string("HP.INPUTS")


def read_output(felts: list[int]) -> dict:
    """The ten public felts, named. Raises on anything malformed — the
    Cairo side returns None instead (`from_felts`)."""
    assert len(felts) == OUTPUT_LEN, len(felts)
    assert felts[0] == VERSION, felts[0]
    assert felts[5] in STATUS_NAMES, felts[5]
    out = dict(zip(FIELDS, felts))
    assert out["tic_end"] >= out["tic_start"]
    return out


def continues(earlier: dict, later: dict) -> bool:
    return (
        earlier["h_out"] == later["h_in"]
        and earlier["tic_end"] == later["tic_start"]
        and earlier["status"] == RUNNING
    )


def check_run(outputs: list[dict], genesis: int) -> bool:
    """The rules `DoomRuns` enforces over a whole run."""
    if not outputs:
        return False
    if outputs[0]["h_in"] != genesis:
        return False
    for earlier, later in zip(outputs, outputs[1:]):
        if not continues(earlier, later):
            return False
    return outputs[-1]["status"] == EXIT


def inputs_seed() -> int:
    return poseidon_hash_many([TAG_INPUT_LOG, SCHEMA_VERSION, 0])


def commit_log(packed: list[int]) -> int:
    """Recompute a segment's `inputs_commitment` from its slice of the
    packed log. `poseidon_hash(a, b)` is Starknet's 2-to-1 Poseidon, the
    same function `starknet.js` exposes."""
    commitment = inputs_seed()
    for felt in packed:
        commitment = poseidon_hash(commitment, felt)
    return commitment


def pack_log(words: list[int]) -> list[int]:
    return [
        sum(w << (32 * i) for i, w in enumerate(words[g: g + TICS_PER_FELT]))
        for g in range(0, len(words), TICS_PER_FELT)
    ]


def main() -> None:
    print(f"output layout, {OUTPUT_LEN} felts")
    for index, name in enumerate(FIELDS):
        print(f"  {index}  {name}")
    print(f"\nstatus codes: {STATUS_NAMES}")
    print(f"inputs_seed() = {hex(inputs_seed())}")

    # A nine-tic segment: two packed felts (7 + 2), folded from the seed.
    words = [0x00808080 + i for i in range(9)]
    packed = pack_log(words)
    assert len(packed) == 2
    print(f"\nnine tics -> {len(packed)} transport felts")
    print(f"  commitment = {hex(commit_log(packed))}")

    # Continuity over a three-segment run.
    run = [
        {"version": VERSION, "h_in": 1, "h_out": 2, "tic_start": 0, "tic_end": 80,
         "status": RUNNING, "inputs_commitment": 0, "kills": 0, "items": 0, "secrets": 0},
        {"version": VERSION, "h_in": 2, "h_out": 3, "tic_start": 80, "tic_end": 160,
         "status": RUNNING, "inputs_commitment": 0, "kills": 3, "items": 0, "secrets": 0},
        {"version": VERSION, "h_in": 3, "h_out": 4, "tic_start": 160, "tic_end": 200,
         "status": EXIT, "inputs_commitment": 0, "kills": 5, "items": 1, "secrets": 0},
    ]
    assert check_run(run, genesis=1)
    assert not check_run(run, genesis=99), "wrong genesis must be rejected"
    broken = [dict(s) for s in run]
    broken[1]["h_in"] = 999
    assert not check_run(broken, genesis=1), "broken chain must be rejected"
    unfinished = [dict(s) for s in run]
    unfinished[-1]["status"] = RUNNING
    assert not check_run(unfinished, genesis=1), "a run must end in EXIT"
    gapped = [dict(s) for s in run]
    gapped[2]["tic_start"] = 161
    assert not check_run(gapped, genesis=1), "a tic gap must be rejected"
    print("\nrun-level checks (genesis, chaining, tic continuity, EXIT): ok")

    # A well-formed output survives the reader.
    felts = [VERSION, 11, 22, 0, 80, RUNNING, 33, 1, 2, 3]
    assert read_output(felts)["kills"] == 1
    print("output reader: ok")


if __name__ == "__main__":
    main()

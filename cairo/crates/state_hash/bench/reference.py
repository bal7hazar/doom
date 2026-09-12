#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent reference implementation of `state_hash`'s domain-separation
scheme, used to produce the vectors pinned in `src/lib.cairo`.

Poseidon comes from `poseidon_py` (the reference implementation used by
starknet.py), so the Cairo values are checked against a hash implementation
this repository did not write.

    H(tag, version, data) = poseidon_hash_many([tag, version, len(data)] + data)

Run: `python3 reference.py`
"""

from poseidon_py.poseidon_hash import poseidon_hash, poseidon_hash_many

SCHEMA_VERSION = 1


def short_string(text: str) -> int:
    """Cairo's short-string literal encoding: big-endian ASCII bytes."""
    return int.from_bytes(text.encode("ascii"), "big")


TAG_STATE = short_string("HP.STATE")
TAG_SEGMENT_OUTPUT = short_string("HP.SEGOUT")
TAG_INPUT_LOG = short_string("HP.INPUTS")


def hash_tagged(tag: int, version: int, data: list[int]) -> int:
    return poseidon_hash_many([tag, version, len(data)] + list(data))


def hash_record(tag: int, data: list[int]) -> int:
    return hash_tagged(tag, SCHEMA_VERSION, data)


def inputs_seed() -> int:
    return hash_record(TAG_INPUT_LOG, [])


def commit_input(prev: int, packed: int) -> int:
    # Starknet's 2-to-1 Poseidon: one Hades permutation over (prev, packed, 2).
    # Not poseidon_hash_many([prev, packed]), which pads.
    return poseidon_hash(prev, packed)


def commit_log(packed: list[int]) -> int:
    commitment = inputs_seed()
    for felt in packed:
        commitment = commit_input(commitment, felt)
    return commitment


def main() -> None:
    print("reserved tags")
    for name, value in [
        ("STATE", TAG_STATE),
        ("SEGMENT_OUTPUT", TAG_SEGMENT_OUTPUT),
        ("INPUT_LOG", TAG_INPUT_LOG),
    ]:
        print(f"  {name:<15} {hex(value)}")

    print("\nvectors pinned in src/lib.cairo")
    tagged = hash_tagged(short_string("T"), 1, [1, 2, 3])
    seed = inputs_seed()
    commit111 = commit_input(seed, 111)
    print(f"  REFERENCE_TAGGED       = {hex(tagged)}")
    print(f"  REFERENCE_INPUTS_SEED  = {hex(seed)}")
    print(f"  REFERENCE_COMMIT_111   = {hex(commit111)}")

    print("\nvectors pinned in ../../segment/src/lib.cairo")
    print(f"  SEGMENT_OUTPUT tag     = {hex(TAG_SEGMENT_OUTPUT)}")

    # Domain separation: the properties the Cairo tests assert.
    assert hash_tagged(1, 1, [1]) != hash_tagged(2, 1, [1]), "tag separates"
    assert hash_tagged(1, 1, [1]) != hash_tagged(1, 2, [1]), "version separates"
    assert hash_tagged(1, 1, [1]) != hash_tagged(1, 1, [1, 2]), "length separates"
    # The concatenation attack the length prefix stops: without it,
    # H(tag, v, [1]) and H(tag, v, [1, 2]) would share a prefix of absorbed
    # felts, and a record could be extended.
    assert poseidon_hash_many([1, 1, 1]) != poseidon_hash_many([1, 1, 1, 2])
    print("\ndomain separation properties: ok")


if __name__ == "__main__":
    main()

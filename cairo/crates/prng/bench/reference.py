#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent reference implementation of `prng`, used to produce the
reference vectors asserted in `src/lib.cairo`'s test module.

The crate is table-agnostic, so the reference uses the same synthetic
stand-in table the Cairo tests build: `table[i] = (i * 167 + 61) % 256`.
Run `python3 reference.py` and compare with `test_reference_vectors`,
`test_below_bounds_and_zero_modulus` and `test_sub_random_*`.
"""

TABLE_LEN = 256
TABLE = [(i * 167 + 61) % 256 for i in range(TABLE_LEN)]


def draw(index: int) -> tuple[int, int]:
    """Return (next_index, value), mirroring `PrngTrait::next`."""
    return (0 if index == TABLE_LEN - 1 else index + 1), TABLE[index]


def sub_random(index: int) -> tuple[int, int]:
    index, a = draw(index)
    index, b = draw(index)
    return index, a - b


def main() -> None:
    index = 0
    values = []
    for _ in range(4):
        index, value = draw(index)
        values.append(value)
    print("first four draws from index 0:", values)
    print("below(8) of the first draw:", TABLE[0] % 8)
    print("sub_random from index 0:", sub_random(0))
    print("sum over one full period:", sum(TABLE))
    # Property the Cairo tests assert: one period is a permutation of the
    # table, from any starting cursor.
    for start in (0, 7, 200, 255):
        index, seen = start, []
        for _ in range(TABLE_LEN):
            index, value = draw(index)
            seen.append(value)
        assert sorted(seen) == sorted(TABLE), start
        assert index == start, start
    print("period check: ok for every starting cursor")


if __name__ == "__main__":
    main()

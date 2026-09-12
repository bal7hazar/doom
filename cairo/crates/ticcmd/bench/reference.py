#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent reference implementation of `ticcmd`'s two wire formats.

Written from the format description alone (not from the Cairo source), and
used both to produce the reference vectors asserted in `src/lib.cairo` and
to cross-check the round-trip properties exhaustively over ranges the Cairo
tests can only sample.

Run: `python3 reference.py`
"""

MOVE_MIN, MOVE_MAX = -128, 127
TURN_UNIT = 256
TURN_MIN, TURN_MAX = -32768, 32512
TICS_PER_FELT = 7
WORD_SHIFT = 1 << 32
# The Starknet prime; a transport felt (224 bits) always fits.
PRIME = 2**251 + 17 * 2**192 + 1


def encode(forward: int, side: int, turn: int, buttons: int) -> int:
    assert MOVE_MIN <= forward <= MOVE_MAX, forward
    assert MOVE_MIN <= side <= MOVE_MAX, side
    assert TURN_MIN <= turn <= TURN_MAX, turn
    assert turn % TURN_UNIT == 0, turn
    assert 0 <= buttons <= 255, buttons
    return (
        (forward + 128)
        | ((side + 128) << 8)
        | ((turn // TURN_UNIT + 128) << 16)
        | (buttons << 24)
    )


def decode(word: int) -> tuple[int, int, int, int]:
    assert 0 <= word < WORD_SHIFT, word
    return (
        (word & 0xFF) - 128,
        ((word >> 8) & 0xFF) - 128,
        (((word >> 16) & 0xFF) - 128) * TURN_UNIT,
        (word >> 24) & 0xFF,
    )


def quantize(forward: int, side: int, turn: int, buttons: int) -> tuple:
    def clamp(v, lo, hi):
        return lo if v < lo else hi if v > hi else v

    turn = clamp(turn, TURN_MIN, TURN_MAX)
    # Round towards minus infinity, like an arithmetic shift right.
    turn = (turn // TURN_UNIT) * TURN_UNIT
    return clamp(forward, MOVE_MIN, MOVE_MAX), clamp(side, MOVE_MIN, MOVE_MAX), turn, buttons


def pack7(words: list[int]) -> int:
    assert len(words) <= TICS_PER_FELT
    return sum(w << (32 * i) for i, w in enumerate(words))


def unpack7(packed: int) -> list[int]:
    return [(packed >> (32 * i)) & 0xFFFFFFFF for i in range(TICS_PER_FELT)]


def pack_log(words: list[int]) -> list[int]:
    return [
        pack7(words[i: i + TICS_PER_FELT]) for i in range(0, len(words), TICS_PER_FELT)
    ]


def main() -> None:
    print("reference words")
    for label, cmd in [
        ("idle", (0, 0, 0, 0)),
        ("sample", (1, -1, 256, 3)),
        ("min", (-128, -128, -32768, 0)),
        ("max", (127, 127, 32512, 255)),
        ("decode_offsets sample", (-40, 90, -2560, 17)),
    ]:
        word = encode(*cmd)
        print(f"  {label:<22} {cmd} -> 0x{word:08X}  offsets={[(word >> (8 * i)) & 0xFF for i in range(4)]}")

    print("reference pack7 of [1..7]:", hex(pack7([1, 2, 3, 4, 5, 6, 7])))
    print("a full group is", hex(pack7([0xFFFFFFFF] * 7)), "<", hex(1 << 224), "and < PRIME:",
          pack7([0xFFFFFFFF] * 7) < PRIME)

    # Exhaustive round trip over every representable command.
    count = 0
    for forward in range(MOVE_MIN, MOVE_MAX + 1):
        for units in range(-128, 128):
            cmd = (forward, -forward - 1, units * TURN_UNIT, (forward + 128) & 0xFF)
            assert decode(encode(*cmd)) == cmd, cmd
            count += 1
    print(f"exhaustive encode/decode round trip: ok ({count} commands)")

    # quantize is total and idempotent.
    for turn in range(-40000, 40000, 37):
        q = quantize(0, 0, turn, 0)
        assert quantize(*q) == q, turn
        assert TURN_MIN <= q[2] <= TURN_MAX and q[2] % TURN_UNIT == 0, turn
    print("quantize: total and idempotent")
    assert quantize(9999, -9999, 12345, 200) == (127, -128, 12288, 200)
    assert quantize(0, 0, 255, 0)[2] == 0
    assert quantize(0, 0, -1, 0)[2] == -256

    # pack/unpack round trip over awkward log lengths.
    for n in range(0, 16):
        words = [encode(1, 2, TURN_UNIT, i & 0xFF) for i in range(n)]
        packed = pack_log(words)
        assert len(packed) == (n + 6) // 7, n
        flat = [w for felt in packed for w in unpack7(felt)][:n]
        assert flat == words, n
    print("pack_log/unpack_log: ok for every length 0..15")


if __name__ == "__main__":
    main()

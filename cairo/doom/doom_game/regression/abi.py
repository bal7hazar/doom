# SPDX-License-Identifier: GPL-2.0-only
"""Strict public doom_run ABI and an independent D13/D14 Poseidon oracle."""
import hashlib
from dataclasses import dataclass
from poseidon_py.poseidon_hash import poseidon_hash, poseidon_hash_many

PRIME = (1 << 251) + 17 * (1 << 192) + 1
SMALL = 1 << 72
STATE_TAG = int.from_bytes(b"HP.STATE", "big")
INPUTS_TAG = int.from_bytes(b"HP.INPUTS", "big")


class Failure(AssertionError):
    def __init__(self, kind, detail):
        self.kind = kind
        super().__init__(f"{kind}: {detail}")


def require(condition, kind, detail):
    if not condition:
        raise Failure(kind, detail)


def digest(values):
    return hashlib.sha256(" ".join(hex(x) for x in values).encode()).hexdigest()


def packed(state, words):
    return [len(state), *state, len(words), *words]


def check_state(state):
    require(len(state) >= 47, "state_shape", "truncated state")
    require(state[:2] == [STATE_TAG, 2] and state[2] == len(state) - 3,
            "state_shape", "unknown schema/tag/length")
    require(all(0 <= x < SMALL for x in state), "state_range", "felt outside [0,2^72)")
    require(state[5] in (0, 1, 2), "abort", f"state status {state[5]}")
    require(state[4] < (1 << 30), "clock", "invalid game clock")


@dataclass
class Frame:
    raw: list[int]
    status: int
    state: list[int]
    snapshot: list[int]

    @property
    def tic(self):
        return self.state[4]

    @property
    def stats(self):
        return self.snapshot[29:32]

    def summary(self):
        return dict(status=self.status, tic=self.tic, health=self.snapshot[11],
                    armor=self.snapshot[12], weapon=self.snapshot[22], ammo=self.snapshot[14:18],
                    xyz=self.snapshot[5:8], angle=self.snapshot[9], stats=self.stats,
                    prng=self.state[8], mrng=self.state[9],
                    state_felts=len(self.state), snapshot_felts=len(self.snapshot),
                    state_sha256=digest(self.state), snapshot_sha256=digest(self.snapshot),
                    output_sha256=digest(self.raw))


def decode_frame(values):
    require(len(values) >= 3, "frame_shape", "truncated envelope")
    status, n = values[:2]
    require(0 < n <= len(values) - 3, "frame_shape", "invalid state length")
    state = values[2:2 + n]
    m = values[2 + n]
    snapshot = values[3 + n:]
    require(len(snapshot) == m and m >= 36, "frame_shape", "invalid snapshot length")
    check_state(state)
    require(status in (0, 1, 2), "abort", f"step_tic status {status}")
    require(all(0 <= x < SMALL for x in snapshot), "render_range", "felt outside [0,2^72)")
    require(snapshot[0] == 1 and m == 36 + 11 * snapshot[3] + 4 * snapshot[4],
            "frame_shape", "unknown snapshot schema/length")
    require(status == state[5] == snapshot[2] and state[4] == snapshot[1] == snapshot[35],
            "frame_shape", "state/render status or clock differs")
    return Frame(values, status, state, snapshot)


def input_commitment(words):
    value = poseidon_hash_many([INPUTS_TAG, 1, 0])
    for offset in range(0, len(words), 7):
        block = sum(w << (32 * i) for i, w in enumerate(words[offset:offset + 7]))
        value = poseidon_hash(value, block)
    return value


def expected_d14(start, end, words):
    consumed = end.tic - start[4]
    require(0 <= consumed <= len(words), "clock", "invalid number of advanced tics")
    return [1, poseidon_hash_many(start), poseidon_hash_many(end.state), start[4], end.tic,
            end.status, input_commitment(words[:consumed]), *end.stats]


def compare(actual, expected, kind):
    if actual != expected:
        at = next((i for i, (a, b) in enumerate(zip(actual, expected)) if a != b),
                  min(len(actual), len(expected)))
        raise Failure(kind, f"first differing felt {at}; lengths {len(actual)}/{len(expected)}; "
                      f"sha256 {digest(actual)}/{digest(expected)}")

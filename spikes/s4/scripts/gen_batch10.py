#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Plans one **batch** of `segment_stub10` leaves and writes it as `batch.json` (P4.2b).

A batch is a list of games; each game is a chain of segments, and the leaves of the batch are
those chains concatenated in fold order — exactly what `DoomRuns.submit_batch` expects as
`leaves[]` with one `Member {player, level_id, leaf_start, leaf_len}` per game.

This file decides, off chain and reproducibly, what each leaf's *arguments* are:

    (h_in, tic_start, n_tics, seed, status, kills, items, secrets)

with `h_in[0] = genesis(version_id, level_id)`, `h_in[i+1] = h_out[i] = poseidon(h_in, n_tics)`
(the stub's chaining rule), `tic_end[i] = tic_start[i+1]`, `status = RUNNING` on every segment
but the last of a game and `EXIT` (or `DEAD`) on that one. It also computes what the program
*will* return — the packed input log and its `inputs_commitment` — with `poseidon_py`, so the
pipeline can assert the prover's preimages against an independent model before anything is
folded, and so the replay calldata is available later without re-running the program.

    gen_batch10.py --shape 2 --out batch.json                 # one game, two segments
    gen_batch10.py --shape 2,1 --out batch.json               # two games (2 + 1), one batch

Nothing here proves anything; `run_pipeline10.sh` consumes the file.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from poseidon_py.poseidon_hash import poseidon_hash, poseidon_hash_many

VERSION = 1
RUNNING, DEAD, EXIT, ABORT = 0, 1, 2, 3
TICS_PER_FELT = 7
SCHEMA_VERSION = 1
WORD_BASE = 0x00808080
MASK32 = 0xFFFFFFFF


def short_string(text: str) -> int:
    return int.from_bytes(text.encode("ascii"), "big")


TAG_INPUT_LOG = short_string("HP.INPUTS")


def inputs_seed() -> int:
    """`state_hash::inputs_seed()`."""
    return poseidon_hash_many([TAG_INPUT_LOG, SCHEMA_VERSION, 0])


def commit_log(packed: list[int]) -> int:
    """`state_hash::commit_input` folded over a segment's own packed log (D13)."""
    commitment = inputs_seed()
    for felt in packed:
        commitment = poseidon_hash(commitment, felt)
    return commitment


def pack_log(words: list[int]) -> list[int]:
    """Seven 32-bit tic words to a transport felt, little-endian lanes (`ticcmd::Packer`)."""
    return [
        sum(w << (32 * i) for i, w in enumerate(words[g:g + TICS_PER_FELT]))
        for g in range(0, len(words), TICS_PER_FELT)
    ]


def log_of(seed: int, n_tics: int) -> list[int]:
    """The synthetic input log `segment_stub10` builds for `(seed, n_tics)`."""
    return pack_log([(WORD_BASE + seed + j) & MASK32 for j in range(n_tics)])


def genesis_of(version_id: int, level_id: int) -> int:
    """The constant `DoomRuns` pins per `(version, level)`; the same convention as
    `cairo/doom_contracts/tools/doomruns_model.py`."""
    return poseidon_hash_many([short_string("HP.GENESIS"), version_id, level_id])


def plan(shape: list[int], *, version_id: int = 1, level_id: int = 1, tics: int = 160,
         last_tics: int = 137, final_status: int = EXIT) -> dict:
    leaves: list[dict] = []
    members: list[dict] = []
    for game, n_segments in enumerate(shape):
        start = len(leaves)
        h_in = genesis_of(version_id, level_id)
        tic_start = 0
        for i in range(n_segments):
            last = i == n_segments - 1
            n_tics = last_tics if last else tics
            seed = 1000 * (game + 1) + 7 * i
            packed = log_of(seed, n_tics)
            h_out = poseidon_hash_many([h_in, n_tics])
            status = (final_status if last else RUNNING)
            kills = (3 + game) * (i + 1)
            items = i + game
            secrets = (i + game) // 2
            leaves.append({
                "game": game,
                "segment": i,
                "args": [hex(h_in), hex(tic_start), hex(n_tics), hex(seed), hex(status),
                         hex(kills), hex(items), hex(secrets)],
                "packed": [str(w) for w in packed],
                "output": [str(x) for x in [
                    VERSION, h_in, h_out, tic_start, tic_start + n_tics, status,
                    commit_log(packed), kills, items, secrets,
                ]],
            })
            h_in = h_out
            tic_start += n_tics
        members.append({"game": game, "level_id": level_id,
                        "leaf_start": start, "leaf_len": n_segments})
    return {"shape": shape, "version_id": version_id, "level_id": level_id,
            "genesis": hex(genesis_of(version_id, level_id)),
            "members": members, "leaves": leaves}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shape", required=True,
                    help="segments per game, comma separated (e.g. '2' or '2,1')")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--version-id", type=int, default=1)
    ap.add_argument("--level-id", type=int, default=1)
    ap.add_argument("--tics", type=int, default=160)
    ap.add_argument("--last-tics", type=int, default=137)
    cfg = ap.parse_args()
    shape = [int(x) for x in cfg.shape.split(",")]
    doc = plan(shape, version_id=cfg.version_id, level_id=cfg.level_id,
               tics=cfg.tics, last_tics=cfg.last_tics)
    cfg.out.parent.mkdir(parents=True, exist_ok=True)
    cfg.out.write_text(json.dumps(doc, indent=1))
    print(f"{len(doc['leaves'])} leaves, {len(shape)} game(s) {shape}, genesis {doc['genesis']}")
    print("->", cfg.out)


if __name__ == "__main__":
    main()

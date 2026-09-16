#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The D35 open-prover round on devnet, on real data: commit, prove from another account,
get paid; commit again, let it expire, reclaim.

`e2e_10felt_drive.py` shows the P4.2b path (router verifies the root proof, `DoomRuns` consumes
the fact). This drive adds the commitment half around it, with **two** devnet accounts:

    player  (--account, also the owner):  MockERC20.mint + approve(DoomRuns, bounty)
                                          commit_run(version, level, packed, tics, bounty)
                                            -> RunCommitted + ceil(len / 256) x RunLog, escrow
    prover  (--prover):                   StwoCircuitRouter.begin/merkle/answers/fri x 5
                                          register_member(member of the committed game, replay)
                                            -> RunSubmitted, CommitmentProved, bounty -> prover
    player:                               commit_run of the other game of the fixture, whose
                                          first segment is not 7-tic aligned: the contract
                                          cannot recompute its run-level commitment, so the
                                          prover's submit_batch records the run but settles
                                          nothing (docs/design/doomruns.md, D35 settlement rule)
                                          reclaim before expiry  -> REVERTED 'not expired'
                                          devnet_createBlock x expiry_blocks, reclaim
                                            -> CommitmentReclaimed, refund

Every event is read back from the receipts and checked by selector and layout (the same
layout `infra/indexer/src/decode.ts` reads), the commitment id is recomputed here with
`poseidon_py`, and the escrow is followed on the token's balances. Receipts, gas and fees are
recorded verbatim in `--out`; `commit_run`'s l2 gas is the number D35 quotes.

Nothing here can reach a public network: the URL must be a local devnet.

Usage:
  starknet-devnet --seed 42 --port 5081 --accounts 3 --state-archive-capacity full ...
  sncast --accounts-file accounts.json account import --url http://127.0.0.1:5081/rpc \
      --name devnet42 --type oz --address <addr0> --private-key <key0>
  sncast --accounts-file accounts.json account import --url http://127.0.0.1:5081/rpc \
      --name prover --type oz --address <addr1> --private-key <key1>
  tools/commit_drive.py crates/recursion_outputs/fixtures/B2-1_doom \
      --out results/commit_receipts.json --accounts-file accounts.json --work /tmp/commit \
      --url http://127.0.0.1:5081/rpc [--account devnet42] [--prover prover] \
      [--expiry-blocks 20] [--bounty 1000000000000000000]
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from types import SimpleNamespace

from poseidon_py.poseidon_hash import poseidon_hash_many

from devnet_drive import gas_prices, retdata, rpc, sncast, trace
from doomruns_drive import account_address, digest_felts, invoke, submit_calldata
from doomruns_model import TICS_PER_FELT, commit_log, pack_log, short_string
from e2e_10felt_drive import (
    RUNS_PACKAGE,
    VERIFIER_CLASSES,
    VERIFIER_PACKAGE,
    VERSION_ID,
    declare,
    deploy,
    invoke_expect_revert,
    root_proof,
    run,
    verify_root,
)
from real_batch import load

HERE = Path(__file__).resolve().parent

TAG_COMMIT = short_string("HP.COMMIT")
STATUS = {0: "NONE", 1: "PENDING", 2: "PROVED", 3: "RECLAIMED"}
# `doom_runs::LOG_CHUNK`: a `RunLog` event carries at most this many felts.
LOG_CHUNK = 256

# sn_keccak of the event names (`hash.getSelectorFromName` in starknet.js, pinned by
# infra/indexer/test/decode.test.ts against the compiled ABI). Python has no keccak in its
# standard library, so the values are written out.
SELECTORS = {
    "RunSubmitted": 0x38dbedbaea23463fa7b099b0672c1db68cc92a8df60e41360c95f8ef4c37c1f,
    "Replay": 0x116d140995fef79fce540ac3cc243e6c5d430e283892977658665ceb2a5fc41,
    "MemberRejected": 0x2ec3f67ac6add7d5a3765ea0686da69481d94874c9f0ee1cdccbd377988f101,
    "RunCommitted": 0x1099626e2b9a923474254b7263af666f7c1a048447bb0a1e4dc8b8d0419e33c,
    "RunLog": 0x2d88b9fb81ec1e6da1d03071766806fc8fa19acced5d8e3c6d2d603a6b9d251,
    "CommitmentProved": 0x12fe72cbd47e53727a60da817ca427b6cd89c345d2b6ed491525ee6ddc7d59,
    "CommitmentReclaimed": 0xe8f30b17561c2ce1eb44fd16376c8d236c3057935869966a603679eb142ca7,
}
NAMES = {v: k for k, v in SELECTORS.items()}


def commitment_id_of(version_id: int, level_id: int, player: int, inputs_commitment: int) -> int:
    """`doom_runs::commitment_id_of`."""
    return poseidon_hash_many([TAG_COMMIT, version_id, level_id, player, inputs_commitment])


def unpack_log(packed: list[int], tics: int) -> list[int]:
    """Inverse of `pack_log`: seven 32-bit lanes per felt, the last group short."""
    words: list[int] = []
    for felt in packed:
        for _ in range(min(TICS_PER_FELT, tics - len(words))):
            words.append(felt & 0xFFFFFFFF)
            felt >>= 32
    assert len(words) == tics, (len(words), tics)
    return words


def u256(lo: str, hi: str) -> int:
    return int(lo, 16) + (int(hi, 16) << 128)


def u256_calldata(value: int) -> list[str]:
    return [hex(value & ((1 << 128) - 1)), hex(value >> 128)]


def settleable(batch: dict, member: dict) -> bool:
    """Whether the contract can recompute the game's run-level commitment from a submission:
    one segment, or every non-final segment covering a multiple of 7 tics (`doom_runs.cairo`
    `run_inputs_commitment`)."""
    own = batch["leaves"][member["leaf_start"]: member["leaf_start"] + member["leaf_len"]]
    return all((leaf["tic_end"] - leaf["tic_start"]) % TICS_PER_FELT == 0 for leaf in own[:-1])


def journal_of(batch: dict, member: dict) -> tuple[list[int], int]:
    """The whole packed input log of one game and its tic count: the per-segment logs are each
    packed from their own first tic, so the run's log is their words re-packed from tic 0."""
    start, n = member["leaf_start"], member["leaf_len"]
    words: list[int] = []
    for i in range(start, start + n):
        leaf = batch["leaves"][i]
        words += unpack_log(batch["logs"][i], leaf["tic_end"] - leaf["tic_start"])
    tics = batch["leaves"][start + n - 1]["tic_end"] - batch["leaves"][start]["tic_start"]
    assert len(words) == tics
    return pack_log(words), tics


def events_of(url: str, tx_hash: str, contract: str) -> list[dict]:
    """The named events one contract emitted in a transaction, decoded by layout."""
    rec = rpc(url, "starknet_getTransactionReceipt", [tx_hash])
    out = []
    for ev in rec.get("events", []):
        if int(ev["from_address"], 16) != int(contract, 16):
            continue
        keys = [int(k, 16) for k in ev["keys"]]
        data = ev["data"]
        name = NAMES.get(keys[0])
        if name is None:
            continue
        row = {"name": name, "keys": ev["keys"][1:], "data": data}
        if name == "RunCommitted":
            assert len(keys) == 4 and len(data) == 8, ev
            row.update(commitment_id=keys[1], player=keys[2], version_id=keys[3],
                       level_id=int(data[0], 16), genesis=int(data[1], 16),
                       inputs_commitment=int(data[2], 16), tics=int(data[3], 16),
                       bounty=u256(data[4], data[5]), expires_at=int(data[6], 16),
                       n_chunks=int(data[7], 16))
        elif name == "RunLog":
            assert len(keys) == 2 and len(data) >= 3, ev
            n = int(data[2], 16)
            assert len(data) == 3 + n, (len(data), n)
            row.update(commitment_id=keys[1], chunk=int(data[0], 16), offset=int(data[1], 16),
                       packed=[int(x, 16) for x in data[3:]])
        elif name == "CommitmentProved":
            assert len(keys) == 4 and len(data) == 3, ev
            row.update(commitment_id=keys[1], run_id=keys[2], prover=keys[3],
                       player=int(data[0], 16), bounty=u256(data[1], data[2]))
        elif name == "CommitmentReclaimed":
            assert len(keys) == 3 and len(data) == 2, ev
            row.update(commitment_id=keys[1], player=keys[2], bounty=u256(data[0], data[1]))
        elif name == "RunSubmitted":
            assert len(keys) == 4 and len(data) == 8, ev
            row.update(run_id=keys[1], player=keys[2], version_id=keys[3],
                       tics=int(data[1], 16), n_segments=int(data[6], 16))
        elif name == "MemberRejected":
            row.update(member_index=keys[1], reason=int(data[0], 16).to_bytes(32, "big")
                       .lstrip(b"\x00").decode("ascii", "replace"))
        out.append(row)
    return out


def view_call(cfg, address: str, function: str, calldata: list[str]) -> list[str]:
    """A view call's raw felts (`e2e_10felt_drive.call` cannot take an empty calldata)."""
    args = ["call", "--contract-address", address, "--function", function]
    if calldata:
        args += ["--calldata"] + calldata
    return sncast(args, cfg).get("response_raw") or []


def get_commitment(cfg, runs: str, commitment_id: int) -> dict:
    """`get_commitment`: the 13-felt `Commitment` (the layout `decodeCommitment` reads)."""
    raw = view_call(cfg, runs, "get_commitment", [hex(commitment_id)])
    assert len(raw) == 13, f"Commitment is {len(raw)} felts, expected 13"
    f = [int(x, 16) for x in raw]
    return {"player": f[0], "version_id": f[1], "level_id": f[2], "genesis": f[3],
            "inputs_commitment": f[4], "tics": f[5], "bounty": f[6] + (f[7] << 128),
            "created_block": f[8], "expires_at": f[9], "status": f[10],
            "status_name": STATUS.get(f[10], "?"), "run_id": f[11], "prover": f[12]}


def balance(cfg, token: str, who: str) -> int:
    raw = view_call(cfg, token, "balance_of", [who])
    return u256(raw[0], raw[1])


def block_number(url: str) -> int:
    return int(rpc(url, "starknet_blockNumber", []))


def mine(url: str, blocks: int) -> None:
    for _ in range(blocks):
        rpc(url, "devnet_createBlock", {})


def commit(cfg, prices, token: str, runs: str, batch: dict, member: dict, bounty: int,
           expiry: int, label: str) -> dict:
    """mint + approve + commit_run from the player; every check of the RunCommitted/RunLog
    layout, the id, the escrow and the view."""
    url = cfg.url
    player = account_address(cfg)
    packed, tics = journal_of(batch, member)
    inputs_commitment = commit_log(packed)
    own = batch["leaves"][member["leaf_start"]: member["leaf_start"] + member["leaf_len"]]
    if member["leaf_len"] == 1:
        assert inputs_commitment == own[0]["inputs_commitment"], \
            "a one-segment game's log must fold to the leaf's own inputs_commitment"
    expected_id = commitment_id_of(VERSION_ID, member["level_id"], int(player, 16),
                                   inputs_commitment)

    mint = invoke(cfg, prices, token, "mint", [player] + u256_calldata(bounty))
    approve = invoke(cfg, prices, token, "approve", [runs] + u256_calldata(bounty))
    escrow_before = balance(cfg, token, runs)
    player_before = balance(cfg, token, player)
    head = block_number(url)
    calldata = ([hex(VERSION_ID), hex(member["level_id"]), hex(len(packed))]
                + [hex(w) for w in packed] + [hex(tics)] + u256_calldata(bounty))
    row = invoke(cfg, prices, runs, "commit_run", calldata)
    ret = retdata(trace(url, row["tx_hash"]))
    assert ret and int(ret[0], 16) == expected_id, \
        f"commit_run returned {ret}, expected {hex(expected_id)}"

    events = events_of(url, row["tx_hash"], runs)
    header = [e for e in events if e["name"] == "RunCommitted"]
    logs = [e for e in events if e["name"] == "RunLog"]
    assert len(header) == 1, events
    header = header[0]
    assert header["commitment_id"] == expected_id, hex(header["commitment_id"])
    assert header["player"] == int(player, 16)
    assert header["version_id"] == VERSION_ID and header["level_id"] == member["level_id"]
    assert header["genesis"] == batch["genesis"]
    assert header["inputs_commitment"] == inputs_commitment
    assert header["tics"] == tics and header["bounty"] == bounty
    assert header["n_chunks"] == (len(packed) + LOG_CHUNK - 1) // LOG_CHUNK == len(logs)
    assert [log["chunk"] for log in logs] == list(range(len(logs)))
    assembled: list[int] = []
    for log in logs:
        assert log["commitment_id"] == expected_id
        assert log["offset"] == len(assembled), (log["offset"], len(assembled))
        assert len(log["packed"]) <= LOG_CHUNK
        assembled += log["packed"]
    assert assembled == packed, "the RunLog chunks do not concatenate to the committed log"

    view = get_commitment(cfg, runs, expected_id)
    assert view["status"] == 1, view
    assert view["player"] == int(player, 16) and view["tics"] == tics
    assert view["bounty"] == bounty and view["inputs_commitment"] == inputs_commitment
    assert view["genesis"] == batch["genesis"]
    assert view["created_block"] >= head + 1, (view["created_block"], head)
    assert view["expires_at"] == view["created_block"] + expiry == header["expires_at"]
    assert balance(cfg, token, runs) == escrow_before + bounty, "escrow not received"
    assert balance(cfg, token, player) == player_before - bounty, "player not debited"

    row.update({"label": label, "game": member["game"], "tics": tics, "packed_felts": len(packed),
                "bounty": bounty, "commitment_id": hex(expected_id),
                "inputs_commitment": hex(inputs_commitment), "n_chunks": header["n_chunks"],
                "expires_at": header["expires_at"], "created_block": view["created_block"],
                "mint": mint, "approve": approve, "commitment": view})
    print(f"  {label}: commit_run game {member['game']} tics {tics} packed {len(packed)} "
          f"felts calldata {row['calldata_felts']}  l2_gas {row['l2_gas']:,}  "
          f"l1_data_gas {row['l1_data_gas']:,}  fee {row['fee_fri'] / 1e18:.4f} STRK  "
          f"writes {row['storage_writes']}  chunks {header['n_chunks']}  "
          f"id {hex(expected_id)[:12]}… expires at block {header['expires_at']}")
    return row


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("results", type=Path, help="a proved fixture directory (B2-1_doom)")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--work", type=Path, required=True, help="scratch dir for the calldata")
    ap.add_argument("--url", default="http://127.0.0.1:5081/rpc")
    ap.add_argument("--account", default="devnet42", help="the player (and owner)")
    ap.add_argument("--prover", default="prover", help="the other account, which proves")
    ap.add_argument("--accounts-file", type=Path, required=True)
    ap.add_argument("--expiry-blocks", type=int, default=20)
    ap.add_argument("--bounty", type=int, default=10 ** 18, help="in the token's smallest unit")
    cfg = ap.parse_args()
    if not any(h in cfg.url for h in ("127.0.0.1", "localhost")):
        sys.exit("refusing to drive anything but a local devnet")
    cfg.work.mkdir(parents=True, exist_ok=True)
    url = cfg.url

    # The same settings signed by the other account: `sncast`/`invoke` read `cfg.account`.
    prover_cfg = SimpleNamespace(**{**vars(cfg), "account": cfg.prover})
    player = account_address(cfg)
    prover = account_address(prover_cfg)
    assert int(player, 16) != int(prover, 16), "the prover must be another account"

    batch = load(cfg.results.resolve())
    prices = gas_prices(url)
    print("devnet prices:", prices)
    print("player/owner", player, "\nprover      ", prover)

    # --- P4.0 router, MockERC20, DoomRuns(owner, token, expiry) -----------
    classes = {name: declare(cfg, name, VERIFIER_PACKAGE) for name in VERIFIER_CLASSES}
    router, router_deploy = deploy(cfg, classes["StwoCircuitRouter"]["class_hash"],
                                   [classes["StwoPhasesBegin"]["class_hash"],
                                    classes["StwoPhasesMerkle"]["class_hash"],
                                    classes["StwoPhasesFri"]["class_hash"]])
    classes["MockERC20"] = declare(cfg, "MockERC20", RUNS_PACKAGE)
    classes["DoomRuns"] = declare(cfg, "DoomRuns", RUNS_PACKAGE)
    token, token_deploy = deploy(cfg, classes["MockERC20"]["class_hash"], [])
    runs, runs_deploy = deploy(cfg, classes["DoomRuns"]["class_hash"],
                               [player, token, hex(cfg.expiry_blocks)])
    print("router", router, "\ntoken ", token, "\nDoomRuns", runs)
    assert int(view_call(cfg, runs, "fee_token", [])[0], 16) == int(token, 16)
    assert int(view_call(cfg, runs, "expiry_blocks", [])[0], 16) == cfg.expiry_blocks

    version_calldata = ([hex(VERSION_ID), hex(batch["program_hash"]),
                         hex(batch["program_hash_function"])]
                        + [hex(x) for x in digest_felts(batch["leaf_circuit_hash"])]
                        + [hex(x) for x in digest_felts(batch["multiverifier_hash"])]
                        + [hex(batch["registry_name"]), router])
    setup = [invoke(cfg, prices, runs, "add_version", version_calldata),
             invoke(cfg, prices, runs, "set_genesis",
                    [hex(VERSION_ID), hex(batch["level_id"]), hex(batch["genesis"])])]

    # --- the committed game: the one the settlement rule can recompute -------
    provable = [m for m in batch["members"] if settleable(batch, m)]
    unprovable = [m for m in batch["members"] if not settleable(batch, m)]
    assert provable, "no game of the fixture has 7-tic aligned segments"
    game = provable[0]
    print(f"committing game {game['game']} ({game['leaf_len']} segment(s)); "
          f"unaligned games: {[m['game'] for m in unprovable]}")
    first = commit(cfg, prices, token, runs, batch, game, cfg.bounty, cfg.expiry_blocks,
                   "commit_run")

    # --- the prover: the root proof through the router, then register_member ----
    proof = root_proof(cfg.results.resolve(), cfg.work)
    calls = cfg.work / f"calls_{batch['name']}.json"
    run([sys.executable, str(HERE / "emit_calldata.py"), str(proof), "--out", str(calls),
         "--proof-id", "0x1"])
    print(f"== {batch['name']}: the prover verifies the root proof ==")
    fact, verifier_rows = verify_root(prover_cfg, prices, router, calls, batch["name"])
    assert fact is not None and int(fact, 16) == batch["fact"], fact

    prover_before = balance(cfg, token, prover)
    players = {m["game"]: int(player, 16) for m in batch["members"]}
    settle = invoke(prover_cfg, prices, runs, "register_member",
                    submit_calldata(batch, with_replay=True, members=[game], single=True,
                                    version_id=VERSION_ID, players=players))
    ret = retdata(trace(url, settle["tx_hash"]))
    assert ret and int(ret[0], 16) == 1, f"register_member returned {ret}"
    events = events_of(url, settle["tx_hash"], runs)
    proved = [e for e in events if e["name"] == "CommitmentProved"]
    assert len(proved) == 1, [e["name"] for e in events]
    proved = proved[0]
    assert proved["commitment_id"] == int(first["commitment_id"], 16)
    assert proved["run_id"] == game["run_id"], (hex(proved["run_id"]), hex(game["run_id"]))
    assert proved["prover"] == int(prover, 16) and proved["player"] == int(player, 16)
    assert proved["bounty"] == cfg.bounty
    submitted = [e for e in events if e["name"] == "RunSubmitted"]
    assert len(submitted) == 1 and submitted[0]["run_id"] == game["run_id"]
    assert events.index(submitted[0]) < events.index(proved), "settled before recorded"
    assert balance(cfg, token, prover) == prover_before + cfg.bounty, "bounty not paid"
    assert balance(cfg, token, runs) == 0, "escrow not released"
    view = get_commitment(cfg, runs, int(first["commitment_id"], 16))
    assert view["status"] == 2 and view["run_id"] == game["run_id"] \
        and view["prover"] == int(prover, 16), view
    settle.update({"label": "register_member(settles)", "game": game["game"],
                   "events": [e["name"] for e in events], "commitment": view,
                   "prover_balance": balance(cfg, token, prover)})
    print(f"  register_member by the prover: l2_gas {settle['l2_gas']:,}  events "
          f"{settle['events']}  bounty {cfg.bounty / 1e18} paid to the prover; "
          f"commitment PROVED, run_id {hex(view['run_id'])[:12]}…")

    # --- a second commitment that nothing settles, then reclaimed --------------
    second = None
    if unprovable:
        other = unprovable[0]
        second = commit(cfg, prices, token, runs, batch, other, cfg.bounty, cfg.expiry_blocks,
                        "commit_run(2)")
        second_id = int(second["commitment_id"], 16)
        rest = invoke(prover_cfg, prices, runs, "submit_batch",
                      submit_calldata(batch, with_replay=True, members=[other],
                                      version_id=VERSION_ID, players=players))
        names = [e["name"] for e in events_of(url, rest["tx_hash"], runs)]
        assert "RunSubmitted" in names and "CommitmentProved" not in names, names
        assert get_commitment(cfg, runs, second_id)["status"] == 1
        rest.update({"label": "submit_batch(unaligned game, settles nothing)",
                     "game": other["game"], "events": names})
        print(f"  submit_batch of game {other['game']}: {names} — still PENDING, as the "
              f"settlement rule says for a non-aligned first segment")

        early = invoke_expect_revert(cfg, prices, runs, "reclaim", [hex(second_id)])
        assert early["execution_status"] == "REVERTED" and \
            "not expired" in (early["revert_reason"] or ""), early
        to_mine = second["expires_at"] - block_number(url)
        mine(url, max(0, to_mine))
        assert block_number(url) >= second["expires_at"]
        player_before = balance(cfg, token, player)
        reclaim = invoke(cfg, prices, runs, "reclaim", [hex(second_id)])
        events = events_of(url, reclaim["tx_hash"], runs)
        assert [e["name"] for e in events] == ["CommitmentReclaimed"], events
        assert events[0]["commitment_id"] == second_id and \
            events[0]["player"] == int(player, 16) and events[0]["bounty"] == cfg.bounty
        assert balance(cfg, token, player) == player_before + cfg.bounty, "not refunded"
        assert balance(cfg, token, runs) == 0
        view = get_commitment(cfg, runs, second_id)
        assert view["status"] == 3, view
        reclaim.update({"label": "reclaim", "mined_blocks": max(0, to_mine),
                        "early_attempt": early, "commitment": view})
        second["submit"] = rest
        second["reclaim"] = reclaim
        print(f"  reclaim after {max(0, to_mine)} empty blocks: l2_gas {reclaim['l2_gas']:,}  "
              f"refunded; early attempt reverted with "
              f"{(early['revert_reason'] or '').strip().splitlines()[-1][:60]!r}")

    doc = {
        "network": "starknet-devnet 0.10.0 (local)", "url": url,
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "what": "D35 open prover on devnet: commit_run by the player, the real root proof "
                "verified and register_member sent by another account, the bounty paid to "
                "it; a second commitment left to expire and reclaimed",
        "fixture": batch["name"], "prices": prices,
        "player": player, "prover": prover, "router": router, "token": token,
        "doom_runs": runs, "expiry_blocks": cfg.expiry_blocks, "bounty": cfg.bounty,
        "classes": classes,
        "deploys": {"StwoCircuitRouter": router_deploy, "MockERC20": token_deploy,
                    "DoomRuns": runs_deploy},
        "version_setup": setup,
        "commit": first,
        "verifier_txs": verifier_rows,
        "settlement": settle,
        "second_commit": second,
        "totals": {
            "commit_run_l2_gas": first["l2_gas"],
            "commit_run_packed_felts": first["packed_felts"],
            "second_commit_run_l2_gas": second["l2_gas"] if second else None,
            "second_commit_run_packed_felts": second["packed_felts"] if second else None,
            "verifier_l2_gas": sum(r["l2_gas"] for r in verifier_rows),
            "register_member_l2_gas": settle["l2_gas"],
            "reclaim_l2_gas": second["reclaim"]["l2_gas"] if second else None,
        },
    }
    cfg.out.parent.mkdir(parents=True, exist_ok=True)
    cfg.out.write_text(json.dumps(doc, indent=1))
    print("->", cfg.out)


if __name__ == "__main__":
    main()

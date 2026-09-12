#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Devnet drive of the consumer transaction: `DoomRuns.submit_batch` (P4.2).

Declares `DoomRuns` (+ `MockFactRegistry`, the stand-in for the P4.0 router's fact store),
deploys them, pins one version and one level genesis, then submits batches of N segments in
several member shapes, with and without the optional replay publication, and records the
receipts verbatim. The batches come from `doomruns_model.py`, the independent Python model, so
the calldata and the facts are built exactly as a client would build them.

The fact is *mocked*, not verified: a real one costs 3.81e9 L2 gas (5–6 transactions,
`docs/design/onchain-verifier.md`). What is measured here is the consumer's own cost, which is
what the < 5 % budget of P4.2 is about — the one cross-contract `is_valid` call is the same
whichever contract answers it.

Nothing here can reach a public network: the URL must be a local devnet.

Usage:
  starknet-devnet --seed 42 --port 5077 --accounts 3 --state-archive-capacity full …
  sncast --accounts-file accounts.json account import --url http://127.0.0.1:5077/rpc \
      --name devnet42 --type oz --address <addr> --private-key <key>
  tools/doomruns_drive.py --out results/doomruns_receipts.json \
      --accounts-file accounts.json --url http://127.0.0.1:5077/rpc
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from devnet_drive import (  # same directory
    INVOKE_L2_GAS_CAP,
    S5_SNAPSHOT,
    gas_prices,
    sncast,
    state_diff_stats,
    trace,
    wait_receipt,
)
from doomruns_model import (
    LEAF_CIRCUIT_HASH,
    MULTIVERIFIER_HASH,
    PROGRAM_HASH,
    PROGRAM_HASH_FUNCTION,
    REGISTRY_NAME,
    build_batch,
    genesis_of,
)

PACKAGE = "doom_runs"
VERSION_ID = 1
LEVEL_ID = 1
# The verifier's own budget for one fact (docs/design/onchain-verifier.md §0).
FACT_L2_GAS = 3_809_794_480
BUDGET_RATIO = 0.05

BOUND_L2 = 1_140_000_000
BOUND_L1_GAS = 200_000
# A 480-leaf batch writes ~600 slots: the state diff alone needs ~66 k L1 data gas.
BOUND_L1_DATA_GAS = 250_000

PLAYER_BASE = 0x1000


def digest_felts(words: list[int]) -> list[int]:
    """Eight u32 words as the two u128 limbs of `Digest`."""
    lo = sum(w << (32 * i) for i, w in enumerate(words[:4]))
    hi = sum(w << (32 * i) for i, w in enumerate(words[4:]))
    return [lo, hi]


def submit_calldata(batch: dict, *, with_replay: bool, members: list[dict] | None = None,
                    single: bool = False, version_id: int = VERSION_ID) -> list[str]:
    """`submit_batch(version_id, leaves, members, replay)` — or `register_member` when
    `single`."""
    members = members if members is not None else batch["members"]
    words: list[int] = [version_id, len(batch["leaves"])]
    for leaf in batch["leaves"]:
        words += leaf.felts
    if not single:
        words.append(len(members))
    for m in members:
        words += [PLAYER_BASE + m["game"] + 1, m["level_id"], m["leaf_start"], m["leaf_len"]]
    if with_replay:
        covered = [i for m in members
                   for i in range(m["leaf_start"], m["leaf_start"] + m["leaf_len"])]
        words.append(len(covered))
        for i in covered:
            words += [i, len(batch["logs"][i])] + batch["logs"][i]
    else:
        words.append(0)
    return [hex(w) for w in words]


def account_address(cfg) -> str:
    """The address of `--account` in the sncast accounts file."""
    doc = json.loads(cfg.accounts_file.read_text())
    for network in doc.values():
        if cfg.account in network:
            return network[cfg.account]["address"]
    sys.exit(f"account {cfg.account} not found in {cfg.accounts_file}")


def invoke(cfg, prices, address: str, function: str, calldata: list[str]) -> dict:
    res = sncast([
        "invoke", "--contract-address", address, "--function", function,
        "--l2-gas", str(BOUND_L2), "--l2-gas-price", str(prices["l2_gas_price_fri"]),
        "--l1-gas", str(BOUND_L1_GAS), "--l1-gas-price", str(prices["l1_gas_price_fri"]),
        "--l1-data-gas", str(BOUND_L1_DATA_GAS),
        "--l1-data-gas-price", str(prices["l1_data_gas_price_fri"]),
        "--calldata"] + calldata, cfg)
    rec = wait_receipt(cfg.url, res["transaction_hash"])
    tr = trace(cfg.url, res["transaction_hash"])
    er = rec["execution_resources"]
    row = {
        "tx_hash": res["transaction_hash"],
        "function": function,
        "calldata_felts": len(calldata),
        "l2_gas": er.get("l2_gas"),
        "l1_gas": er.get("l1_gas"),
        "l1_data_gas": er.get("l1_data_gas"),
        "fee_fri": int(rec["actual_fee"]["amount"], 16),
        **state_diff_stats(tr),
    }
    row["pct_of_invoke_cap"] = round(100 * row["l2_gas"] / INVOKE_L2_GAS_CAP, 2)
    row["pct_of_fact"] = round(100 * row["l2_gas"] / FACT_L2_GAS, 3)
    return row


def scenarios() -> list[dict]:
    """N = 1, 8, 25 segments in one or several games, the replay-on variants, and the large
    batches that locate the per-invoke ceiling. `tics_per_segment = 160` is the reference
    segment cut (K = 160), i.e. 23 packed felts of input log per segment.

    Each scenario gets **its own `version_id`**, so its leaderboards start empty and every run
    it records pays an insertion: these are cold, worst-case numbers. `saturated` repeats a
    scenario on a version whose boards are already full, which is the common case in a season.
    """
    out = []
    for i, (label, shape, replay) in enumerate([
        ("n1_1game", [1], False),
        ("n1_1game_replay", [1], True),
        ("n8_1game", [8], False),
        ("n8_8games", [1] * 8, False),
        ("n8_8games_replay", [1] * 8, True),
        ("n25_1game", [25], False),
        ("n25_5games", [5] * 5, False),
        ("n25_5games_replay", [5] * 5, True),
        ("n25_25games", [1] * 25, False),
        ("n50_10games", [5] * 10, False),
        ("n100_20games", [5] * 20, False),
        ("n200_40games", [5] * 40, False),
        ("n400_80games", [5] * 80, False),
        ("n480_96games", [5] * 96, False),
    ]):
        out.append({"label": label, "shape": shape, "replay": replay,
                    "salt": 7919 * (i + 1), "version_id": VERSION_ID + i})
    # The same shape again on the version that has just been filled: the boards are saturated
    # and every insertion stops at the cutoff read.
    out.append({"label": "n25_25games_saturated", "shape": [1] * 25, "replay": False,
                "salt": 104729 * 3, "version_id": VERSION_ID + 8})
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--url", default="http://127.0.0.1:5077/rpc")
    ap.add_argument("--account", default="devnet42")
    ap.add_argument("--accounts-file", type=Path, required=True)
    ap.add_argument("--only", nargs="*", help="run only these scenario labels")
    cfg = ap.parse_args()
    if not any(h in cfg.url for h in ("127.0.0.1", "localhost")):
        sys.exit("refusing to drive anything but a local devnet")

    prices = gas_prices(cfg.url)
    print("devnet prices:", prices)

    classes = {}
    for name in ("MockFactRegistry", "DoomRuns"):
        res = sncast(["declare", "--contract-name", name, "--package", PACKAGE], cfg,
                     allow_error="is already declared")
        if res.get("type") == "error":
            class_hash = res["error"].split("class hash ")[1].split(" ")[0]
            classes[name] = {"class_hash": class_hash, "l2_gas": 0, "fee_fri": 0,
                             "note": "already declared"}
        else:
            rec = wait_receipt(cfg.url, res["transaction_hash"])
            classes[name] = {
                "class_hash": res["class_hash"],
                "l2_gas": rec["execution_resources"].get("l2_gas"),
                "fee_fri": int(rec["actual_fee"]["amount"], 16),
            }
        print(f"declared {name:<18} {classes[name]['class_hash']}  "
              f"l2_gas {classes[name]['l2_gas']:,}")

    registry_dep = sncast(["deploy", "--class-hash", classes["MockFactRegistry"]["class_hash"]],
                          cfg)
    registry = registry_dep["contract_address"]
    wait_receipt(cfg.url, registry_dep["transaction_hash"])
    # The owner of the version table is the driving account: it is the one that signs
    # `add_version` / `set_genesis` / `freeze`.
    owner = account_address(cfg)
    runs_dep = sncast(["deploy", "--class-hash", classes["DoomRuns"]["class_hash"],
                       "--constructor-calldata", owner], cfg)
    runs = runs_dep["contract_address"]
    deploy_rec = wait_receipt(cfg.url, runs_dep["transaction_hash"])
    print("registry", registry, "\nDoomRuns", runs, "\nowner", owner)

    rows = []
    setup_rows = []

    def pin_version(version_id: int) -> None:
        """Owner setup of one version: the table entry and the level genesis."""
        version_calldata = [hex(version_id), hex(PROGRAM_HASH), hex(PROGRAM_HASH_FUNCTION)] + \
            [hex(x) for x in digest_felts(LEAF_CIRCUIT_HASH)] + \
            [hex(x) for x in digest_felts(MULTIVERIFIER_HASH)] + \
            [hex(REGISTRY_NAME), registry]
        add = invoke(cfg, prices, runs, "add_version", version_calldata)
        gen = invoke(cfg, prices, runs, "set_genesis",
                     [hex(version_id), hex(LEVEL_ID), hex(genesis_of(version_id, LEVEL_ID))])
        add["version_id"] = gen["version_id"] = version_id
        setup_rows.extend([add, gen])

    pinned: set[int] = set()
    for sc in scenarios():
        if cfg.only and sc["label"] not in cfg.only:
            continue
        version_id = sc["version_id"]
        if version_id not in pinned:
            pin_version(version_id)
            pinned.add(version_id)
        batch = build_batch(sc["shape"], salt=sc["salt"], tics_per_segment=160,
                            version_id=version_id)
        invoke(cfg, prices, registry, "register", [hex(batch["fact"])])
        calldata = submit_calldata(batch, with_replay=sc["replay"], version_id=version_id)
        row = invoke(cfg, prices, runs, "submit_batch", calldata)
        row.update({"label": sc["label"], "n_segments": len(batch["leaves"]),
                    "n_members": len(sc["shape"]), "replay": sc["replay"],
                    "version_id": version_id})
        rows.append(row)
        print(f"  {row['label']:<20} N={row['n_segments']:<4} members={row['n_members']:<3}"
              f" replay={str(row['replay']):<5} calldata {row['calldata_felts']:>5}"
              f"  l2_gas {row['l2_gas']:>12,}  {row['pct_of_fact']:>6.3f} % of a fact"
              f"  writes {row['storage_writes']:>3}"
              f"  fee {row['fee_fri'] / 1e18:.4f} STRK")

    # `register_member`: the same batch split one game at a time.
    split_version = VERSION_ID + 100
    pin_version(split_version)
    split = build_batch([5] * 5, salt=104729, tics_per_segment=160, version_id=split_version)
    invoke(cfg, prices, registry, "register", [hex(split["fact"])])
    split_rows = []
    for member in split["members"]:
        cd = submit_calldata(split, with_replay=False, members=[member], single=True,
                             version_id=split_version)
        r = invoke(cfg, prices, runs, "register_member", cd)
        r["member"] = member["game"]
        split_rows.append(r)
    print(f"  register_member x{len(split_rows)}: "
          f"{sum(r['l2_gas'] for r in split_rows):,} L2 gas total")

    # A rejected member (an already-registered run): the cost of the skip path.
    rejected = invoke(cfg, prices, runs, "submit_batch",
                      submit_calldata(split, with_replay=False, version_id=split_version))
    rejected["label"] = "n25_5games_all_rejected"

    doc = {
        "network": "starknet-devnet 0.10.0 (local)",
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "url": cfg.url,
        "prices": prices,
        "mainnet_price_snapshot": S5_SNAPSHOT,
        "classes": classes,
        "registry": registry,
        "doom_runs": runs,
        "deploy_fee_fri": int(deploy_rec["actual_fee"]["amount"], 16),
        "fact_l2_gas": FACT_L2_GAS,
        "budget_ratio": BUDGET_RATIO,
        "setup": setup_rows,
        "batches": rows,
        "register_member_split": split_rows,
        "rejected_members": rejected,
    }
    def fit(a: str, b: str, key: str) -> None:
        try:
            x = next(r for r in rows if r["label"] == a)
            y = next(r for r in rows if r["label"] == b)
        except StopIteration:
            return
        doc[key] = (y["l2_gas"] - x["l2_gas"]) / (y["n_segments"] - x["n_segments"])

    fit("n1_1game", "n25_25games", "fit_l2_gas_per_game_of_one_segment")
    fit("n1_1game", "n25_1game", "fit_l2_gas_per_extra_segment_same_game")
    cfg.out.parent.mkdir(parents=True, exist_ok=True)
    cfg.out.write_text(json.dumps(doc, indent=1))
    print("->", cfg.out)


if __name__ == "__main__":
    main()

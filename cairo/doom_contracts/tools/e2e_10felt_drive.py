#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The whole path, on devnet, on **real** data (P4.2b).

`devnet_drive.py` measures the verifier alone; `doomruns_drive.py` measures the consumer alone
against `MockFactRegistry` and synthetic batches. This drive joins them, on batches that were
actually proved (`spikes/s4/scripts/run_pipeline10.sh`, ten-felt leaves):

    for each batch:
        emit_calldata.py root.proof            -> 5 (or 6) transactions
        StwoCircuitRouter.begin/merkle/answers/fri × 5   -> fact registered, is_valid(fact)
    DoomRuns.add_version(verifier_router = the real router) + set_genesis
    for each batch:
        DoomRuns.submit_batch(leaves, members, replay)   -> runs recorded, leaderboard filled
        ... and the same batch with one kill added: the fact moves, the call reverts

so the fact the consumer requires is the one the router registered from the proof, not one a
test put there. The receipts of every transaction — verifier and consumer — are recorded with
their gas, which is the number `docs/design/doomruns.md` quotes for the full path.

Nothing here can reach a public network: the URL must be a local devnet.

Usage:
  starknet-devnet --seed 42 --port 5081 --accounts 3 --state-archive-capacity full …
  sncast --accounts-file accounts.json account import --url http://127.0.0.1:5081/rpc \
      --name devnet42 --type oz --address <addr> --private-key <key>
  tools/e2e_10felt_drive.py ../../spikes/s4/results/B2-1_doom ../../spikes/s4/results/B2_doom \
      --out results/e2e_10felt_receipts.json --accounts-file accounts.json \
      --url http://127.0.0.1:5081/rpc --work /tmp/e2e
"""

from __future__ import annotations

import argparse
import gzip
import json
import subprocess
import sys
import time
from pathlib import Path

from devnet_drive import (
    BOUNDS_L2,
    INVOKE_L2_GAS_CAP,
    S5_SNAPSHOT,
    calldata_for,
    gas_prices,
    retdata,
    rpc,
    sncast,
    state_diff_stats,
    trace,
    wait_receipt,
)
from doomruns_drive import (EXPIRY_BLOCKS, FEE_TOKEN, account_address, digest_felts, invoke,
                            submit_calldata)
from real_batch import load

HERE = Path(__file__).resolve().parent
PACKAGE_DIR = HERE.parent
VERIFIER_PACKAGE = "doom_contracts"
VERIFIER_CLASSES = ["StwoPhasesBegin", "StwoPhasesMerkle", "StwoPhasesFri", "StwoCircuitRouter"]
RUNS_PACKAGE = "doom_runs"
VERSION_ID = 1
BOUND_L1_GAS = 200_000
BOUND_L1_DATA_GAS = 250_000


def root_proof(results: Path, work: Path) -> Path:
    """The root proof felts of one run: `root.proof` if the heavy file is still there, else the
    committed `root.proof.gz`, decompressed into the work directory."""
    plain = results / "root.proof"
    if plain.exists():
        return plain
    packed = results / "root.proof.gz"
    if not packed.exists():
        sys.exit(f"{results}: neither root.proof nor root.proof.gz "
                 f"(regenerate with spikes/s4/scripts/run_pipeline10.sh)")
    out = work / f"{results.name}_root.proof"
    if not out.exists():
        with gzip.open(packed, "rb") as src:
            out.write_bytes(src.read())
    return out


def run(cmd: list[str]) -> None:
    r = subprocess.run(cmd, cwd=PACKAGE_DIR)
    if r.returncode != 0:
        sys.exit(f"failed: {' '.join(cmd)}")


def declare(cfg, name: str, package: str) -> dict:
    res = sncast(["declare", "--contract-name", name, "--package", package], cfg,
                 allow_error="is already declared")
    if res.get("type") == "error":
        class_hash = res["error"].split("class hash ")[1].split(" ")[0]
        row = {"class_hash": class_hash, "tx_hash": None, "l2_gas": 0, "fee_fri": 0,
               "note": "already declared"}
    else:
        rec = wait_receipt(cfg.url, res["transaction_hash"])
        row = {"class_hash": res["class_hash"], "tx_hash": res["transaction_hash"],
               "l2_gas": rec["execution_resources"].get("l2_gas"),
               "fee_fri": int(rec["actual_fee"]["amount"], 16)}
    print(f"declared {name:<18} {row['class_hash']}  l2_gas {row['l2_gas']:>13,}  "
          f"fee {row['fee_fri'] / 1e18:.4f} STRK")
    return row


def deploy(cfg, class_hash: str, calldata: list[str]) -> tuple[str, dict]:
    args = ["deploy", "--class-hash", class_hash]
    if calldata:
        args += ["--constructor-calldata"] + calldata
    res = sncast(args, cfg)
    rec = wait_receipt(cfg.url, res["transaction_hash"])
    return res["contract_address"], {"tx_hash": res["transaction_hash"],
                                     "l2_gas": rec["execution_resources"].get("l2_gas"),
                                     "fee_fri": int(rec["actual_fee"]["amount"], 16)}


def verify_root(cfg, prices, router: str, calls: Path, name: str) -> tuple[str, list[dict]]:
    """The 5 (or 6) verifier transactions for one root proof, threading the checkpoint state.
    Returns the fact the router registered and the receipts."""
    doc = json.loads(calls.read_text())
    rows, echo = [], None
    for tx in doc["txs"]:
        cd = calldata_for(tx, echo)
        inv = sncast([
            "invoke", "--contract-address", router, "--function", tx["entrypoint"],
            "--l2-gas", str(BOUNDS_L2[tx["entrypoint"]]),
            "--l2-gas-price", str(prices["l2_gas_price_fri"]),
            "--l1-gas", "100000", "--l1-gas-price", str(prices["l1_gas_price_fri"]),
            "--l1-data-gas", "40000", "--l1-data-gas-price", str(prices["l1_data_gas_price_fri"]),
            "--calldata"] + cd, cfg)
        rec = wait_receipt(cfg.url, inv["transaction_hash"])
        tr = trace(cfg.url, inv["transaction_hash"])
        er = rec["execution_resources"]
        row = {"batch": name, "phase": "verifier", "label": tx["label"],
               "entrypoint": tx["entrypoint"], "tx_hash": inv["transaction_hash"],
               "calldata_felts": len(cd), "payload_slots": tx["payload_slots"],
               "l2_gas": er.get("l2_gas"), "l1_gas": er.get("l1_gas"),
               "l1_data_gas": er.get("l1_data_gas"),
               "fee_fri": int(rec["actual_fee"]["amount"], 16), **state_diff_stats(tr)}
        row["pct_of_invoke_cap"] = round(100 * row["l2_gas"] / INVOKE_L2_GAS_CAP, 2)
        rows.append(row)
        ret = retdata(tr)
        if ret:
            n = int(ret[0], 16)
            echo = ret[1: 1 + n]
        print(f"  {row['label']:<8} calldata {row['calldata_felts']:>5}  "
              f"l2_gas {row['l2_gas']:>13,} ({row['pct_of_invoke_cap']:>5.1f}% of cap)  "
              f"fee {row['fee_fri'] / 1e18:.4f} STRK")
    fact = None
    for ev in rpc(cfg.url, "starknet_getTransactionReceipt",
                  [rows[-1]["tx_hash"]]).get("events", []):
        if len(ev.get("keys", [])) == 2 and len(ev.get("data", [])) == 2:
            fact = ev["keys"][1]  # FactRegistered { #[key] fact, caller, proof_id }
    return fact, rows


def invoke_expect_revert(cfg, prices, address: str, function: str,
                         calldata: list[str]) -> dict:
    """Like `invoke`, but the transaction is expected to REVERT; returns its reason."""
    res = sncast(["invoke", "--contract-address", address, "--function", function,
                  "--l2-gas", "1140000000", "--l2-gas-price", str(prices["l2_gas_price_fri"]),
                  "--l1-gas", str(BOUND_L1_GAS), "--l1-gas-price", str(prices["l1_gas_price_fri"]),
                  "--l1-data-gas", str(BOUND_L1_DATA_GAS),
                  "--l1-data-gas-price", str(prices["l1_data_gas_price_fri"]),
                  "--calldata"] + calldata, cfg)
    tx_hash = res["transaction_hash"]
    deadline = time.time() + 300
    while time.time() < deadline:
        try:
            rec = rpc(cfg.url, "starknet_getTransactionReceipt", [tx_hash])
        except RuntimeError:
            time.sleep(0.5)
            continue
        if rec.get("execution_status") in ("REVERTED", "SUCCEEDED"):
            return {"tx_hash": tx_hash, "execution_status": rec["execution_status"],
                    "revert_reason": rec.get("revert_reason"),
                    "l2_gas": rec["execution_resources"].get("l2_gas"),
                    "fee_fri": int(rec["actual_fee"]["amount"], 16)}
        time.sleep(0.5)
    sys.exit(f"tx {tx_hash}: no receipt")


def predeployed_accounts(url: str) -> list[str]:
    """The devnet's own accounts, used as the players of the recorded games."""
    try:
        return [a["address"] for a in rpc(url, "devnet_getPredeployedAccounts", {})]
    except Exception as e:  # noqa: BLE001
        print("predeployed_accounts unavailable:", e)
        return []


def decode_short(value: int) -> str:
    """A Cairo short string back to text (the rejection reasons are short strings)."""
    return value.to_bytes(32, "big").lstrip(b"\x00").decode("ascii", "replace")


def submit_events(cfg, tx_hash: str, runs: str) -> dict:
    """The consumer's own events of one transaction, told apart by shape: `RunSubmitted` has 4
    keys and 8 data felts, `MemberRejected` 3 and 3, `Replay` 2 keys and a variable tail."""
    rec = rpc(cfg.url, "starknet_getTransactionReceipt", [tx_hash])
    runs_id = int(runs, 16)
    submitted, rejected, replays = 0, [], 0
    for ev in rec.get("events", []):
        if int(ev["from_address"], 16) != runs_id:
            continue
        keys, data = ev.get("keys", []), ev.get("data", [])
        if len(keys) == 4 and len(data) == 8:
            submitted += 1
        elif len(keys) == 3 and len(data) == 3:
            rejected.append({"member_index": int(keys[1], 16),
                             "reason": decode_short(int(data[0], 16))})
        elif len(keys) == 2:
            replays += 1
    return {"runs_submitted": submitted, "members_rejected": rejected,
            "replay_events": replays}


def call(cfg, address: str, function: str, calldata: list[str]) -> dict:
    """A view call: `raw` is the felt stream, `value` sncast's decoded rendering of it."""
    res = sncast(["call", "--contract-address", address, "--function", function,
                  "--calldata"] + calldata, cfg)
    return {"raw": res.get("response_raw") or [], "value": res.get("response")}


def tampered(batch: dict) -> dict:
    """The same batch with one extra kill on the last leaf — the fact moves, so the consumer
    must refuse the whole call (`doomruns: fact not registered`)."""
    leaves = [type(leaf)(leaf) for leaf in batch["leaves"]]
    leaves[-1]["kills"] += 1
    return {**batch, "leaves": leaves}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("results", nargs="+", type=Path,
                    help="spikes/s4/results/B<shape>_doom directories (run_pipeline10.sh)")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--work", type=Path, required=True, help="scratch dir for the calldata")
    ap.add_argument("--url", default="http://127.0.0.1:5081/rpc")
    ap.add_argument("--account", default="devnet42")
    ap.add_argument("--accounts-file", type=Path, required=True)
    cfg = ap.parse_args()
    if not any(h in cfg.url for h in ("127.0.0.1", "localhost")):
        sys.exit("refusing to drive anything but a local devnet")
    cfg.work.mkdir(parents=True, exist_ok=True)

    batches = [load(p.resolve()) for p in cfg.results]
    prices = gas_prices(cfg.url)
    print("devnet prices:", prices)
    owner = account_address(cfg)

    # --- P4.0: the verifier classes and the router -------------------------
    classes = {name: declare(cfg, name, VERIFIER_PACKAGE) for name in VERIFIER_CLASSES}
    router, router_deploy = deploy(cfg, classes["StwoCircuitRouter"]["class_hash"],
                                   [classes["StwoPhasesBegin"]["class_hash"],
                                    classes["StwoPhasesMerkle"]["class_hash"],
                                    classes["StwoPhasesFri"]["class_hash"]])
    print("router", router)

    # --- the real root proofs, verified on chain ---------------------------
    verifier_rows: list[dict] = []
    for i, (path, batch) in enumerate(zip(cfg.results, batches)):
        proof = root_proof(path.resolve(), cfg.work)
        calls = cfg.work / f"calls_{batch['name']}.json"
        run([sys.executable, str(HERE / "emit_calldata.py"), str(proof),
             "--out", str(calls), "--proof-id", hex(i + 1)])
        print(f"== {batch['name']}: verifying the root proof ==")
        fact, rows = verify_root(cfg, prices, router, calls, batch["name"])
        assert fact is not None, f"{batch['name']}: no FactRegistered event"
        assert int(fact, 16) == batch["fact"], (
            f"{batch['name']}: the router registered {fact}, the leaves recompose to "
            f"{hex(batch['fact'])}")
        valid = call(cfg, router, "is_valid", [fact])
        assert valid["raw"] and int(valid["raw"][0], 16) == 1, \
            f"{batch['name']}: is_valid(fact) is false"
        batch["router_fact"] = fact
        batch["verifier_l2_gas"] = sum(r["l2_gas"] for r in rows)
        verifier_rows += rows
        print(f"  fact {fact} registered and valid; it is the one the leaves recompose to")

    # --- P4.2: the consumer, pointed at that router ------------------------
    runs_class = declare(cfg, "DoomRuns", RUNS_PACKAGE)
    runs, runs_deploy = deploy(cfg, runs_class["class_hash"], [owner, FEE_TOKEN, hex(EXPIRY_BLOCKS)])
    print("DoomRuns", runs, "owner", owner)

    head = batches[0]
    version_calldata = ([hex(VERSION_ID), hex(head["program_hash"]),
                         hex(head["program_hash_function"])]
                        + [hex(x) for x in digest_felts(head["leaf_circuit_hash"])]
                        + [hex(x) for x in digest_felts(head["multiverifier_hash"])]
                        + [hex(head["registry_name"]), router])
    setup = [invoke(cfg, prices, runs, "add_version", version_calldata),
             invoke(cfg, prices, runs, "set_genesis",
                    [hex(VERSION_ID), hex(head["level_id"]), hex(head["genesis"])])]
    setup[0]["label"], setup[1]["label"] = "add_version", "set_genesis"

    # Each game gets one of the devnet's own predeployed accounts as its player — the player is
    # a field of `Member`, not the caller, so one account submits for everybody (§12.1).
    known = predeployed_accounts(cfg.url) or [owner]

    # A run id is the fold of the inputs the proof consumed (R10-A1) — it carries neither the
    # submitter nor the batch. Two batches that contain the *same game* therefore collide on
    # purpose: the second submission must skip that member with `already registered`, and this
    # drive checks exactly that against the ids it has already recorded.
    consumer_rows, checks, seen_run_ids = [], [], set()
    for batch in batches:
        players = {m["game"]: int(known[m["game"] % len(known)], 16)
                   for m in batch["members"]}
        cd = submit_calldata(batch, with_replay=True, version_id=VERSION_ID, players=players)
        row = invoke(cfg, prices, runs, "submit_batch", cd)
        row.update({"batch": batch["name"], "phase": "consumer", "label": "submit_batch",
                    "n_segments": len(batch["leaves"]), "n_members": len(batch["members"]),
                    "replay": True, "fact": batch["router_fact"],
                    "verifier_l2_gas": batch["verifier_l2_gas"],
                    **submit_events(cfg, row["tx_hash"], runs)})
        row["pct_of_fact"] = round(100 * row["l2_gas"] / batch["verifier_l2_gas"], 3)
        assert row["runs_submitted"] + len(row["members_rejected"]) == row["n_members"], row
        replayed = [m["game"] for m in batch["members"] if m["run_id"] in seen_run_ids]
        assert [r["member_index"] for r in row["members_rejected"]] == replayed, (
            f"{batch['name']}: rejected {row['members_rejected']}, expected the already "
            f"recorded members {replayed}")
        assert all(r["reason"] == "already registered" for r in row["members_rejected"]), \
            row["members_rejected"]
        assert row["runs_submitted"] == row["n_members"] - len(replayed)
        seen_run_ids.update(m["run_id"] for m in batch["members"])
        batch["runs_submitted"] = row["runs_submitted"]
        batch["members_rejected"] = row["members_rejected"]
        consumer_rows.append(row)
        print(f"  submit_batch {batch['name']:<10} N={row['n_segments']} "
              f"members={row['n_members']} calldata {row['calldata_felts']:>4}  "
              f"l2_gas {row['l2_gas']:>11,}  {row['pct_of_fact']:.3f} % of its fact  "
              f"writes {row['storage_writes']}  recorded {row['runs_submitted']}"
              f"  replay events {row['replay_events']}"
              + (f"  rejected {[r['reason'] for r in row['members_rejected']]}"
                 if row["members_rejected"] else ""))

        # The tampered twin: one extra kill moves the output_hash, so the fact is not there.
        bad = invoke_expect_revert(cfg, prices, runs, "submit_batch",
                                   submit_calldata(tampered(batch), with_replay=False,
                                                   version_id=VERSION_ID, players=players))
        bad.update({"batch": batch["name"], "phase": "consumer",
                    "label": "submit_batch(tampered kills)"})
        assert bad["execution_status"] == "REVERTED", "a tampered batch was accepted"
        assert "fact not registered" in (bad["revert_reason"] or ""), bad["revert_reason"]
        consumer_rows.append(bad)
        print(f"  tampered batch rejected: {bad['revert_reason'].strip().splitlines()[-1][:80]}")

        for m in batch["members"]:
            registered = call(cfg, runs, "is_run_registered", [hex(m["run_id"])])
            run_row = call(cfg, runs, "get_run", [hex(m["run_id"])])
            player_runs = call(cfg, runs, "player_runs",
                               [hex(players[m["game"]]), "0x0", "0xa"])
            own = batch["leaves"][m["leaf_start"]: m["leaf_start"] + m["leaf_len"]]
            checks.append({
                "batch": batch["name"], "game": m["game"], "run_id": hex(m["run_id"]),
                "player": hex(players[m["game"]]),
                "is_run_registered": bool(registered["raw"]
                                          and int(registered["raw"][0], 16) == 1),
                "get_run": run_row["value"], "get_run_felts": run_row["raw"],
                "player_runs": player_runs["value"],
                "expected": {"tics": own[-1]["tic_end"], "kills": own[-1]["kills"],
                             "items": own[-1]["items"], "secrets": own[-1]["secrets"],
                             "n_segments": len(own)},
            })
            assert checks[-1]["is_run_registered"], f"run {hex(m['run_id'])} not registered"

    board = call(cfg, runs, "leaderboard", [hex(VERSION_ID), "0x0", "0x0", "0xa"])
    board_len = call(cfg, runs, "leaderboard_len", [hex(VERSION_ID), "0x0"])
    time_board = call(cfg, runs, "leaderboard", [hex(VERSION_ID), "0x1", "0x0", "0xa"])
    print(f"  leaderboard(score), {int(board_len['raw'][0], 16)} entries: {board['value']}")

    verifier_total = sum(r["l2_gas"] for r in verifier_rows)
    consumer_total = sum(r["l2_gas"] for r in consumer_rows if r.get("label") == "submit_batch")
    setup_total = sum(r["l2_gas"] for r in setup)
    doc = {
        "network": "starknet-devnet 0.10.0 (local)", "url": cfg.url,
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "what": "P4.2b: real ten-felt root proofs verified by the P4.0 router, then consumed "
                "by DoomRuns pointed at that router (no MockFactRegistry)",
        "prices": prices, "mainnet_price_snapshot": S5_SNAPSHOT,
        "router": router, "doom_runs": runs, "owner": owner,
        "classes": {**classes, "DoomRuns": runs_class},
        "deploys": {"StwoCircuitRouter": router_deploy, "DoomRuns": runs_deploy},
        "batches": [{
            "name": b["name"], "shape": b["shape"], "n_leaves": len(b["leaves"]),
            "program_hash": hex(b["program_hash"]), "genesis": hex(b["genesis"]),
            "leaf_circuit_hash": b["leaf_circuit_hash"],
            "multiverifier_hash": b["multiverifier_hash"],
            "output_hash": b["output_hash"], "verifier_output": b["verifier_output"],
            "fact": hex(b["fact"]), "router_fact": b["router_fact"],
            "verifier_l2_gas": b["verifier_l2_gas"],
            "runs_submitted": b.get("runs_submitted"),
            "members_rejected": b.get("members_rejected"),
            "members": [{**m, "run_id": hex(m["run_id"])} for m in b["members"]],
        } for b in batches],
        "verifier_txs": verifier_rows,
        "version_setup": setup,
        "consumer_txs": consumer_rows,
        "run_checks": checks,
        "leaderboard_score": board, "leaderboard_time": time_board,
        "leaderboard_len": int(board_len["raw"][0], 16),
        "totals": {
            "verifier_l2_gas": verifier_total,
            "version_setup_l2_gas": setup_total,
            "consumer_l2_gas": consumer_total,
            "full_path_l2_gas": verifier_total + setup_total + consumer_total,
            "consumer_pct_of_verifier": round(100 * consumer_total / verifier_total, 3),
            "declare_l2_gas": sum(c["l2_gas"] for c in
                                  [*classes.values(), runs_class]),
            "fee_fri": sum(r["fee_fri"] for r in
                           verifier_rows + setup + consumer_rows),
        },
    }
    priced = []
    for sc in (S5_SNAPSHOT,):
        l2 = doc["totals"]["full_path_l2_gas"]
        l1d = sum(r.get("l1_data_gas") or 0 for r in verifier_rows + setup + consumer_rows)
        fee = l2 * sc["l2_gas_price_fri"] + l1d * sc["l1_data_gas_price_fri"]
        priced.append({"label": sc["label"], "l2_gas": l2, "l1_data_gas": l1d,
                       "fee_strk": fee / 1e18, "fee_usd": fee / 1e18 * sc["strk_usd"]})
    doc["priced_full_path"] = priced
    cfg.out.parent.mkdir(parents=True, exist_ok=True)
    cfg.out.write_text(json.dumps(doc, indent=1))
    print(f"\nverifier {verifier_total:,} + setup {setup_total:,} + consumer {consumer_total:,} "
          f"= {doc['totals']['full_path_l2_gas']:,} L2 gas "
          f"({doc['totals']['consumer_pct_of_verifier']} % consumer)")
    for p in priced:
        print(f"  {p['label']:<42} {p['fee_strk']:8.3f} STRK  ${p['fee_usd']:.3f}")
    print("->", cfg.out)


if __name__ == "__main__":
    main()

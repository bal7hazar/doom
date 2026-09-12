#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Devnet drive of the resumable verifier — the gas oracle for one fact (R3-A7, R7-A6).

Declares the four classes (`StwoPhasesBegin`, `StwoPhasesMerkle`, `StwoPhasesFri`,
`StwoCircuitRouter`), deploys the router, and plays the transactions of `calls.json`
(`tools/emit_calldata.py`) in order against a LOCAL starknet-devnet, threading the checkpoint
state returned by each transaction into the next one's calldata. Receipts are recorded verbatim
with the per-invoke-cap ratio, then priced at the devnet's prices and at a mainnet snapshot.

Nothing here can reach a public network: the URL must be a local devnet.

Usage:
  tools/devnet_drive.py --calls calls.json --out results/devnet_receipts.json \
      --accounts-file <accounts.json> [--account devnet42] [--url http://127.0.0.1:5055/rpc] \
      [--deployment results/devnet_deployment.json]   # reuse an earlier declare+deploy

Explicit resource bounds are mandatory (sncast's automatic x1.5 pushes a large invoke past the
1.21e9 per-invoke cap, S5 §6): `l2_gas` = the snforge figure x1.15 rounded up, capped at 95 %
of the invoke cap; `l1_data_gas` carries a wide margin (under-provisioning REVERTS).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PACKAGE_DIR = HERE.parent
PACKAGE = "doom_contracts"
CLASSES = ["StwoPhasesBegin", "StwoPhasesMerkle", "StwoPhasesFri", "StwoCircuitRouter"]

INVOKE_L2_GAS_CAP = 1_210_000_000
CAP_SAFETY = 0.9  # R7-A5

# l2 gas bounds per entrypoint: generous (the receipt reports the real consumption; the bound
# only has to be accepted by the sequencer, i.e. stay under the cap).
BOUNDS_L2 = {
    "begin": 1_150_000_000,
    "merkle": 1_150_000_000,
    "answers": 1_150_000_000,
    "fri": 1_150_000_000,
}
BOUND_L1_GAS = 100_000
BOUND_L1_DATA_GAS = 40_000

# Mainnet price snapshot of docs/spikes/S5.md §5 (2026-09-12 13:20 UTC), used when the live
# read-only fetch is disabled or fails.
S5_SNAPSHOT = {
    "label": "mainnet 2026-09-12 (S5 §5 snapshot)",
    "l2_gas_price_fri": 30_528_000_000,
    "l1_data_gas_price_fri": 38_328_000_000,
    "l1_gas_price_fri": 93_024_150_000_000,
    "strk_usd": 0.02876053,
    "strk_eur": 0.02478928,
}
L2_GAS_PRICE_FLOOR_FRI = 3_000_000_000
MAINNET_RPC = "https://api.cartridge.gg/x/starknet/mainnet"
PRICE_API = "https://api.coingecko.com/api/v3/simple/price?ids=starknet&vs_currencies=usd,eur"


def rpc(url: str, method: str, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        reply = json.load(resp)
    if "error" in reply:
        raise RuntimeError(f"{method}: {reply['error']}")
    return reply["result"]


def sncast(args: list[str], cfg, retries: int = 1):
    cmd = ["sncast", "--json", "--accounts-file", str(cfg.accounts_file),
           "--account", cfg.account] + args + ["--url", cfg.url]
    for attempt in range(retries + 1):
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=PACKAGE_DIR)
        if r.returncode == 0:
            break
        if attempt == retries:
            sys.exit(f"sncast failed: {' '.join(cmd[:8])}…\n{r.stdout[-3000:]}\n{r.stderr[-3000:]}")
        time.sleep(2)
    objs = [json.loads(l) for l in r.stdout.strip().splitlines() if l.strip().startswith("{")]
    for o in objs:
        if o.get("type") == "response":
            return o
    return objs[-1] if objs else {}


def wait_receipt(url: str, tx_hash: str, timeout: int = 900):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            rec = rpc(url, "starknet_getTransactionReceipt", [tx_hash])
        except RuntimeError:
            time.sleep(0.5)
            continue
        status = rec.get("execution_status")
        if status == "REVERTED":
            sys.exit(f"tx {tx_hash} REVERTED: {rec.get('revert_reason')}")
        if status == "SUCCEEDED":
            return rec
        time.sleep(0.5)
    sys.exit(f"tx {tx_hash}: no receipt after {timeout}s")


def gas_prices(url: str) -> dict:
    block = rpc(url, "starknet_getBlockWithTxHashes", ["latest"])
    return {
        "l1_gas_price_fri": int(block["l1_gas_price"]["price_in_fri"], 16),
        "l1_data_gas_price_fri": int(block["l1_data_gas_price"]["price_in_fri"], 16),
        "l2_gas_price_fri": int(block["l2_gas_price"]["price_in_fri"], 16),
        "starknet_version": block.get("starknet_version"),
        "block_number": block.get("block_number"),
    }


def trace(url: str, tx_hash: str) -> dict:
    try:
        return rpc(url, "starknet_traceTransaction", [tx_hash])
    except RuntimeError:
        return {}


def state_diff_stats(tr: dict) -> dict:
    sd = tr.get("state_diff") or {}
    writes = sum(len(e.get("storage_entries", [])) for e in sd.get("storage_diffs", []))
    return {"storage_writes": writes, "nonce_updates": len(sd.get("nonces", []))}


def retdata(tr: dict):
    try:
        return tr["execute_invocation"]["calls"][0]["result"]
    except (KeyError, IndexError, TypeError):
        return None


def live_mainnet_prices() -> dict | None:
    """Read-only: the latest mainnet block's prices and the STRK spot price."""
    try:
        p = gas_prices(MAINNET_RPC)
        with urllib.request.urlopen(PRICE_API, timeout=20) as resp:
            spot = json.load(resp)["starknet"]
        return {"label": f"mainnet live block {p['block_number']} "
                         f"({time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())})",
                **{k: p[k] for k in ("l1_gas_price_fri", "l1_data_gas_price_fri", "l2_gas_price_fri")},
                "strk_usd": spot["usd"], "strk_eur": spot["eur"]}
    except Exception as e:  # noqa: BLE001
        print("live mainnet prices unavailable:", e)
        return None


# --------------------------------------------------------------------------------- calldata


def felts_of_span(values) -> list[str]:
    return [hex(len(values))] + [v if isinstance(v, str) else hex(v) for v in values]


def calldata_for(tx: dict, echo: list[str] | None) -> list[str]:
    a = tx["args"]
    cd = [hex(a["proof_id"])]
    if tx["entrypoint"] != "begin":
        assert echo is not None, f"{tx['label']}: missing state echo"
        cd += felts_of_span(echo)
    cd += felts_of_span(a["payload"])
    if tx["entrypoint"] in ("begin", "merkle", "answers"):
        cd += felts_of_span(a["lens"])
    if tx["entrypoint"] in ("begin", "merkle"):
        cd += felts_of_span(a["trees"])
    if tx["entrypoint"] == "fri":
        cd.append(hex(a["n_values"]))
    return cd


# ------------------------------------------------------------------------------------- main


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--calls", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--url", default="http://127.0.0.1:5055/rpc")
    ap.add_argument("--account", default="devnet42")
    ap.add_argument("--accounts-file", type=Path, required=True)
    ap.add_argument("--deployment", type=Path, help="reuse an earlier declare + deploy")
    ap.add_argument("--no-live", action="store_true", help="skip the read-only mainnet price fetch")
    cfg = ap.parse_args()

    if not any(h in cfg.url for h in ("127.0.0.1", "localhost")):
        sys.exit("refusing to drive anything but a local devnet")

    prices = gas_prices(cfg.url)
    print("devnet prices:", prices)

    # --- declares + deploy -------------------------------------------------
    if cfg.deployment and cfg.deployment.exists():
        prev = json.loads(cfg.deployment.read_text())
        router, classes, deploy_fee = prev["router"], prev["classes"], prev["deploy_fee_fri"]
        print("reusing router", router)
    else:
        classes = {}
        for name in CLASSES:
            res = sncast(["declare", "--contract-name", name, "--package", PACKAGE], cfg)
            rec = wait_receipt(cfg.url, res["transaction_hash"])
            er = rec["execution_resources"]
            classes[name] = {
                "class_hash": res["class_hash"], "tx_hash": res["transaction_hash"],
                "l2_gas": er.get("l2_gas"), "l1_gas": er.get("l1_gas"),
                "l1_data_gas": er.get("l1_data_gas"),
                "fee_fri": int(rec["actual_fee"]["amount"], 16),
            }
            print(f"declared {name:<18} {res['class_hash']}  l2_gas {er.get('l2_gas'):>13,}  "
                  f"fee {classes[name]['fee_fri']/1e18:.4f} STRK")
        dep = sncast(["deploy", "--class-hash", classes["StwoCircuitRouter"]["class_hash"],
                      "--constructor-calldata",
                      classes["StwoPhasesBegin"]["class_hash"],
                      classes["StwoPhasesMerkle"]["class_hash"],
                      classes["StwoPhasesFri"]["class_hash"]], cfg)
        router = dep["contract_address"]
        deploy_fee = int(wait_receipt(cfg.url, dep["transaction_hash"])["actual_fee"]["amount"], 16)
        print("router", router)
        dep_doc = {"router": router, "classes": classes, "deploy_fee_fri": deploy_fee,
                   "prices": prices, "url": cfg.url}
        dep_path = cfg.out.with_name(cfg.out.stem + "_deployment.json")
        dep_path.write_text(json.dumps(dep_doc, indent=1))
        print("->", dep_path)

    # --- the transactions -------------------------------------------------
    doc = json.loads(cfg.calls.read_text())
    rows, echo = [], None
    for tx in doc["txs"]:
        l2 = BOUNDS_L2[tx["entrypoint"]]
        assert l2 <= INVOKE_L2_GAS_CAP
        cd = calldata_for(tx, echo)
        inv = sncast([
            "invoke", "--contract-address", router, "--function", tx["entrypoint"],
            "--l2-gas", str(l2), "--l2-gas-price", str(prices["l2_gas_price_fri"]),
            "--l1-gas", str(BOUND_L1_GAS), "--l1-gas-price", str(prices["l1_gas_price_fri"]),
            "--l1-data-gas", str(BOUND_L1_DATA_GAS),
            "--l1-data-gas-price", str(prices["l1_data_gas_price_fri"]),
            "--calldata"] + cd, cfg)
        rec = wait_receipt(cfg.url, inv["transaction_hash"])
        tr = trace(cfg.url, inv["transaction_hash"])
        er = rec["execution_resources"]
        ret = retdata(tr)
        row = {
            "label": tx["label"], "entrypoint": tx["entrypoint"],
            "tx_hash": inv["transaction_hash"],
            "calldata_felts": len(cd), "payload_slots": tx["payload_slots"],
            "echo_felts": len(echo) if echo else 0,
            "l2_gas": er.get("l2_gas"), "l1_gas": er.get("l1_gas"),
            "l1_data_gas": er.get("l1_data_gas"),
            "fee_fri": int(rec["actual_fee"]["amount"], 16),
            "bounds": {"l2_gas": l2, "l1_gas": BOUND_L1_GAS, "l1_data_gas": BOUND_L1_DATA_GAS},
            "meta": tx["meta"],
            **state_diff_stats(tr),
        }
        row["pct_of_invoke_cap"] = round(100 * row["l2_gas"] / INVOKE_L2_GAS_CAP, 2)
        row["under_90pct_cap"] = row["l2_gas"] <= CAP_SAFETY * INVOKE_L2_GAS_CAP
        rows.append(row)
        # The returned state (`Array<felt252>`: len ‖ felts) is the next echo.
        if ret:
            n = int(ret[0], 16)
            echo = ret[1 : 1 + n]
            assert len(echo) == n, "retdata length"
        print(f"  {row['label']:<8} calldata {row['calldata_felts']:>5}  l2_gas {row['l2_gas']:>13,} "
              f"({row['pct_of_invoke_cap']:>5.1f}% of cap)  l1_data_gas {row['l1_data_gas']:>6}  "
              f"fee {row['fee_fri']/1e18:.4f} STRK  writes {row['storage_writes']}")

    # --- fact check ---------------------------------------------------------
    fact = None
    last = rows[-1]
    events = rpc(cfg.url, "starknet_getTransactionReceipt", [last["tx_hash"]]).get("events", [])
    for ev in events:
        if len(ev.get("keys", [])) == 2 and len(ev.get("data", [])) == 2:
            fact = ev["keys"][1]  # FactRegistered { #[key] fact, caller, proof_id }
    is_valid = None
    if fact:
        res = sncast(["call", "--contract-address", router, "--function", "is_valid",
                      "--calldata", fact], cfg)
        is_valid = int(res["response"][0], 16) == 1 if isinstance(res.get("response"), list) \
            else res.get("response")

    # --- pricing -------------------------------------------------------------
    total_l2 = sum(r["l2_gas"] for r in rows)
    total_l1d = sum(r["l1_data_gas"] for r in rows)
    total_fee = sum(r["fee_fri"] for r in rows)
    scenarios = [S5_SNAPSHOT]
    if not cfg.no_live:
        live = live_mainnet_prices()
        if live:
            scenarios.insert(0, live)
    scenarios.append({"label": "protocol floor (3 gFri)", "l2_gas_price_fri": L2_GAS_PRICE_FLOOR_FRI,
                      "l1_data_gas_price_fri": S5_SNAPSHOT["l1_data_gas_price_fri"],
                      "l1_gas_price_fri": 0, "strk_usd": S5_SNAPSHOT["strk_usd"],
                      "strk_eur": S5_SNAPSHOT["strk_eur"]})
    priced = []
    for sc in scenarios:
        fee = total_l2 * sc["l2_gas_price_fri"] + total_l1d * sc["l1_data_gas_price_fri"]
        priced.append({"label": sc["label"], "l2_gas_price_gfri": sc["l2_gas_price_fri"] / 1e9,
                       "fee_strk": fee / 1e18, "fee_usd": fee / 1e18 * sc["strk_usd"],
                       "fee_eur": fee / 1e18 * sc["strk_eur"]})

    out = {
        "network": "starknet-devnet (local)", "url": cfg.url,
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "prices": prices, "router": router, "classes": classes, "deploy_fee_fri": deploy_fee,
        "declare_l2_gas_total": sum(c["l2_gas"] for c in classes.values()),
        "declare_fee_strk_total": sum(c["fee_fri"] for c in classes.values()) / 1e18,
        "fact": fact, "fact_is_valid": is_valid,
        "txs": rows, "n_txs": len(rows), "total_l2_gas": total_l2, "total_l1_data_gas": total_l1d,
        "total_fee_fri": total_fee, "total_fee_strk_devnet_prices": total_fee / 1e18,
        "worst_tx_pct_of_cap": max(r["pct_of_invoke_cap"] for r in rows),
        "priced": priced,
    }
    cfg.out.write_text(json.dumps(out, indent=1))
    print(f"\n{len(rows)} txs, total l2_gas {total_l2:,} (worst tx {out['worst_tx_pct_of_cap']}% "
          f"of the cap), fact {fact} is_valid={is_valid}")
    for p in priced:
        print(f"  {p['label']:<48} {p['l2_gas_price_gfri']:7.3f} gFri  {p['fee_strk']:8.3f} STRK  "
              f"${p['fee_usd']:.3f}")
    print("->", cfg.out)


if __name__ == "__main__":
    main()

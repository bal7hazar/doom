#!/usr/bin/env python3
"""S5 devnet drive — the gas oracle for one Stwo fact.

Declares the three lane-1 classes (`StwoPhase1`, `StwoPhase2`,
`StwoFactRegistry`), deploys the registry, and plays the three
transactions of a fact (stage / phase 1 / phase 2) against a local
starknet-devnet, recording the receipts verbatim.

Everything runs on a LOCAL devnet. No transaction is ever sent to Sepolia
or mainnet by this script.

Usage:
  spikes/s5/drive.py --package-dir <ssv>/contracts/stwo_fact_registry \
      --calls results/calls.json --out results/devnet_receipts.json \
      [--url http://127.0.0.1:5055/rpc] [--account devnet42] \
      [--accounts-file <path>] [--skip-declare results/classes.json]

Explicit resource bounds are mandatory: sncast's automatic estimation
multiplies by 1.5, which pushes an ~874M-gas invoke past the 1.21e9
per-invoke cap (docs/lane1-results.md). Under-provisioned `l1_data_gas`
REVERTS rather than being rejected, so its bound carries a wider margin.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

CLASSES = ["StwoPhase1", "StwoPhase2", "StwoFactRegistry"]
PACKAGE = "stwo_fact_registry"

# Per-invoke L2 gas cap observed on Sepolia (sequencer rejection message).
INVOKE_L2_GAS_CAP = 1_210_000_000

# Bounds per call: (l2_gas, l1_gas, l1_data_gas). Chosen from the snforge
# figures scaled by the known ~1.6x production factor, then capped at 95%
# of the per-invoke bound so the sequencer accepts the bound itself.
BOUNDS = {
    "stage_proof": (150_000_000, 100_000, 40_000),
    "verify_phase1": (1_150_000_000, 100_000, 40_000),
    "verify_phase2": (1_150_000_000, 100_000, 40_000),
}


def rpc(url: str, method: str, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        reply = json.load(resp)
    if "error" in reply:
        raise RuntimeError(f"{method}: {reply['error']}")
    return reply["result"]


def sncast(args: list[str], cfg, cwd: Path | None = None, retries: int = 1):
    cmd = [
        "sncast", "--json",
        "--accounts-file", str(cfg.accounts_file),
        "--account", cfg.account,
    ] + args + ["--url", cfg.url]
    for attempt in range(retries + 1):
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
        if r.returncode == 0:
            break
        if attempt == retries:
            sys.exit(f"sncast failed: {' '.join(cmd[:10])}…\n{r.stdout}\n{r.stderr}")
        time.sleep(2)
    # sncast --json emits one JSON object per line (progress, response,
    # notification); the payload is the one tagged `"type": "response"`.
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
        "l1_da_mode": block.get("l1_da_mode"),
    }


def state_diff_stats(url: str, tx_hash: str) -> dict:
    """Storage writes and state-diff felt weight from the transaction trace."""
    try:
        trace = rpc(url, "starknet_traceTransaction", [tx_hash])
    except RuntimeError:
        return {}
    sd = trace.get("state_diff") or {}
    writes = sum(len(e.get("storage_entries", [])) for e in sd.get("storage_diffs", []))
    return {
        "storage_writes": writes,
        "nonce_updates": len(sd.get("nonces", [])),
        "state_diff_felts": 2 * writes + 2 * len(sd.get("nonces", [])),
    }


def retdata(url: str, tx_hash: str):
    try:
        trace = rpc(url, "starknet_traceTransaction", [tx_hash])
        return trace["execute_invocation"]["calls"][0]["result"]
    except (RuntimeError, KeyError, IndexError):
        return None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--package-dir", type=Path, required=True,
                    help="path to the stwo_fact_registry package of the ssv checkout")
    ap.add_argument("--calls", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--url", default="http://127.0.0.1:5055/rpc")
    ap.add_argument("--account", default="devnet42")
    ap.add_argument("--accounts-file", type=Path, required=True)
    ap.add_argument("--skip-declare", type=Path)
    ap.add_argument("--deploy-only", action="store_true",
                    help="declare + deploy, then stop (so estimate.ts can simulate "
                         "against the same pre-drive state)")
    ap.add_argument("--deployment", type=Path,
                    help="reuse the registry/classes recorded by an earlier --deploy-only run")
    cfg = ap.parse_args()

    if "sepolia" in cfg.url.lower() or "mainnet" in cfg.url.lower():
        sys.exit("refusing to drive anything but a local devnet")

    prices = gas_prices(cfg.url)
    print("devnet prices:", prices)

    # --- reuse an earlier deployment --------------------------------------
    if cfg.deployment and cfg.deployment.exists():
        prev = json.loads(cfg.deployment.read_text())
        registry, hashes = prev["registry"], prev["classes"]
        deploy_fee = prev["deploy_fee_fri"]
        print("reusing registry", registry)
        return _drive(cfg, prices, registry, hashes, deploy_fee)

    # --- declares ---------------------------------------------------------
    if cfg.skip_declare and cfg.skip_declare.exists():
        hashes = json.loads(cfg.skip_declare.read_text())
    else:
        hashes = {}
        for name in CLASSES:
            res = sncast(["declare", "--contract-name", name, "--package", PACKAGE],
                         cfg, cwd=cfg.package_dir)
            hashes[name] = {"class_hash": res["class_hash"]}
            rec = wait_receipt(cfg.url, res["transaction_hash"])
            er = rec["execution_resources"]
            hashes[name].update({
                "tx_hash": res["transaction_hash"],
                "l2_gas": er.get("l2_gas"),
                "l1_gas": er.get("l1_gas"),
                "l1_data_gas": er.get("l1_data_gas"),
                "fee_fri": int(rec["actual_fee"]["amount"], 16),
            })
            print(f"declared {name:<18} {res['class_hash']}  "
                  f"l2_gas {er.get('l2_gas'):>13,}  fee {hashes[name]['fee_fri']/1e18:.4f} STRK")
        cfg.out.with_suffix(".classes.json").write_text(json.dumps(hashes, indent=1))

    # --- deploy -----------------------------------------------------------
    dep = sncast(["deploy", "--class-hash", hashes["StwoFactRegistry"]["class_hash"],
                  "--constructor-calldata",
                  hashes["StwoPhase1"]["class_hash"], hashes["StwoPhase2"]["class_hash"]],
                 cfg, cwd=cfg.package_dir)
    registry = dep["contract_address"]
    deploy_rec = wait_receipt(cfg.url, dep["transaction_hash"])
    deploy_fee = int(deploy_rec["actual_fee"]["amount"], 16)
    print("registry", registry)

    if cfg.deploy_only:
        doc = {"registry": registry, "classes": hashes, "deploy_fee_fri": deploy_fee,
               "prices": prices, "url": cfg.url}
        path = cfg.out.with_name(cfg.out.stem + "_deployment.json")
        path.write_text(json.dumps(doc, indent=1))
        print("->", path)
        return

    _drive(cfg, prices, registry, hashes, deploy_fee)


def _drive(cfg, prices, registry, hashes, deploy_fee):
    # --- the three transactions -------------------------------------------
    doc = json.loads(cfg.calls.read_text())
    rows = []
    for call in doc["calls"]:
        l2, l1, l1d = BOUNDS[call["entrypoint"]]
        assert l2 <= INVOKE_L2_GAS_CAP, f"{call['label']}: bound over the invoke cap"
        inv = sncast([
            "invoke", "--contract-address", registry,
            "--function", call["entrypoint"],
            "--l2-gas", str(l2), "--l2-gas-price", str(prices["l2_gas_price_fri"]),
            "--l1-gas", str(l1), "--l1-gas-price", str(prices["l1_gas_price_fri"]),
            "--l1-data-gas", str(l1d),
            "--l1-data-gas-price", str(prices["l1_data_gas_price_fri"]),
            "--calldata"] + call["calldata"], cfg)
        rec = wait_receipt(cfg.url, inv["transaction_hash"])
        er = rec["execution_resources"]
        row = {
            "label": call["label"],
            "entrypoint": call["entrypoint"],
            "tx_hash": inv["transaction_hash"],
            "calldata_felts": call["calldata_felts"],
            "l2_gas": er.get("l2_gas"),
            "l1_gas": er.get("l1_gas"),
            "l1_data_gas": er.get("l1_data_gas"),
            "fee_fri": int(rec["actual_fee"]["amount"], 16),
            "bounds": {"l2_gas": l2, "l1_gas": l1, "l1_data_gas": l1d},
            "meta": call["meta"],
        }
        row.update(state_diff_stats(cfg.url, inv["transaction_hash"]))
        row["retdata"] = retdata(cfg.url, inv["transaction_hash"])
        row["pct_of_invoke_cap"] = round(100 * row["l2_gas"] / INVOKE_L2_GAS_CAP, 2)
        rows.append(row)
        print(f"  {row['label']:<15} l2_gas {row['l2_gas']:>13,} "
              f"({row['pct_of_invoke_cap']:>5.1f}% of cap)  "
              f"l1_data_gas {row['l1_data_gas']:>6}  fee {row['fee_fri']/1e18:.4f} STRK")

    # Cross-check the hard-coded FRI offset against what phase 1 returned.
    p1 = next(r for r in rows if r["entrypoint"] == "verify_phase1")
    if p1["retdata"]:
        got = int(p1["retdata"][0], 16)
        assert got == doc["fri_value_offset"], \
            f"phase1 returned fri_value_offset {got}, calls.json assumed {doc['fri_value_offset']}"
    fact = next(r for r in rows if r["entrypoint"] == "verify_phase2")["retdata"]

    total_l2 = sum(r["l2_gas"] for r in rows)
    total_fee = sum(r["fee_fri"] for r in rows)
    out = {
        "network": "starknet-devnet (local)",
        "url": cfg.url,
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "prices": prices,
        "registry": registry,
        "classes": hashes,
        "deploy_fee_fri": deploy_fee,
        "fact": fact[0] if fact else None,
        "txs": rows,
        "total_l2_gas": total_l2,
        "total_fee_fri": total_fee,
        "total_fee_strk": total_fee / 1e18,
    }
    cfg.out.write_text(json.dumps(out, indent=1))
    print(f"\n3 txs, total l2_gas {total_l2:,}, total fee {total_fee/1e18:.4f} STRK")
    print("fact:", out["fact"])
    print("->", cfg.out)


if __name__ == "__main__":
    main()

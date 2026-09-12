#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Transport calibration on devnet: the receipts of `probe_noop` and `probe_unpack` over one
real fast-path payload (the first FRI transaction's layers 0-1, one section), which isolate the per-slot cost of
the packed transport (calldata + unpack) from the verifier compute. Reuses the phase classes of
an earlier drive deployment and declares/deploys the current router.

Usage: tools/devnet_probe.py --calls calls.json --deployment results/devnet_receipts_deployment.json \
           --accounts-file <accounts.json> [--url http://127.0.0.1:5066/rpc] --out results/devnet_probe.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from devnet_drive import (BOUND_L1_DATA_GAS, BOUND_L1_GAS, felts_of_span, gas_prices, retdata,  # noqa: E402
                          sncast, trace, wait_receipt)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--calls", type=Path, required=True)
    ap.add_argument("--deployment", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--url", default="http://127.0.0.1:5066/rpc")
    ap.add_argument("--account", default="devnet42")
    ap.add_argument("--accounts-file", type=Path, required=True)
    cfg = ap.parse_args()
    if not any(h in cfg.url for h in ("127.0.0.1", "localhost")):
        sys.exit("refusing to drive anything but a local devnet")

    prices = gas_prices(cfg.url)
    dep = json.loads(cfg.deployment.read_text())
    classes = dep["classes"]
    res = sncast(["declare", "--contract-name", "StwoCircuitRouter", "--package", "doom_contracts"],
                 cfg, allow_error="is already declared")
    router_class = res["class_hash"] if res.get("type") == "response" \
        else res["error"].split("class hash ")[1].split(" ")[0]
    if res.get("type") == "response":
        wait_receipt(cfg.url, res["transaction_hash"])
    d = sncast(["deploy", "--class-hash", router_class, "--constructor-calldata",
                classes["StwoPhasesBegin"]["class_hash"], classes["StwoPhasesMerkle"]["class_hash"],
                classes["StwoPhasesFri"]["class_hash"]], cfg)
    router = d["contract_address"]
    wait_receipt(cfg.url, d["transaction_hash"])

    doc = json.loads(cfg.calls.read_text())
    # A single fast-path section (the first FRI chunk): payload = n_slots(n_values) slots.
    fri1 = next(t for t in doc["txs"] if t["entrypoint"] == "fri")
    payload = fri1["args"]["payload"]
    n_values = fri1["args"]["n_values"]
    rows = []
    for fn, cd in (("probe_noop", felts_of_span(payload)),
                   ("probe_unpack", felts_of_span(payload) + [hex(n_values)])):
        inv = sncast(["invoke", "--contract-address", router, "--function", fn,
                      "--l2-gas", "1150000000", "--l2-gas-price", str(prices["l2_gas_price_fri"]),
                      "--l1-gas", str(BOUND_L1_GAS), "--l1-gas-price", str(prices["l1_gas_price_fri"]),
                      "--l1-data-gas", str(BOUND_L1_DATA_GAS),
                      "--l1-data-gas-price", str(prices["l1_data_gas_price_fri"]),
                      "--calldata"] + cd, cfg)
        rec = wait_receipt(cfg.url, inv["transaction_hash"])
        tr = trace(cfg.url, inv["transaction_hash"])
        execute = tr["execute_invocation"]["calls"][0]["execution_resources"]["l2_gas"]
        rows.append({"fn": fn, "tx_hash": inv["transaction_hash"], "calldata_felts": len(cd),
                     "slots": len(payload), "n_values": n_values,
                     "l2_gas_receipt": rec["execution_resources"]["l2_gas"],
                     "l2_gas_router_call": execute, "retdata": retdata(tr)})
        print(f"{fn:<13} calldata {len(cd):>5} receipt l2_gas {rows[-1]['l2_gas_receipt']:>13,} "
              f"router call {execute:>13,}")
    noop, unp = rows
    per_slot = (unp["l2_gas_router_call"] - noop["l2_gas_router_call"]) / len(payload)
    out = {"router": router, "router_class": router_class, "prices": prices, "rows": rows,
           "unpack_gas_per_slot": per_slot,
           "calldata_gas_per_felt": (noop["l2_gas_receipt"] - noop["l2_gas_router_call"]) / len(payload)}
    print(f"unpack: {per_slot:,.0f} L2 gas per slot ({per_slot / 7:,.0f} per value); "
          f"tx overhead (calldata + validate + fee) {out['calldata_gas_per_felt']:,.0f} per felt")
    cfg.out.write_text(json.dumps(out, indent=1))
    print("->", cfg.out)


if __name__ == "__main__":
    main()

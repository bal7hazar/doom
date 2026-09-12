#!/usr/bin/env python3
"""Measure the consumer transaction: `DoomRunsStub.submit_run` on devnet.

Declares and deploys `spikes/s5/doomruns_stub`, then calls `submit_run`
for N segments, N in {8, 25, 50} by default, recording the receipts.

This sizes the *fourth* transaction of a submission (PLAN.md Phase 4):
the on-chain recomposition of the leaf-output chain (RISKS.md R3-A4) plus
the `Run` record. Local devnet only.

Usage:
  spikes/s5/stub_drive.py --package-dir spikes/s5/doomruns_stub \
      --out results/doomruns_stub.json [--n 8 25 50]
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from drive import (  # noqa: E402  (same directory)
    INVOKE_L2_GAS_CAP,
    gas_prices,
    sncast,
    state_diff_stats,
    wait_receipt,
)

WORDS_PER_SEGMENT = 8
STATUS_EXIT = 2
GENESIS = 0x1000


def segments_calldata(run_id: int, n: int) -> list[str]:
    """`submit_run(run_id, genesis, outputs)` for an n-segment run."""
    words: list[int] = []
    for i in range(n):
        h_in = GENESIS + i
        h_out = GENESIS + i + 1
        words += [
            h_in,
            h_out,
            (i + 1) * 1_050,  # tics
            (i + 1) * 3,  # kills
            (i + 1) * 2,  # items
            i % 4,  # secrets
            (i + 1) * 137,  # score
            STATUS_EXIT if i == n - 1 else 0,
        ]
    assert len(words) == n * WORDS_PER_SEGMENT
    return [hex(x) for x in [run_id, GENESIS, len(words)] + words]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--package-dir", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--url", default="http://127.0.0.1:5055/rpc")
    ap.add_argument("--account", default="devnet42")
    ap.add_argument("--accounts-file", type=Path, required=True)
    ap.add_argument("--n", type=int, nargs="+", default=[8, 25, 50])
    cfg = ap.parse_args()

    prices = gas_prices(cfg.url)
    dec = sncast(["declare", "--contract-name", "DoomRunsStub", "--package", "doomruns_stub"],
                 cfg, cwd=cfg.package_dir)
    class_hash = dec["class_hash"]
    dec_rec = wait_receipt(cfg.url, dec["transaction_hash"])
    print(f"declared DoomRunsStub {class_hash}  "
          f"l2_gas {dec_rec['execution_resources'].get('l2_gas'):,}")

    dep = sncast(["deploy", "--class-hash", class_hash], cfg, cwd=cfg.package_dir)
    address = dep["contract_address"]
    wait_receipt(cfg.url, dep["transaction_hash"])
    print("stub at", address)

    rows = []
    for n in cfg.n:
        calldata = segments_calldata(0xD00_0000 + n, n)
        inv = sncast([
            "invoke", "--contract-address", address, "--function", "submit_run",
            "--l2-gas", "400000000", "--l2-gas-price", str(prices["l2_gas_price_fri"]),
            "--l1-gas", "100000", "--l1-gas-price", str(prices["l1_gas_price_fri"]),
            "--l1-data-gas", "40000",
            "--l1-data-gas-price", str(prices["l1_data_gas_price_fri"]),
            "--calldata"] + calldata, cfg)
        rec = wait_receipt(cfg.url, inv["transaction_hash"])
        er = rec["execution_resources"]
        row = {
            "n_segments": n,
            "tx_hash": inv["transaction_hash"],
            "calldata_felts": len(calldata),
            "l2_gas": er.get("l2_gas"),
            "l1_gas": er.get("l1_gas"),
            "l1_data_gas": er.get("l1_data_gas"),
            "fee_fri": int(rec["actual_fee"]["amount"], 16),
            "pct_of_invoke_cap": round(100 * er.get("l2_gas") / INVOKE_L2_GAS_CAP, 3),
        }
        row.update(state_diff_stats(cfg.url, inv["transaction_hash"]))
        rows.append(row)
        print(f"  N={n:<3} calldata {row['calldata_felts']:>4}  "
              f"l2_gas {row['l2_gas']:>11,}  l1_data_gas {row['l1_data_gas']:>6}  "
              f"fee {row['fee_fri']/1e18:.4f} STRK")

    if len(rows) >= 2:
        a, b = rows[0], rows[-1]
        per_seg = (b["l2_gas"] - a["l2_gas"]) / (b["n_segments"] - a["n_segments"])
        fixed = a["l2_gas"] - per_seg * a["n_segments"]
        print(f"\nlinear fit: {fixed:,.0f} + {per_seg:,.0f} x N  L2 gas")
    else:
        per_seg = fixed = None

    cfg.out.write_text(json.dumps({
        "network": "starknet-devnet (local)",
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "prices": prices,
        "class_hash": class_hash,
        "address": address,
        "declare_l2_gas": dec_rec["execution_resources"].get("l2_gas"),
        "declare_fee_fri": int(dec_rec["actual_fee"]["amount"], 16),
        "runs": rows,
        "fit_l2_gas_fixed": fixed,
        "fit_l2_gas_per_segment": per_seg,
    }, indent=1))
    print("->", cfg.out)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Prints the per-call resources of a devnet transaction trace (where the gas of one
transaction goes: the account's __execute__, the router, each library call).

Usage: tools/trace_tx.py <tx_hash> [--url http://127.0.0.1:5066/rpc]
"""
import argparse
import json
import urllib.request


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req))


def walk(c, depth=0):
    res = c.get("execution_resources") or {}
    print(f"{'  ' * depth}{c.get('call_type', ''):<13} {c.get('class_hash', '')[:10]} "
          f"sel {c.get('entry_point_selector', '')[:10]} calldata {len(c.get('calldata', [])):>6} "
          f"ret {len(c.get('result', [])):>5}  l2_gas {res.get('l2_gas', 0):>13,}  "
          f"l1_gas {res.get('l1_gas', 0)} {'REVERTED' if c.get('is_reverted') else ''}")
    for cc in c.get("calls", []):
        walk(cc, depth + 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tx_hash", nargs="?")
    ap.add_argument("--url", default="http://127.0.0.1:5066/rpc")
    ap.add_argument("--blocks", help="trace every tx of these blocks, e.g. 7-10")
    a = ap.parse_args()
    if a.blocks:
        lo, hi = (int(x) for x in a.blocks.split("-"))
        for b in range(lo, hi + 1):
            blk = rpc(a.url, "starknet_getBlockWithTxHashes", [{"block_number": b}])["result"]
            for h in blk["transactions"]:
                print(f"\n### block {b} tx {h}")
                trace_one(a.url, h)
        return
    trace_one(a.url, a.tx_hash)


def trace_one(url, tx_hash):
    a = argparse.Namespace(url=url, tx_hash=tx_hash)
    rec = rpc(a.url, "starknet_getTransactionReceipt", [a.tx_hash])
    r = rec.get("result", rec)
    print("receipt:", r.get("execution_status"), r.get("execution_resources"),
          (r.get("revert_reason") or "")[:300])
    tr = rpc(a.url, "starknet_traceTransaction", [a.tx_hash])
    if "error" in tr:
        print("trace error:", tr["error"])
        return
    t = tr["result"]
    for k in ("validate_invocation", "execute_invocation", "fee_transfer_invocation"):
        if t.get(k):
            print(k)
            walk(t[k], 1)
    print("overall:", t.get("execution_resources"))


if __name__ == "__main__":
    main()

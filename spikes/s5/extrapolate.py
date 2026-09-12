#!/usr/bin/env python3
"""Extrapolate the measured fixture costs to the S4 root proof.

S5 measured one fact end to end on devnet with modeofO's fixture: a
36,022-felt root proof verified by a circuit verifier of ~3.8 M steps.
S4 reports that the root proof our own pipeline produces
(starkware-libs/proving @ cd7bc5f) is 93,500-96,000 felts and that the
on-chain circuit verifier costs 5.26-5.37 M steps, constant in N.

This script rescales the measured numbers with an explicit, stated model.
Everything it prints is a projection, not a measurement: the modeofO
classes embed an older vendored verifier (stwo-cairo 92bfd1d3) and would
not accept our root proof, so the real figures can only come from a drive
against our own re-vendored classes.

Model:
  gas(tx) = envelope + calldata + storage + compute
  * envelope, per-slot write and per-slot read costs are the ones S5
    measured (or CONTEXT.md §7 where noted); they do not depend on the
    proof size;
  * the compute residual of each verification phase is split into a
    felt-proportional part (unpack + deserialize, share `u`) scaled by the
    felt ratio, and a step-proportional part (the verification itself)
    scaled by the step ratio. `u` comes from docs/lane1-results.md, where
    unpack was 1.8e8 of the 1.8e8 + 5.2e8 unpack+verify budget.

Usage: extrapolate.py [--json results/extrapolation.json]
"""

from __future__ import annotations

import argparse
import json
import math

# ---------------------------------------------------------------- measured

# S5 devnet receipts (spikes/s5/results/devnet_receipts.json).
MEASURED = {"stage_proof": 78_556_800, "verify_phase1": 873_757_120, "verify_phase2": 815_709_840}

# Marginal cost of one staged slot on devnet 0.10.0 / starknet 0.14.4,
# from stage_proof at 0 and 40 slots: (20,760,640 - 835,840) / 40.
SLOT_WRITE_GAS = 498_120
# Same measurement against live Sepolia 0.14.3 from an OpenZeppelin account:
# (20,120,640 - 795,840) / 40 — devnet is 3.1 % conservative.
SLOT_WRITE_GAS_SEPOLIA = 483_120
# Empty stage_proof on devnet: account __execute__ + dispatch.
ENVELOPE_GAS = 835_840
# CONTEXT.md §7.
CALLDATA_GAS_PER_FELT = 5_120
SLOT_READ_GAS = 120_000

# Protocol limits (docs/lane1-results.md, CONTEXT.md §7).
INVOKE_L2_GAS_CAP = 1_210_000_000
CAP_SAFETY = 0.90
CALLDATA_SLOTS_PER_TX = 4_991  # 5,000 felts minus the envelope and scalars
STAGE_SLOTS_PER_TX = 1_900  # state-diff cap: 4,000 felts, 2 per write

# ------------------------------------------------------------------ shapes

FIXTURE = {"felts": 36_022, "slots": 5_147, "steps": 3_800_000,
           "head_slots": 4_991, "staged_slots": 156,
           "fri_values": 12_891, "fri_slots": 1_842,
           # storage_entries in the phase-1 receipt's state diff (checkpoint
           # words + length + the fee entry).
           "checkpoint_writes": 138}

# S4 (docs/spikes/S4.md): root proof 93,500-96,000 felts, verifier
# 5.26-5.37 M steps, constant in N.
S4 = {"felts_lo": 93_500, "felts_hi": 96_000, "steps_lo": 5_260_000, "steps_hi": 5_370_000}

# Share of the compute residual that scales with felts rather than steps.
U_SHARES = {"low": 0.15, "central": 0.26, "high": 0.40}

# Gas prices in FRI (S5 snapshot, 2026-09-12; see docs/spikes/S5.md).
PRICES = {
    "devnet / mainnet (30.475 gFri)": 30_475_398_907,
    "sepolia (30.522 gFri)": 30_522_019_377,
    "protocol floor (3 gFri)": 3_000_000_000,
}
STRK_USD = 0.02876053


def slots_for(felts: int) -> int:
    """7 u32 limbs per slot, at the fixture's observed packing density."""
    return math.ceil(felts * FIXTURE["slots"] / FIXTURE["felts"])


def decompose(label: str) -> dict:
    """Split a measured transaction into envelope / calldata / storage / compute."""
    g = MEASURED[label]
    if label == "stage_proof":
        calldata = (FIXTURE["staged_slots"] + 3) * CALLDATA_GAS_PER_FELT
        storage = FIXTURE["staged_slots"] * SLOT_WRITE_GAS - calldata
        compute = g - ENVELOPE_GAS - calldata - storage
    elif label == "verify_phase1":
        calldata = (FIXTURE["head_slots"] + 4) * CALLDATA_GAS_PER_FELT
        storage = (FIXTURE["staged_slots"] * SLOT_READ_GAS
                   + FIXTURE["checkpoint_writes"] * SLOT_WRITE_GAS)
        compute = g - ENVELOPE_GAS - calldata - storage
    else:
        calldata = (FIXTURE["fri_slots"] + 3) * CALLDATA_GAS_PER_FELT
        storage = (FIXTURE["checkpoint_writes"] * SLOT_READ_GAS + 2 * SLOT_WRITE_GAS)
        compute = g - ENVELOPE_GAS - calldata - storage
    return {"total": g, "envelope": ENVELOPE_GAS, "calldata": calldata,
            "storage": storage, "compute": compute}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", type=str, default="")
    args = ap.parse_args()

    out: dict = {"model": __doc__.split("Usage:")[0].strip(), "measured": MEASURED}

    print("=== 0. decomposition of the measured fixture transactions")
    parts = {k: decompose(k) for k in MEASURED}
    for k, p in parts.items():
        print(f"  {k:<14} total {p['total']:>13,}  envelope {p['envelope']:>9,}  "
              f"calldata {p['calldata']:>11,}  storage {p['storage']:>12,}  "
              f"compute {p['compute']:>13,}")
    out["decomposition"] = parts

    # All four (felt, step) corners of the S4 interval.
    scenarios = []
    for felt_tag, felts in (("lo", S4["felts_lo"]), ("hi", S4["felts_hi"])):
        for step_tag, steps in (("lo", S4["steps_lo"]), ("hi", S4["steps_hi"])):
            scenarios.append((f"{felts:,} felts / {steps/1e6:.2f} M steps", felts, steps))

    print("\n=== 1. staging the S4 root proof")
    print("  proof felts   slots   head    staged   staging txs   staging L2 gas   worst tx  %cap")
    staging_rows = []
    for felts in (S4["felts_lo"], S4["felts_hi"]):
        slots = slots_for(felts)
        head = min(CALLDATA_SLOTS_PER_TX, slots)
        staged = slots - head
        n_tx = math.ceil(staged / STAGE_SLOTS_PER_TX) if staged else 0
        per_tx = [min(STAGE_SLOTS_PER_TX, staged - i * STAGE_SLOTS_PER_TX) for i in range(n_tx)]
        gas = [ENVELOPE_GAS + n * SLOT_WRITE_GAS for n in per_tx]
        worst = max(gas) if gas else 0
        row = {"felts": felts, "slots": slots, "head_slots": head, "staged_slots": staged,
               "staging_txs": n_tx, "staging_l2_gas": sum(gas), "worst_tx_l2_gas": worst,
               "worst_pct_of_cap": 100 * worst / INVOKE_L2_GAS_CAP}
        staging_rows.append(row)
        print(f"  {felts:>11,} {slots:>7,} {head:>6,} {staged:>9,} {n_tx:>13} "
              f"{sum(gas):>16,} {worst:>10,} {row['worst_pct_of_cap']:>5.1f}")
    out["staging"] = staging_rows

    print("\n=== 2. verification, rescaled")
    print("  (compute residual x [(1-u)*step_ratio + u*felt_ratio]; storage and calldata rebuilt)")
    verif_rows = []
    for name, felts, steps in scenarios:
        felt_ratio = felts / FIXTURE["felts"]
        step_ratio = steps / FIXTURE["steps"]
        slots = slots_for(felts)
        head = min(CALLDATA_SLOTS_PER_TX, slots)
        staged = slots - head
        fri_values = round(FIXTURE["fri_values"] * felt_ratio)
        fri_slots = slots_for(fri_values)
        for u_name, u in U_SHARES.items():
            blend = (1 - u) * step_ratio + u * felt_ratio
            p1 = parts["verify_phase1"]
            p2 = parts["verify_phase2"]
            # phase 1: same 4,991-slot calldata head, but every staged slot is read back
            g1 = (ENVELOPE_GAS
                  + (head + 4) * CALLDATA_GAS_PER_FELT
                  + staged * SLOT_READ_GAS
                  + FIXTURE["checkpoint_writes"] * SLOT_WRITE_GAS
                  + p1["compute"] * blend)
            # phase 2: the FRI section grows with the proof; it no longer fits in
            # one transaction's calldata, so the excess is read from storage.
            fri_in_calldata = min(fri_slots, CALLDATA_SLOTS_PER_TX)
            fri_from_storage = max(0, fri_slots - fri_in_calldata)
            g2 = (ENVELOPE_GAS
                  + (fri_in_calldata + 3) * CALLDATA_GAS_PER_FELT
                  + fri_from_storage * SLOT_READ_GAS
                  + FIXTURE["checkpoint_writes"] * SLOT_READ_GAS
                  + 2 * SLOT_WRITE_GAS
                  + p2["compute"] * blend)
            total = g1 + g2
            n_invokes = math.ceil(total / (CAP_SAFETY * INVOKE_L2_GAS_CAP))
            row = {"scenario": name, "u": u, "u_name": u_name,
                   "felt_ratio": felt_ratio, "step_ratio": step_ratio, "blend": blend,
                   "phase1_l2_gas": round(g1), "phase2_l2_gas": round(g2),
                   "verification_l2_gas": round(total),
                   "phase1_pct_of_cap": 100 * g1 / INVOKE_L2_GAS_CAP,
                   "phase2_pct_of_cap": 100 * g2 / INVOKE_L2_GAS_CAP,
                   "fits_in_2_phases": g1 <= INVOKE_L2_GAS_CAP and g2 <= INVOKE_L2_GAS_CAP,
                   "min_invokes_at_90pct": n_invokes,
                   "fri_slots": fri_slots, "fri_from_storage": fri_from_storage}
            verif_rows.append(row)
    for r in verif_rows:
        if r["u_name"] != "central":
            continue
        print(f"  {r['scenario']:<28} u={r['u']}  phase1 {r['phase1_l2_gas']:>13,} "
              f"({r['phase1_pct_of_cap']:>5.0f}% cap)  phase2 {r['phase2_l2_gas']:>13,} "
              f"({r['phase2_pct_of_cap']:>5.0f}% cap)  -> >= {r['min_invokes_at_90pct']} invokes")
    lo = min(r["verification_l2_gas"] for r in verif_rows)
    hi = max(r["verification_l2_gas"] for r in verif_rows)
    print(f"  verification total across all (felts, steps, u) corners: "
          f"{lo:,} .. {hi:,} L2 gas")
    out["verification"] = verif_rows

    print("\n=== 3. cost per fact (staging + verification), STRK and USD")
    print("  shape                              L2 gas        " +
          "  ".join(f"{k:>26}" for k in PRICES))
    cost_rows = []
    baseline_total = sum(MEASURED.values())
    shapes = [("fixture baseline (measured)", baseline_total)]
    for felts in (S4["felts_lo"], S4["felts_hi"]):
        st = next(r for r in staging_rows if r["felts"] == felts)
        for u_name in ("central",):
            vs = [r for r in verif_rows
                  if r["u_name"] == u_name and r["scenario"].startswith(f"{felts:,}")]
            v_lo = min(r["verification_l2_gas"] for r in vs)
            v_hi = max(r["verification_l2_gas"] for r in vs)
            shapes.append((f"S4 {felts:,} felts, u=0.26, steps lo", st["staging_l2_gas"] + v_lo))
            shapes.append((f"S4 {felts:,} felts, u=0.26, steps hi", st["staging_l2_gas"] + v_hi))
    for name, gas in shapes:
        cells, entry = [], {"shape": name, "l2_gas": gas, "prices": {}}
        for pname, price in PRICES.items():
            strk = gas * price / 1e18
            cells.append(f"{strk:>12,.2f} STRK ${strk*STRK_USD:>7.2f}")
            entry["prices"][pname] = {"strk": strk, "usd": strk * STRK_USD}
        cost_rows.append(entry)
        print(f"  {name:<34} {gas:>13,}  " + "  ".join(cells))
    out["cost_per_fact"] = cost_rows

    print("\n=== 4. calldata-only transport (design option for Phase 4)")
    calldata_rows = []
    for felts in (S4["felts_lo"], S4["felts_hi"]):
        slots = slots_for(felts)
        packed_gas = slots * CALLDATA_GAS_PER_FELT
        raw_gas = felts * CALLDATA_GAS_PER_FELT
        txs_packed = math.ceil(slots / CALLDATA_SLOTS_PER_TX)
        txs_raw = math.ceil(felts / CALLDATA_SLOTS_PER_TX)
        st = next(r for r in staging_rows if r["felts"] == felts)
        row = {"felts": felts, "slots": slots,
               "packed_calldata_l2_gas": packed_gas, "packed_txs": txs_packed,
               "raw_calldata_l2_gas": raw_gas, "raw_txs": txs_raw,
               "staging_l2_gas": st["staging_l2_gas"],
               "saving_vs_staging": st["staging_l2_gas"] - packed_gas,
               "ratio_vs_staging": st["staging_l2_gas"] / packed_gas}
        calldata_rows.append(row)
        print(f"  {felts:,} felts -> {slots:,} packed slots")
        print(f"    packed as calldata   {packed_gas:>13,} L2 gas over >= {txs_packed} tx "
              f"(4,991-felt cap)")
        print(f"    unpacked as calldata {raw_gas:>13,} L2 gas over >= {txs_raw} tx")
        print(f"    staged in storage    {st['staging_l2_gas']:>13,} L2 gas over "
              f"{st['staging_txs']} tx  -> storage costs {row['ratio_vs_staging']:.0f}x more")
    out["calldata_only"] = calldata_rows

    if args.json:
        with open(args.json, "w") as f:
            json.dump(out, f, indent=1)
        print(f"\n-> {args.json}")


if __name__ == "__main__":
    main()

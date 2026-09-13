// SPDX-License-Identifier: Apache-2.0
/**
 * Bounds (R7-A1) and the 24 h price median (R7-A2), against the numbers S5 and P4.3 measured.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import {
  boundsFor,
  feeAt,
  priceEstimate,
  simulationBounds,
  withPrices,
  CAP_SAFETY,
  INVOKE_L2_GAS_CAP,
  L2_GAS_PRICE_FLOOR_FRI,
  MARGIN_L1_DATA,
  MARGIN_L2,
  type SequenceEstimate,
  type StepEstimate,
} from "../../../client/src/chain/estimate.js";
import {
  GasPriceMedian,
  MemorySampleStore,
  MIN_SAMPLES,
  SPIKE_FACTOR,
} from "../../../client/src/chain/median.js";
import {
  CachedPriceSource,
  StaticPriceSource,
  friToStrk,
  S5_SNAPSHOT,
} from "../../../client/src/chain/prices.js";
import type { GasPrices } from "../../../client/src/chain/rpc.js";

/** The devnet prices of the P4.2b drive, which are the S5 mainnet snapshot's. */
const PRICES: GasPrices = {
  l1GasPriceFri: 92_599_658_875_965n,
  l1DataGasPriceFri: 37_485_578_886n,
  l2GasPriceFri: 30_475_398_907n,
  blockNumber: 7,
  timestamp: 1_789_000_000,
  starknetVersion: "0.14.4",
};

const step = (label: string, l2: bigint, data = 256n): StepEstimate => ({
  index: 0,
  label,
  phase: "verifier",
  calldataFelts: 4625,
  estimate: { l1GasConsumed: 0n, l2GasConsumed: l2, l1DataGasConsumed: data, overallFee: 0n },
  pctOfCap: (100 * Number(l2)) / Number(INVOKE_L2_GAS_CAP),
});

describe("R7-A1 bounds", () => {
  it("applies ×1.15 to L2 gas and ×1.30 to L1 data gas, never a global ×1.5", () => {
    const b = boundsFor(step("answers", 861_288_640n, 320n), PRICES);
    expect(b.l2GasBound).toBe(BigInt(Math.ceil(861_288_640 * MARGIN_L2)));
    expect(b.l1DataGasBound).toBe(BigInt(Math.ceil(320 * MARGIN_L1_DATA)));
    expect(b.naiveX15L2Gas).toBe(BigInt(Math.ceil(861_288_640 * 1.5)));
    expect(b.naiveX15OverCap).toBe(true); // what sncast would have asked for, and lost
    expect(b.overCap).toBe(false);
  });

  it("flags the P4.0 five-transaction plan's fri1 bound as over the invoke cap", () => {
    // Measured on devnet in P4.3: 1 093 109 120 consumed, 90.3 % of the cap; ×1.15 = 103.9 %.
    const b = boundsFor(step("fri1", 1_093_109_120n), PRICES);
    expect(b.pctOfCap).toBeGreaterThan(100);
    expect(b.overCap).toBe(true);
  });

  it("accepts the historical P4.0 six-transaction plan's heaviest phase, above the 90 % rule", () => {
    const b = boundsFor(step("fri2", 1_021_952_320n), PRICES);
    expect(b.overCap).toBe(false);
    expect(b.over90PctRule).toBe(true);
    expect(b.pctOfCap).toBeLessThan(100);
  });

  it("keeps the historical P4.0 seven-transaction plan's heaviest phase under the 90 % rule", () => {
    const b = boundsFor(step("fri3", 910_606_080n), PRICES);
    expect(b.over90PctRule).toBe(false);
    expect(b.pctOfCap).toBeLessThan(100 * CAP_SAFETY);
  });

  it("applies unchanged R7-A1 margins to the observed P4.1 five-transaction consumption", () => {
    const receipts = JSON.parse(readFileSync(join(
      import.meta.dirname, "../../../cairo/doom_contracts/results/p41_receipts.json",
    ), "utf8"));
    const bounds = receipts.txs.map((r: any) => boundsFor(
      step(r.label, BigInt(r.l2_gas), BigInt(r.l1_data_gas)), PRICES,
    ));
    // Derived from receipt consumption, not a fresh simulation or the fixed bounds sent by
    // the historical Python drive. Sending still requires simulateSequence for this account.
    expect(bounds.map((b: any) => b.l2GasBound)).toEqual([
      347_858_808n, 268_532_912n, 536_381_712n, 338_801_040n, 279_695_180n,
    ]);
    expect(bounds.every((b: any) => !b.overCap && !b.over90PctRule)).toBe(true);
    expect(Math.max(...bounds.map((b: any) => b.pctOfCap))).toBeCloseTo(44.329067, 5);
    expect(receipts.total_l2_gas).toBe(1_540_234_480);
  });

  it("prices the bounds at the block's prices, with headroom for a tick", () => {
    const [b] = withPrices([boundsFor(step("begin", 459_145_440n), PRICES)], PRICES);
    expect(BigInt(b!.bounds.l2_gas.max_price_per_unit)).toBe(PRICES.l2GasPriceFri * 2n);
    expect(BigInt(b!.bounds.l2_gas.max_amount)).toBe(b!.l2GasBound);
    expect(BigInt(b!.bounds.l1_gas.max_amount)).toBe(100_000n);
  });

  it("declares simulation bounds the node will accept", () => {
    const sim = simulationBounds(PRICES);
    expect(BigInt(sim.l2_gas.max_amount)).toBe(INVOKE_L2_GAS_CAP);
    expect(BigInt(sim.l2_gas.max_price_per_unit)).toBe(PRICES.l2GasPriceFri * 2n);
  });
});

describe("pricing the sequence", () => {
  const steps = [
    step("begin", 459_145_440n, 384n),
    step("merkle", 390_766_400n),
    step("answers", 861_288_640n, 320n),
  ];
  const est: SequenceEstimate = {
    steps,
    bounds: steps.map((s) => boundsFor(s, PRICES)),
    totalL2Gas: steps.reduce((a, s) => a + s.estimate.l2GasConsumed, 0n),
    totalL1DataGas: 0n,
    totalFeeFri: 0n,
    prices: PRICES,
    sender: "0x1",
    simulationFlags: ["SKIP_VALIDATE"],
    echoes: [],
    at: "2026-09-12T00:00:00Z",
  };

  it("bills L2 gas, L1 gas and L1 data gas at the block's prices", () => {
    const fee = feeAt(steps[0]!.estimate, PRICES);
    expect(fee).toBe(459_145_440n * PRICES.l2GasPriceFri + 384n * PRICES.l1DataGasPriceFri);
  });

  it("converts to fiat with the quote's own timestamp", () => {
    const priced = priceEstimate(est, { ...S5_SNAPSHOT, source: "test" });
    expect(priced.quote!.at).toBe(S5_SNAPSHOT.at);
    expect(priced.totalUsd).toBeCloseTo(priced.totalStrk * S5_SNAPSHOT.usd, 9);
    expect(priced.steps).toHaveLength(3);
  });

  it("shows what the same gas would cost at the 3 gFri floor", () => {
    const priced = priceEstimate(est, null);
    expect(priced.totalUsd).toBeNull();
    const ratio = priced.totalStrk / priced.floorStrk;
    expect(ratio).toBeGreaterThan(10); // 30.475 gFri is 10.16x the floor (S5 §5)
    expect(ratio).toBeLessThan(11);
    expect(friToStrk(L2_GAS_PRICE_FLOOR_FRI)).toBeCloseTo(3e-9, 12);
  });
});

describe("R7-A2: the 24 h median", () => {
  const t0 = 1_789_000_000;
  const now = () => t0 * 1000;
  const tracker = (samples: [number, bigint][] = []) =>
    new GasPriceMedian(
      new MemorySampleStore(samples.map(([t, p]) => ({ t, priceFri: p.toString() }))),
      { now },
    );

  it("says 'unknown' rather than 'normal' when it has no history", () => {
    const v = tracker().verdict(60_000_000_000n);
    expect(v.kind).toBe("unknown");
    expect(v).toMatchObject({ samples: 0 });
  });

  it("stays 'unknown' below the minimum sample count", () => {
    const few: [number, bigint][] = Array.from({ length: MIN_SAMPLES - 1 }, (_, i) => [
      t0 - 3600 * (i + 1),
      30_000_000_000n,
    ]);
    expect(tracker(few).verdict(30_000_000_000n).kind).toBe("unknown");
  });

  const day: [number, bigint][] = Array.from({ length: 24 }, (_, i) => [
    t0 - 3600 * (i + 1),
    30_000_000_000n,
  ]);

  it("warns above twice the median", () => {
    const v = tracker(day).verdict(30_000_000_000n * BigInt(SPIKE_FACTOR) + 1n);
    expect(v.kind).toBe("high");
    expect(v).toMatchObject({ medianFri: 30_000_000_000n });
  });

  it("does not warn at exactly twice the median", () => {
    expect(tracker(day).verdict(60_000_000_000n).kind).toBe("normal");
  });

  it("ignores samples older than the window", () => {
    const stale: [number, bigint][] = day.map(([t, p]) => [t - 48 * 3600, p]);
    expect(tracker(stale).verdict(30_000_000_000n).kind).toBe("unknown");
  });

  it("takes the mean of the two middle samples on an even count", () => {
    const even: [number, bigint][] = Array.from({ length: 10 }, (_, i) => [
      t0 - 3600 * (i + 1),
      BigInt(10 + i) * 1_000_000_000n,
    ]);
    expect(tracker(even).median()).toBe(14_500_000_000n);
  });

  it("collapses samples taken within the same minute, so polling cannot drown the window", () => {
    const t = tracker(day);
    for (let i = 0; i < 50; i++) t.record(300_000_000_000n, t0 - 10);
    expect(t.samples().filter((s) => s.priceFri === "300000000000")).toHaveLength(1);
    expect(t.verdict(300_000_000_000n).kind).toBe("high");
  });
});

describe("the fiat source", () => {
  it("caches a quote and falls back to the S5 snapshot when the source is down", async () => {
    let calls = 0;
    const flaky = {
      name: "flaky",
      quote: async () => {
        calls++;
        throw new Error("offline");
      },
    };
    const cached = new CachedPriceSource(flaky);
    const first = await cached.quote();
    expect(first.usd).toBe(S5_SNAPSHOT.usd);
    expect(first.source).toContain("unreachable");
    await cached.quote();
    expect(calls).toBe(1); // the fallback is cached too, not retried on every render
  });

  it("serves a static quote unchanged", async () => {
    const q = await new StaticPriceSource(S5_SNAPSHOT, "snapshot").quote();
    expect(q).toEqual({ ...S5_SNAPSHOT, source: "snapshot" });
  });
});

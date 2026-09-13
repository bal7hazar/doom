// SPDX-License-Identifier: Apache-2.0
/**
 * Estimation and resource bounds for the whole submission (R7-A1).
 *
 * The rules, measured in S5 and unchanged here:
 *
 * * estimate the **ordered sequence**, never a transaction in isolation — each one reads what
 *   the previous one left;
 * * estimate **from the account that will actually sign** — S5 §4.1 measured +19 % L2 gas on a
 *   calldata-dense transaction between two account classes, which is more than the margin;
 * * `SKIP_VALIDATE`, empty signature: nothing is signed, nothing can be broadcast;
 * * bounds = simulated × **1.15** on L2 gas and × **1.30** on L1 data gas — never a global ×1.5,
 *   which pushed the old P4.0 heaviest phases *over* the 1.21e9 invoke cap; P4.1 changes the
 *   consumption, not these margins or the need to simulate the actual deployment;
 * * a fixed L1 gas bound: consumption is zero in blob mode, the bound only guards a DA change.
 *
 * **The one thing S5 could not foresee.** In the staged design S5 measured, the checkpoint lived
 * in storage, so the three transactions had calldata that did not depend on each other and a
 * single `starknet_simulateTransactions` over the array was enough. In the P4.0 router the
 * checkpoint is **echoed as calldata** (that is what made it 61× cheaper), so transaction i+1
 * cannot be built until transaction i has run. `simulateSequence` therefore simulates growing
 * prefixes, reading each phase's returned state out of the simulation's own trace, and the last
 * simulation is the complete ordered array R7-A1 asks for — the earlier ones exist only to
 * discover the echoes. It costs ~3× the sequence in node CPU and nothing on chain.
 */

import { phaseCalldata } from "./calldata.js";
import { friToStrk, type FiatQuote } from "./prices.js";
import {
  feeEstimateOf,
  invokeV3,
  type Call,
  type FeeEstimate,
  type GasPrices,
  type ResourceBounds,
  type RpcClient,
} from "./rpc.js";
import type { SubmissionSequence } from "./sequence.js";

/** Empirical per-invoke L2 gas cap (sequencer rejection, S5 / `onchain-verifier.md`). */
export const INVOKE_L2_GAS_CAP = 1_210_000_000n;
/** R7-A5: nothing provisioned above this share of the cap. */
export const CAP_SAFETY = 0.9;
export const MARGIN_L2 = 1.15;
export const MARGIN_L1_DATA = 1.3;
/** Blob mode consumes no L1 gas; the bound only guards a DA-mode change. */
export const L1_GAS_BOUND = 100_000n;
/** Protocol floor on the L2 gas price since v0.14.0. */
export const L2_GAS_PRICE_FLOOR_FRI = 3_000_000_000n;

/** Amounts declared on the *simulated* transactions (not the ones that get sent). */
const SIM_AMOUNTS = { l1_gas: 100_000n, l1_data_gas: 50_000n, l2_gas: INVOKE_L2_GAS_CAP };
/** Headroom over the block's prices so a tick mid-simulation does not fail the bounds check. */
const SIM_PRICE_FACTOR = 2n;

const hex = (v: bigint) => "0x" + v.toString(16);

export function simulationBounds(p: GasPrices): ResourceBounds {
  const bound = (amount: bigint, price: bigint) => ({
    max_amount: hex(amount),
    max_price_per_unit: hex(price * SIM_PRICE_FACTOR),
  });
  return {
    l1_gas: bound(SIM_AMOUNTS.l1_gas, p.l1GasPriceFri),
    l1_data_gas: bound(SIM_AMOUNTS.l1_data_gas, p.l1DataGasPriceFri),
    l2_gas: bound(SIM_AMOUNTS.l2_gas, p.l2GasPriceFri),
  };
}

export interface StepEstimate {
  index: number;
  label: string;
  phase: "verifier" | "consumer";
  calldataFelts: number;
  estimate: FeeEstimate;
  /** Share of the per-invoke cap the *consumption* occupies. */
  pctOfCap: number;
}

export interface StepBounds {
  index: number;
  label: string;
  bounds: ResourceBounds;
  l2GasBound: bigint;
  l1DataGasBound: bigint;
  pctOfCap: number;
  overCap: boolean;
  over90PctRule: boolean;
  /** What a global ×1.5 would have asked for, and whether the sequencer would refuse it. */
  naiveX15L2Gas: bigint;
  naiveX15OverCap: boolean;
}

export interface SequenceEstimate {
  steps: StepEstimate[];
  bounds: StepBounds[];
  totalL2Gas: bigint;
  totalL1DataGas: bigint;
  totalFeeFri: bigint;
  prices: GasPrices;
  sender: string;
  simulationFlags: string[];
  /** Echoes discovered while simulating — reusable to skip the prefix walk next time. */
  echoes: (string[] | null)[];
  at: string;
}

/** Retdata of one simulated invoke: the checkpoint state the phase returned. */
function echoFromSimulation(entry: any): string[] | null {
  const result: string[] | undefined = entry?.transaction_trace?.execute_invocation?.calls?.[0]?.result;
  if (!result || result.length === 0) return null;
  const n = Number(BigInt(result[0]!));
  return result.slice(1, 1 + n);
}

export interface SimulateOptions {
  sender: string;
  /** Skip the consumer transaction (verify the fact only). */
  verifierOnly?: boolean;
  /** Echoes already known — from a previous estimate, a local store, or a resumed run. */
  echoes?: (string[] | null)[];
  /** Start at this phase: everything before it already ran on chain. */
  fromPhase?: number;
  onPrefix?: (done: number, total: number) => void;
}

/**
 * Simulates the ordered sequence and returns the per-transaction consumption and the bounds.
 *
 * Falls back to `SKIP_VALIDATE + SKIP_FEE_CHARGE` when the node refuses the declared bounds
 * (typically a sender that cannot cover them); the two modes give identical numbers (S5 §3).
 */
export async function simulateSequence(
  rpc: RpcClient,
  seq: SubmissionSequence,
  options: SimulateOptions,
): Promise<SequenceEstimate> {
  const prices = await rpc.gasPrices();
  const simBounds = simulationBounds(prices);
  const nonce0 = await rpc.nonce(options.sender);
  const from = options.fromPhase ?? 0;
  const echoes: (string[] | null)[] = [...(options.echoes ?? [])];
  while (echoes.length < seq.phases.length) echoes.push(null);

  const callAt = (i: number): Call =>
    i < seq.phases.length
      ? {
          contractAddress: seq.router,
          entrypoint: seq.phases[i]!.entrypoint,
          calldata: phaseCalldata(seq.phases[i]!, echoes[i] ?? null),
        }
      : seq.consumer.call;

  const lastIndex = options.verifierOnly ? seq.phases.length - 1 : seq.phases.length;
  let flags = ["SKIP_VALIDATE"];
  let sim: any[] = [];

  const simulatePrefix = async (upto: number): Promise<any[]> => {
    const txs: unknown[] = [];
    for (let i = from; i <= upto; i++) {
      txs.push(invokeV3(options.sender, [callAt(i)], nonce0 + BigInt(i - from), simBounds));
    }
    try {
      return await rpc.simulate(txs, flags);
    } catch (e) {
      if (flags.length === 1) {
        flags = ["SKIP_VALIDATE", "SKIP_FEE_CHARGE"];
        return rpc.simulate(txs, flags);
      }
      throw e;
    }
  };

  // Discover the echoes: the state phase i returns is the calldata of phase i+1.
  for (let i = from; i < seq.phases.length - 1; i++) {
    if (echoes[i + 1]) continue;
    options.onPrefix?.(i - from + 1, lastIndex - from + 1);
    sim = await simulatePrefix(i);
    echoes[i + 1] = echoFromSimulation(sim[sim.length - 1]);
  }

  // The complete ordered array — this is the estimate R7-A1 asks for.
  options.onPrefix?.(lastIndex - from + 1, lastIndex - from + 1);
  sim = await simulatePrefix(lastIndex);

  const steps: StepEstimate[] = sim.map((entry, k) => {
    const i = from + k;
    const isVerifier = i < seq.phases.length;
    const estimate = feeEstimateOf(entry);
    return {
      index: i,
      label: isVerifier ? seq.phases[i]!.label : seq.consumer.label,
      phase: isVerifier ? ("verifier" as const) : ("consumer" as const),
      calldataFelts: callAt(i).calldata.length,
      estimate,
      pctOfCap: (100 * Number(estimate.l2GasConsumed)) / Number(INVOKE_L2_GAS_CAP),
    };
  });

  return {
    steps,
    bounds: steps.map((s) => boundsFor(s, prices)),
    totalL2Gas: steps.reduce((a, s) => a + s.estimate.l2GasConsumed, 0n),
    totalL1DataGas: steps.reduce((a, s) => a + s.estimate.l1DataGasConsumed, 0n),
    totalFeeFri: steps.reduce((a, s) => a + s.estimate.overallFee, 0n),
    prices,
    sender: options.sender,
    simulationFlags: flags,
    echoes,
    at: new Date().toISOString(),
  };
}

/** R7-A1 bounds for one simulated transaction. */
export function boundsFor(step: StepEstimate, prices?: GasPrices): StepBounds {
  const l2 = BigInt(Math.ceil(Number(step.estimate.l2GasConsumed) * MARGIN_L2));
  const data = BigInt(Math.ceil(Number(step.estimate.l1DataGasConsumed) * MARGIN_L1_DATA));
  const naive = BigInt(Math.ceil(Number(step.estimate.l2GasConsumed) * 1.5));
  const price = (p: bigint | undefined) => hex(p ?? 0n);
  return {
    index: step.index,
    label: step.label,
    l2GasBound: l2,
    l1DataGasBound: data,
    pctOfCap: (100 * Number(l2)) / Number(INVOKE_L2_GAS_CAP),
    overCap: l2 > INVOKE_L2_GAS_CAP,
    over90PctRule: Number(l2) > CAP_SAFETY * Number(INVOKE_L2_GAS_CAP),
    naiveX15L2Gas: naive,
    naiveX15OverCap: naive > INVOKE_L2_GAS_CAP,
    bounds: {
      l1_gas: {
        max_amount: hex(L1_GAS_BOUND),
        max_price_per_unit: price(prices?.l1GasPriceFri),
      },
      l1_data_gas: {
        max_amount: hex(data),
        max_price_per_unit: price(prices?.l1DataGasPriceFri),
      },
      l2_gas: { max_amount: hex(l2), max_price_per_unit: price(prices?.l2GasPriceFri) },
    },
  };
}

/**
 * Re-prices the bounds against the prices that will actually be charged.
 *
 * `max_price_per_unit` is a ceiling, not what is paid — but it has to be high enough at
 * *inclusion* time, not at estimation time. The multiplier is the tolerance to a price tick
 * between the cost screen and the last transaction of a five-transaction sequence; 2× is what
 * the drives use and what the simulation itself is given.
 */
export function withPrices(
  bounds: StepBounds[],
  prices: GasPrices,
  priceFactor = 2n,
): StepBounds[] {
  return bounds.map((b) => ({
    ...b,
    bounds: {
      l1_gas: {
        max_amount: b.bounds.l1_gas.max_amount,
        max_price_per_unit: hex(prices.l1GasPriceFri * priceFactor),
      },
      l1_data_gas: {
        max_amount: b.bounds.l1_data_gas.max_amount,
        max_price_per_unit: hex(prices.l1DataGasPriceFri * priceFactor),
      },
      l2_gas: {
        max_amount: b.bounds.l2_gas.max_amount,
        max_price_per_unit: hex(prices.l2GasPriceFri * priceFactor),
      },
    },
  }));
}

/** Fee of a step at a given price set — what the cost screen shows per transaction. */
export function feeAt(estimate: FeeEstimate, p: GasPrices): bigint {
  return (
    estimate.l2GasConsumed * p.l2GasPriceFri +
    estimate.l1GasConsumed * p.l1GasPriceFri +
    estimate.l1DataGasConsumed * p.l1DataGasPriceFri
  );
}

export interface PricedStep {
  label: string;
  phase: "verifier" | "consumer";
  l2Gas: bigint;
  l1DataGas: bigint;
  feeFri: bigint;
  strk: number;
  usd: number | null;
  eur: number | null;
  pctOfCap: number;
}

export interface PricedEstimate {
  steps: PricedStep[];
  totalFeeFri: bigint;
  totalStrk: number;
  totalUsd: number | null;
  totalEur: number | null;
  /** How many STRK the same gas would cost at the 3 gFri protocol floor — the "wait" reference. */
  floorStrk: number;
  quote: FiatQuote | null;
  prices: GasPrices;
  at: string;
}

/** Turns an estimate into what the cost screen displays (R7-A2: per transaction, timestamped). */
export function priceEstimate(
  est: SequenceEstimate,
  quote: FiatQuote | null,
  prices: GasPrices = est.prices,
): PricedEstimate {
  const steps: PricedStep[] = est.steps.map((s) => {
    const feeFri = feeAt(s.estimate, prices);
    const strk = friToStrk(feeFri);
    return {
      label: s.label,
      phase: s.phase,
      l2Gas: s.estimate.l2GasConsumed,
      l1DataGas: s.estimate.l1DataGasConsumed,
      feeFri,
      strk,
      usd: quote ? strk * quote.usd : null,
      eur: quote ? strk * quote.eur : null,
      pctOfCap: s.pctOfCap,
    };
  });
  const totalFeeFri = steps.reduce((a, s) => a + s.feeFri, 0n);
  const totalStrk = friToStrk(totalFeeFri);
  const floorFri = est.steps.reduce(
    (a, s) =>
      a +
      s.estimate.l2GasConsumed * L2_GAS_PRICE_FLOOR_FRI +
      s.estimate.l1DataGasConsumed * prices.l1DataGasPriceFri +
      s.estimate.l1GasConsumed * prices.l1GasPriceFri,
    0n,
  );
  return {
    steps,
    totalFeeFri,
    totalStrk,
    totalUsd: quote ? totalStrk * quote.usd : null,
    totalEur: quote ? totalStrk * quote.eur : null,
    floorStrk: friToStrk(floorFri),
    quote,
    prices,
    at: new Date().toISOString(),
  };
}

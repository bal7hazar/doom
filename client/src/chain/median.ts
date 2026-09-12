// SPDX-License-Identifier: Apache-2.0
/**
 * 24-hour median of the L2 gas price, and the "> 2× the median" warning of R7-A2.
 *
 * Since v0.14.3 the L2 base price is dynamic, so "is this expensive?" has no absolute answer —
 * only a relative one. The client samples the latest block's `l2_gas_price` whenever it talks to
 * the chain, persists the samples, and compares the price it is about to pay against the median
 * of the last 24 hours.
 *
 * **Known limitation.** This is a *local* history: a fresh client, a new browser profile or a
 * cleared storage has none, and the first session can therefore not tell a spike from a normal
 * day. `verdict()` says so explicitly (`unknown`) instead of returning a reassuring "normal" —
 * a warning that cannot fire must not look like a warning that did not fire. Options to close
 * it, none of them free: ship a seed history with the build (stale the day after), read a public
 * RPC's block history at startup (~2 880 blocks for 24 h at 30 s), or have the wrapper publish a
 * signed rolling median. The last one is the cheapest for the client and is the recommendation
 * in `docs/design/submission.md` §6.
 */

export interface GasSample {
  /** Unix seconds — the *block's* timestamp, not the client's clock. */
  t: number;
  /** L2 gas price in FRI. */
  priceFri: string;
}

export interface SampleStore {
  load(): GasSample[];
  save(samples: GasSample[]): void;
}

/** In-memory store; the UI backs it with `localStorage`, the CLI with a JSON file. */
export class MemorySampleStore implements SampleStore {
  constructor(private samples: GasSample[] = []) {}
  load(): GasSample[] {
    return this.samples;
  }
  save(samples: GasSample[]): void {
    this.samples = samples;
  }
}

export const WINDOW_SECONDS = 24 * 3600;
/** R7-A2: warn above this multiple of the 24 h median. */
export const SPIKE_FACTOR = 2;
/** Below this many samples the median is not a median. */
export const MIN_SAMPLES = 8;

export type PriceVerdict =
  | { kind: "unknown"; samples: number; reason: string }
  | { kind: "normal"; samples: number; medianFri: bigint; ratio: number }
  | { kind: "high"; samples: number; medianFri: bigint; ratio: number };

export class GasPriceMedian {
  constructor(
    private readonly store: SampleStore,
    private readonly options: { windowSeconds?: number; now?: () => number; maxSamples?: number } = {},
  ) {}

  private get windowSeconds(): number {
    return this.options.windowSeconds ?? WINDOW_SECONDS;
  }

  private nowSeconds(): number {
    return Math.floor((this.options.now?.() ?? Date.now()) / 1000);
  }

  /** Samples inside the window, oldest first. */
  samples(): GasSample[] {
    const cutoff = this.nowSeconds() - this.windowSeconds;
    return this.store
      .load()
      .filter((s) => s.t >= cutoff)
      .sort((a, b) => a.t - b.t);
  }

  /**
   * Records one observation. Samples closer together than a minute collapse onto the newest one:
   * a submission screen polls the chain several times a minute and must not be able to drown the
   * window in its own samples and make a spike look like the norm.
   */
  record(priceFri: bigint, blockTimestamp: number): void {
    const kept = this.samples().filter((s) => Math.abs(s.t - blockTimestamp) >= 60);
    kept.push({ t: blockTimestamp, priceFri: priceFri.toString() });
    kept.sort((a, b) => a.t - b.t);
    const max = this.options.maxSamples ?? 4096;
    this.store.save(kept.slice(Math.max(0, kept.length - max)));
  }

  /** Median over the window, or `null` when there is not enough history. */
  median(): bigint | null {
    const values = this.samples()
      .map((s) => BigInt(s.priceFri))
      .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    if (values.length < MIN_SAMPLES) return null;
    const mid = values.length >> 1;
    if (values.length % 2 === 1) return values[mid]!;
    return (values[mid - 1]! + values[mid]!) / 2n;
  }

  /** Is the price we are about to pay a spike? `unknown` when the history is too short. */
  verdict(priceFri: bigint): PriceVerdict {
    const samples = this.samples().length;
    const med = this.median();
    if (med === null || med === 0n) {
      return {
        kind: "unknown",
        samples,
        reason:
          samples === 0
            ? "no local price history yet — this client has never sampled the chain"
            : `only ${samples} samples in the last 24 h (need ${MIN_SAMPLES})`,
      };
    }
    const ratio = Number(priceFri) / Number(med);
    return ratio > SPIKE_FACTOR
      ? { kind: "high", samples, medianFri: med, ratio }
      : { kind: "normal", samples, medianFri: med, ratio };
  }
}

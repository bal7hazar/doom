// SPDX-License-Identifier: Apache-2.0
/**
 * STRK → fiat, behind a pluggable source (R7-A2).
 *
 * The cost screen must show a fiat equivalent *with the time it was read*: since v0.14.3 the L2
 * base price is indexed on the STRK price, so the bill in dollars is steadier than the bill in
 * STRK (S5 §5) and a stale quote is misleading in a way a stale gas price is not. Every quote
 * therefore carries `at`, and the UI prints it.
 *
 * CoinGecko is the default because it needs no key and is what S5 used; a Pragma on-chain oracle
 * reader is the obvious second implementation and is why this is an interface rather than a
 * function.
 */

export interface FiatQuote {
  usd: number;
  eur: number;
  /** ISO 8601, when the quote was *read* — not when it was cached. */
  at: string;
  source: string;
}

export interface PriceSource {
  readonly name: string;
  quote(): Promise<FiatQuote>;
}

export const COINGECKO_URL =
  "https://api.coingecko.com/api/v3/simple/price?ids=starknet&vs_currencies=usd,eur";

export class CoinGeckoSource implements PriceSource {
  readonly name = "coingecko";

  constructor(
    private readonly url: string = COINGECKO_URL,
    private readonly options: { timeoutMs?: number; fetch?: typeof fetch } = {},
  ) {}

  async quote(): Promise<FiatQuote> {
    const doFetch = this.options.fetch ?? fetch;
    const res = await doFetch(this.url, {
      signal: AbortSignal.timeout(this.options.timeoutMs ?? 20_000),
    });
    const body = (await res.json()) as { starknet?: { usd?: number; eur?: number } };
    if (!body?.starknet?.usd) throw new Error(`unexpected price payload: ${JSON.stringify(body).slice(0, 200)}`);
    return {
      usd: body.starknet.usd,
      eur: body.starknet.eur ?? 0,
      at: new Date().toISOString(),
      source: this.name,
    };
  }
}

/** A fixed quote — tests, offline mode, and the S5 snapshot fallback. */
export class StaticPriceSource implements PriceSource {
  readonly name: string;
  constructor(
    private readonly fixed: Omit<FiatQuote, "source">,
    name = "static",
  ) {
    this.name = name;
  }
  quote(): Promise<FiatQuote> {
    return Promise.resolve({ ...this.fixed, source: this.name });
  }
}

/**
 * The S5 §5 snapshot (2026-09-12 13:20 UTC), used when the network is unreachable. Displayed as
 * such: a snapshot months old is a rough order of magnitude, not a price.
 */
export const S5_SNAPSHOT: Omit<FiatQuote, "source"> = {
  usd: 0.02876053,
  eur: 0.02478928,
  at: "2026-09-12T13:20:12Z",
};

/** Caches a quote for `ttlMs` and falls back to the last good one, then to the S5 snapshot. */
export class CachedPriceSource implements PriceSource {
  private cached: FiatQuote | null = null;
  /**
   * When the inner source was last *asked*, which is not when the quote was read: a failed
   * attempt falls back to a quote stamped months ago, and keying the TTL on that stamp would
   * re-hit a dead endpoint on every render of the cost screen.
   */
  private lastAttempt = -Infinity;
  private readonly ttlMs: number;
  private readonly now: () => number;
  readonly name: string;

  constructor(
    private readonly inner: PriceSource,
    options: { ttlMs?: number; now?: () => number } = {},
  ) {
    this.ttlMs = options.ttlMs ?? 5 * 60_000;
    this.now = options.now ?? (() => Date.now());
    this.name = `${inner.name} (cached ${Math.round(this.ttlMs / 1000)} s)`;
  }

  async quote(): Promise<FiatQuote> {
    if (this.cached && this.now() - this.lastAttempt < this.ttlMs) return this.cached;
    this.lastAttempt = this.now();
    try {
      this.cached = await this.inner.quote();
    } catch {
      this.cached ??= { ...S5_SNAPSHOT, source: `${this.inner.name} unreachable — S5 snapshot` };
    }
    return this.cached;
  }
}

export const FRI_PER_STRK = 1_000_000_000_000_000_000n;

/** FRI → STRK as a float. Fees are ~1e20 FRI, so the double keeps ~5 significant digits. */
export const friToStrk = (fri: bigint): number => Number(fri) / Number(FRI_PER_STRK);

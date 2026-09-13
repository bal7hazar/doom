// SPDX-License-Identifier: Apache-2.0
/** Small felt helpers shared by the decoder and the API. */

/** Normalises a `0x…` felt to lower-case with no leading zeros beyond a single `0x0`. */
export function normFelt(v: string | number | bigint): string {
  const n = typeof v === "bigint" ? v : BigInt(v);
  return "0x" + n.toString(16);
}

/** `u32`/`u8`/small `u64` felt -> a JS number. Every field this is used on is bounded well
 * under 2^53 in practice (tics, kills, score, block numbers, …). */
export function feltToNumber(v: string): number {
  return Number(BigInt(v));
}

/** A felt252 short string (Cairo's `'literal'`) decoded back to text, best-effort. Returns the
 * hex form unchanged when the felt is not printable ASCII (e.g. a hash used as a `reason`-like
 * field by mistake). */
export function feltToShortString(v: string): string {
  let n = BigInt(v);
  const bytes: number[] = [];
  while (n > 0n) {
    bytes.unshift(Number(n & 0xffn));
    n >>= 8n;
  }
  if (bytes.length === 0 || !bytes.every((b) => b >= 0x20 && b < 0x7f)) return v;
  return String.fromCharCode(...bytes);
}

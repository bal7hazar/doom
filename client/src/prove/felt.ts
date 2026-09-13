/** Felt helpers shared by the proving pipeline and the persistence layer. */
import type { Felt } from "./types.js";

/** `0x…` lower-case, no leading zeros (`0x0` for zero). The wrapper's convention. */
export function toFelt(value: bigint | number | string): Felt {
  return `0x${feltValue(value).toString(16)}`;
}

/** Numeric value of a felt written as `0x…` hex or as a decimal string. */
export function feltValue(value: bigint | number | string): bigint {
  if (typeof value === "bigint") return value;
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) throw new RangeError(`not a safe integer: ${value}`);
    return BigInt(value);
  }
  const text = value.trim();
  if (text === "") throw new SyntaxError("empty felt");
  return text.startsWith("0x") || text.startsWith("0X") ? BigInt(text) : BigInt(text);
}

/** Canonical form for comparison: two spellings of the same felt must be `===`. */
export function normalizeFelt(value: Felt): Felt {
  return toFelt(value);
}

/** `a` and `b` denote the same field element, whatever their spelling. */
export function feltEquals(a: Felt, b: Felt): boolean {
  try {
    return feltValue(a) === feltValue(b);
  } catch {
    return false;
  }
}

/** A felt that is expected to be a small non-negative integer (tic counts, stats). */
export function feltToNumber(value: Felt): number {
  const n = feltValue(value);
  if (n < 0n || n > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new RangeError(`felt out of safe-integer range: ${value}`);
  }
  return Number(n);
}

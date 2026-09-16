/** Canonical Cairo wire felts: 32 little-endian bytes, never JS floats. */
export const PRIME = (1n << 251n) + 17n * (1n << 192n) + 1n;

export function encodeFelts(values: readonly (number | bigint | string)[]): Uint8Array {
  const bytes = new Uint8Array(values.length * 32);
  const view = new DataView(bytes.buffer);
  values.forEach((value, i) => {
    let n = BigInt(value);
    if (n < 0n || n >= PRIME) throw new RangeError("noncanonical felt");
    for (let lane = 0; lane < 4; lane++, n >>= 64n) view.setBigUint64(i * 32 + lane * 8, n & ((1n << 64n) - 1n), true);
  });
  return bytes;
}

export function decodeFelts(bytes: Uint8Array): bigint[] {
  if (bytes.byteLength % 32) throw new RangeError("truncated felt buffer");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const values: bigint[] = [];
  for (let i = 0; i < bytes.length; i += 32) {
    let n = 0n;
    for (let lane = 3; lane >= 0; lane--) n = (n << 64n) + view.getBigUint64(i + lane * 8, true);
    if (n >= PRIME) throw new RangeError("noncanonical felt");
    values.push(n);
  }
  return values;
}

export function u32(n: bigint | undefined): number {
  if (n === undefined || n < 0n || n > 0xffffffffn) throw new RangeError("expected u32");
  return Number(n);
}

export function word32(n: number): number {
  if (!Number.isInteger(n) || n < 0 || n > 0xffffffff) throw new RangeError("expected input word u32");
  return n;
}

export function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

export function stateTic(bytes: Uint8Array): number {
  const state = decodeFelts(bytes);
  if (state[0] !== 0x48502e5354415445n || state[1] !== 2n || state.length < 6 || state[2] !== BigInt(state.length - 3)) throw new RangeError("expected state schema 2");
  return u32(state[4]);
}

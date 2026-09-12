// SPDX-License-Identifier: Apache-2.0
/**
 * `getSelectorFromName` without a dependency.
 *
 * `client/src/chain/` is deliberately dependency-free: the browser bundle should not carry
 * starknet.js just to build calldata (signing is the wallet's job — the Cartridge Controller
 * brings its own account object, and `infra/submit` brings starknet.js for the devnet signer).
 * The one primitive that is not arithmetic is the entrypoint selector, which is
 * `keccak256(name)` truncated to 250 bits, so keccak-f[1600] lives here.
 *
 * Checked against known mainnet selectors in `infra/submit/test/selector.test.ts`, including a
 * cross-check against starknet.js's own `hash.getSelectorFromName`.
 */

const MASK64 = (1n << 64n) - 1n;
/** Selectors are the low 250 bits of the digest (Starknet's `starknet_keccak`). */
const MASK250 = (1n << 250n) - 1n;
const RATE = 136; // keccak256: 1600 - 2*256 bits

const RC: bigint[] = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];
const PI = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1];
const ROT = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44];

const rotl = (x: bigint, n: number): bigint =>
  ((x << BigInt(n)) | (x >> BigInt(64 - n))) & MASK64;

function keccakF(a: bigint[]): void {
  for (let round = 0; round < 24; round++) {
    // theta
    const c = [0n, 0n, 0n, 0n, 0n];
    for (let x = 0; x < 5; x++) c[x] = a[x]! ^ a[x + 5]! ^ a[x + 10]! ^ a[x + 15]! ^ a[x + 20]!;
    for (let x = 0; x < 5; x++) {
      const d = c[(x + 4) % 5]! ^ rotl(c[(x + 1) % 5]!, 1);
      for (let y = 0; y < 25; y += 5) a[x + y] = a[x + y]! ^ d;
    }
    // rho + pi
    let t = a[1]!;
    for (let i = 0; i < 24; i++) {
      const j = PI[i]!;
      const tmp = a[j]!;
      a[j] = rotl(t, ROT[i]!);
      t = tmp;
    }
    // chi
    for (let y = 0; y < 25; y += 5) {
      const row = [a[y]!, a[y + 1]!, a[y + 2]!, a[y + 3]!, a[y + 4]!];
      for (let x = 0; x < 5; x++) {
        a[y + x] = row[x]! ^ (~row[(x + 1) % 5]! & MASK64 & row[(x + 2) % 5]!);
      }
    }
    // iota
    a[0] = a[0]! ^ RC[round]!;
  }
}

/** Ethereum-flavoured keccak-256 (pad10*1 with the 0x01 domain byte), digest as a bigint. */
export function keccak256(bytes: Uint8Array): bigint {
  const padded = new Uint8Array(Math.ceil((bytes.length + 1) / RATE) * RATE);
  padded.set(bytes);
  padded[bytes.length] = 0x01;
  padded[padded.length - 1] = (padded[padded.length - 1] ?? 0) | 0x80;

  const state = new Array<bigint>(25).fill(0n);
  for (let off = 0; off < padded.length; off += RATE) {
    for (let i = 0; i < RATE / 8; i++) {
      let lane = 0n;
      for (let b = 7; b >= 0; b--) lane = (lane << 8n) | BigInt(padded[off + i * 8 + b]!);
      state[i] = state[i]! ^ lane;
    }
    keccakF(state);
  }
  // Squeeze 32 bytes, big-endian digest from little-endian lanes.
  let digest = 0n;
  for (let i = 0; i < 4; i++) {
    const lane = state[i]!;
    for (let b = 0; b < 8; b++) digest = (digest << 8n) | ((lane >> BigInt(8 * b)) & 0xffn);
  }
  return digest;
}

const cache = new Map<string, string>();

/** The entrypoint selector of `name`: `keccak256(name) & (2^250 - 1)`, as a 0x felt. */
export function getSelectorFromName(name: string): string {
  const hit = cache.get(name);
  if (hit) return hit;
  const selector = "0x" + (keccak256(new TextEncoder().encode(name)) & MASK250).toString(16);
  cache.set(name, selector);
  return selector;
}

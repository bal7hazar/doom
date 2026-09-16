// SPDX-License-Identifier: Apache-2.0
/**
 * Starknet's Poseidon (the *Hades* permutation over the Stark field) without a dependency.
 *
 * `client/src/chain/` builds calldata and talks JSON-RPC with nothing but `fetch` (see
 * `selector.ts` for the same argument about keccak). The open-prover flow of D35 adds one
 * hash the browser has to compute *before* signing: `commit_log(packed)` and the derived
 * `commitment_id`, so the run record can carry the id the contract will assign, and the
 * `RunCommitted` event can be checked against what was expected. Both are Poseidon, so the
 * permutation lives here.
 *
 * Parameters are Starknet's (`starkware-libs/starkware-crypto-utils`, `poseidon_py`,
 * `@scure/starknet`'s `poseidonSmall`): state width 3, rate 2, capacity 1, S-box `x^3`, 8 full
 * rounds around 83 partial rounds whose S-box acts on the **last** lane, the fixed MDS matrix
 * `[[3,1,1],[1,-1,1],[1,1,-2]]`, and round constants `sha256("Hades" ‖ i) mod p` for
 * `i = 0 … 272`. The hash conventions on top (`poseidon_hash(x, y) = perm(x, y, 2)[0]`,
 * `poseidon_hash_span` = rate-2 absorption with the `1, 0…` padding) are Cairo's
 * `core::poseidon`. Pinned against `poseidon_py` and the `doom_runs` test vectors in
 * `client/test/commit.test.ts`.
 */

/** The Stark field prime, `2^251 + 17·2^192 + 1`. */
export const STARK_PRIME = 0x800000000000011000000000000000000000000000000000000000000000001n;

const FULL_ROUNDS = 8;
const PARTIAL_ROUNDS = 83;
const WIDTH = 3;

const mod = (v: bigint): bigint => {
  const r = v % STARK_PRIME;
  return r < 0n ? r + STARK_PRIME : r;
};

// -- sha256, only to derive the round constants -----------------------------------------------

const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

const rotr = (x: number, n: number): number => (x >>> n) | (x << (32 - n));

/** Plain SHA-256 over a short byte string, as 32 bytes. */
export function sha256(message: Uint8Array): Uint8Array {
  const bitLen = message.length * 8;
  const padded = new Uint8Array(Math.ceil((message.length + 9) / 64) * 64);
  padded.set(message);
  padded[message.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 8, Math.floor(bitLen / 2 ** 32));
  view.setUint32(padded.length - 4, bitLen >>> 0);

  const h = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  const w = new Uint32Array(64);
  for (let off = 0; off < padded.length; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(off + i * 4);
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15]!, 7) ^ rotr(w[i - 15]!, 18) ^ (w[i - 15]! >>> 3);
      const s1 = rotr(w[i - 2]!, 17) ^ rotr(w[i - 2]!, 19) ^ (w[i - 2]! >>> 10);
      w[i] = (w[i - 16]! + s0 + w[i - 7]! + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, hh] = h as unknown as [number, number, number, number, number, number, number, number];
    for (let i = 0; i < 64; i++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (hh + S1 + ch + K[i]! + w[i]!) >>> 0;
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) >>> 0;
      hh = g; g = f; f = e; e = (d + t1) >>> 0;
      d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    h[0] = (h[0]! + a) >>> 0; h[1] = (h[1]! + b) >>> 0; h[2] = (h[2]! + c) >>> 0; h[3] = (h[3]! + d) >>> 0;
    h[4] = (h[4]! + e) >>> 0; h[5] = (h[5]! + f) >>> 0; h[6] = (h[6]! + g) >>> 0; h[7] = (h[7]! + hh) >>> 0;
  }
  const out = new Uint8Array(32);
  const outView = new DataView(out.buffer);
  for (let i = 0; i < 8; i++) outView.setUint32(i * 4, h[i]!);
  return out;
}

const bytesToBigInt = (bytes: Uint8Array): bigint => {
  let v = 0n;
  for (const b of bytes) v = (v << 8n) | BigInt(b);
  return v;
};

/** `sha256("Hades" ‖ decimal index) mod p` — Starknet's round-constant derivation. */
function roundConstant(index: number): bigint {
  return mod(bytesToBigInt(sha256(new TextEncoder().encode(`Hades${index}`))));
}

let constants: bigint[] | undefined;
/** The `(8 + 83) × 3` round constants, derived once on first use. */
function roundConstants(): bigint[] {
  if (!constants) {
    constants = [];
    for (let i = 0; i < (FULL_ROUNDS + PARTIAL_ROUNDS) * WIDTH; i++) constants.push(roundConstant(i));
  }
  return constants;
}

// -- the permutation -----------------------------------------------------------------------

const cube = (x: bigint): bigint => mod(mod(x * x) * x);

/** MDS `[[3,1,1],[1,-1,1],[1,1,-2]]`. */
function mix(s0: bigint, s1: bigint, s2: bigint): [bigint, bigint, bigint] {
  const sum = s0 + s1 + s2;
  return [mod(sum + 2n * s0), mod(sum - 2n * s1), mod(sum - 3n * s2)];
}

/** `core::poseidon::hades_permutation`. */
export function hadesPermutation(a: bigint, b: bigint, c: bigint): [bigint, bigint, bigint] {
  const rc = roundConstants();
  let s0 = mod(a);
  let s1 = mod(b);
  let s2 = mod(c);
  let round = 0;
  const half = FULL_ROUNDS / 2;
  const full = (): void => {
    const base = round * WIDTH;
    [s0, s1, s2] = mix(cube(s0 + rc[base]!), cube(s1 + rc[base + 1]!), cube(s2 + rc[base + 2]!));
    round++;
  };
  const partial = (): void => {
    const base = round * WIDTH;
    [s0, s1, s2] = mix(s0 + rc[base]!, s1 + rc[base + 1]!, cube(s2 + rc[base + 2]!));
    round++;
  };
  for (let i = 0; i < half; i++) full();
  for (let i = 0; i < PARTIAL_ROUNDS; i++) partial();
  for (let i = 0; i < half; i++) full();
  return [s0, s1, s2];
}

/** `core::poseidon::poseidon_hash` / starknet.js `poseidonHash`: `perm(x, y, 2)[0]`. */
export function poseidonHash(x: bigint, y: bigint): bigint {
  return hadesPermutation(x, y, 2n)[0];
}

/**
 * `core::poseidon::poseidon_hash_span` / `poseidon_hash_many`: rate-2 sponge, the input padded
 * with `1` then zeros to a whole number of pairs, the capacity lane left untouched.
 */
export function poseidonHashMany(values: readonly bigint[]): bigint {
  const padded = [...values, 1n];
  if (padded.length % 2 === 1) padded.push(0n);
  let s0 = 0n;
  let s1 = 0n;
  let s2 = 0n;
  for (let i = 0; i < padded.length; i += 2) {
    [s0, s1, s2] = hadesPermutation(s0 + padded[i]!, s1 + padded[i + 1]!, s2);
  }
  return s0;
}

/** Cairo's short-string literal (`'HP.COMMIT'`): the ASCII bytes read big-endian. */
export function shortString(text: string): bigint {
  if (text.length > 31) throw new RangeError(`short string too long: ${text}`);
  return bytesToBigInt(new TextEncoder().encode(text));
}

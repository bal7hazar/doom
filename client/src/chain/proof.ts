// SPDX-License-Identifier: Apache-2.0
/**
 * Cairo-serde `CircuitProof` stream → the sections the resumable verifier consumes.
 *
 * Port of `cairo/doom_contracts/tools/emit_calldata.py` (parsing + packing halves) so that the
 * browser can split a root proof without a Python round trip. The two files must stay in step:
 * `infra/submit/test/calldata.test.ts` diffs this module's output against the Python emitter's
 * on the committed fixtures, and against the calldata sizes of the devnet receipts
 * (`cairo/doom_contracts/results/e2e_10felt_receipts.json`).
 *
 * Everything is `bigint`: proof felts are u32 except the two proof-of-work nonces (u64), but a
 * packed slot is a full felt252 and JavaScript numbers stop being exact at 2^53.
 */

/** A limb of `0xFFFFFFFF` escapes a (low, high) u64 pair in the escaped encoding. */
const ESCAPE = 0xffffffffn;
const LIMBS_PER_SLOT = 7;
const QM31_FELTS = 4;
const HASH_FELTS = 8;
const N_TREES = 4;

/** Usable calldata felts of one invoke (5 000 minus the `__execute__` envelope, S5 lane 1). */
export const DEFAULT_MAX_CALLDATA = 4_990;
/** Serialized checkpoint sizes at 70 queries (`onchain-verifier.md` §4). */
export const MERKLE_STATE_FELTS = 228;
export const FRI_STATE_FELTS = 576;

export interface ProofSections {
  /** Everything `begin` mixes into the Fiat–Shamir channel, in transcript order. */
  head: bigint[];
  /** The sampled values sub-stream, re-supplied to `answers` and bound by `d_sampled`. */
  sampled: bigint[];
  /** Queried values per Merkle tree, each prefixed by its element count. */
  queriedValues: bigint[][];
  /** Merkle hash witnesses per tree, each prefixed by its element count. */
  decommitments: bigint[][];
  /** FRI layer proofs, first (circle) layer then the inner ones. */
  layers: bigint[][];
  pcsConfig: bigint[];
}

class Stream {
  private pos = 0;
  constructor(private readonly v: bigint[]) {}

  take(n: number): bigint[] {
    const r = this.v.slice(this.pos, this.pos + n);
    if (r.length !== n) throw new Error("truncated proof stream");
    this.pos += n;
    return r;
  }

  u(): bigint {
    return this.take(1)[0]!;
  }

  /** A `Span<T>`: the element count followed by `n * elemFelts` felts, count included. */
  array(elemFelts: number): bigint[] {
    const n = this.u();
    return [n, ...this.take(Number(n) * elemFelts)];
  }

  /** `FriLayerProof`: fri_witness (Span<QM31>) ‖ decommitment (Span<Hash>) ‖ commitment. */
  layer(): bigint[] {
    return [...this.array(QM31_FELTS), ...this.array(HASH_FELTS), ...this.take(HASH_FELTS)];
  }

  get at(): number {
    return this.pos;
  }
}

/** Splits a `CircuitProof` felt stream into the sections of `onchain-verifier.md` §2. */
export function parseProof(values: bigint[]): ProofSections {
  const s = new Stream(values);
  const claim = s.array(QM31_FELTS);
  const interactionPow = s.take(1);
  const interactionClaim = s.take(11 * QM31_FELTS);
  const pcsConfig = s.take(5);
  const commitments = s.array(HASH_FELTS);

  // sampled_values: Span<Span<Span<QM31>>> — kept as the raw slice, `d_sampled` hashes it.
  const start = s.at;
  const nTrees = Number(s.u());
  for (let t = 0; t < nTrees; t++) {
    const nCols = Number(s.u());
    for (let c = 0; c < nCols; c++) s.array(QM31_FELTS);
  }
  const sampled = values.slice(start, s.at);

  const nDecommitments = Number(s.u());
  const decommitments: bigint[][] = [];
  for (let i = 0; i < nDecommitments; i++) decommitments.push(s.array(HASH_FELTS));
  const nQueried = Number(s.u());
  const queriedValues: bigint[][] = [];
  for (let i = 0; i < nQueried; i++) queriedValues.push(s.array(1));

  const powNonce = s.take(1);
  const firstLayer = s.layer();
  const nInner = Number(s.u());
  const innerLayers: bigint[][] = [];
  for (let i = 0; i < nInner; i++) innerLayers.push(s.layer());
  const lastLayerPoly = [...s.array(QM31_FELTS), ...s.take(1)];
  const salt = s.take(1);
  if (s.at !== values.length) throw new Error(`trailing proof data: ${values.length - s.at} felts`);
  if (decommitments.length !== N_TREES || queriedValues.length !== N_TREES) {
    throw new Error(`expected ${N_TREES} Merkle trees, got ${decommitments.length}`);
  }

  const layers = [firstLayer, ...innerLayers];
  // The FRI *head* is the transcript-bound part of the walk: every layer's commitment (the
  // last HASH_FELTS of the layer proof), the inner count, and the last-layer polynomial.
  const friHead = [
    ...layers[0]!.slice(-HASH_FELTS),
    BigInt(nInner),
    ...innerLayers.flatMap((l) => l.slice(-HASH_FELTS)),
    ...lastLayerPoly,
  ];
  const head = [
    ...claim,
    ...interactionPow,
    ...interactionClaim,
    ...pcsConfig,
    ...commitments,
    ...sampled,
    ...powNonce,
    ...friHead,
    ...salt,
  ];
  return { head, sampled, queriedValues, decommitments, layers, pcsConfig };
}

/** Packs 7 little-endian u32 limbs per felt252, zero-padding the last slot. */
export function packLimbs(limbs: bigint[]): bigint[] {
  const padded = limbs.slice();
  while (padded.length % LIMBS_PER_SLOT) padded.push(0n);
  const slots: bigint[] = [];
  for (let i = 0; i < padded.length; i += LIMBS_PER_SLOT) {
    let slot = 0n;
    for (let j = 0; j < LIMBS_PER_SLOT; j++) slot += padded[i + j]! << BigInt(32 * j);
    slots.push(slot);
  }
  return slots;
}

/**
 * Escaped encoding — the head only, because it is the one section carrying the two u64 PoW
 * nonces. A plain `0xFFFFFFFF` is escaped as well: not doing so was a real 2^-32 collision bug
 * in the first version of the Cairo side.
 */
export function pack(values: bigint[]): bigint[] {
  const limbs: bigint[] = [];
  for (const v of values) {
    if (v < ESCAPE) {
      limbs.push(v);
    } else {
      if (v >= 1n << 64n) throw new Error(`value 0x${v.toString(16)} does not fit the u64 escape`);
      limbs.push(ESCAPE, v & 0xffffffffn, v >> 32n);
    }
  }
  return packLimbs(limbs);
}

/** Fast-path encoding (`unpack_u32`): one u32 per limb, no escapes. Every other section. */
export function packU32(values: bigint[]): bigint[] {
  for (const v of values) {
    if (v >= 1n << 32n) throw new Error(`packU32: value 0x${v.toString(16)} is not a u32`);
  }
  return packLimbs(values);
}

/** Inverse of `pack` — used by the round-trip assertions, never on chain. */
export function unpack(slots: bigint[], nValues: number): bigint[] {
  const limbs: bigint[] = [];
  for (const slot of slots) {
    for (let j = 0; j < LIMBS_PER_SLOT; j++) limbs.push((slot >> BigInt(32 * j)) & 0xffffffffn);
  }
  const out: bigint[] = [];
  let i = 0;
  while (out.length !== nValues) {
    if (limbs[i] === ESCAPE) {
      out.push(limbs[i + 1]! + (limbs[i + 2]! << 32n));
      i += 3;
    } else {
      out.push(limbs[i]!);
      i += 1;
    }
  }
  return out;
}

export function slotsOf(nFelts: number): number {
  return Math.ceil(nFelts / LIMBS_PER_SLOT);
}

/** Concatenation of independently fast-path-packed sections (each has its own padded slot). */
export function packSections(sections: bigint[][]): bigint[] {
  return sections.flatMap((s) => packU32(s));
}

/** Parses the one-felt-per-line `.txt` fixtures and the `[...]` JSON arrays alike. */
export function parseFeltStream(text: string): bigint[] {
  const trimmed = text.trimStart();
  if (trimmed.startsWith("[")) {
    return (JSON.parse(trimmed) as (string | number)[]).map((x) => BigInt(x));
  }
  return text.split(/\s+/).filter(Boolean).map((l) => BigInt(l));
}

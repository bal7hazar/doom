/**
 * Packing helpers specific to WAD tool v2's "packed" layout option (see
 * `emitConfig.ts`). Field-level packing shared with v1 (bias16/raw16/
 * packFields) lives in `packing.ts`; this module adds the multi-value and
 * multi-field layouts v2 introduces: bit-packing a plain list of small
 * indices several-per-felt (REJECT-style, S1 §5.9 "REJECT bit-packée"), and
 * packing the handful of new "cold" record shapes v2 needs (linedef
 * special/tag, sector light/special/tag, the R2-A4 half-plane predicate,
 * the linedef bbox).
 */
import { bias16, packFields, raw16, unbias16, unpackFields, unraw16 } from "./packing.js";
import { FixedBBox, HalfPlane, LinedefPredicate } from "./predicates.js";

/** Bits used per packed index in `packIndices`/`unpackIndices` (covers any WAD-scale count: subsectors, sectors, sidedefs). */
export const INDEX_BITS = 16;

/**
 * Bit-packs a flat list of small non-negative integers (each < 2^`bits`),
 * `perFelt` values per felt252, least-significant value first. Used for
 * cold, bulky index lists: SIDEDEFS_SECTOR, SUBSECTOR_SECTOR, and the
 * flattened R2-A9 accelerator candidate list. Mirrors the REJECT chunking
 * already used in v1 (`recordPacking.ts#packRejectRows`), generalized to
 * plain index arrays instead of bits.
 */
export function packIndices(values: number[], perFelt = 8, bits = INDEX_BITS): bigint[] {
  const out: bigint[] = [];
  for (let i = 0; i < values.length; i += perFelt) {
    const chunk = values.slice(i, i + perFelt);
    let acc = 0n;
    for (let j = 0; j < chunk.length; j++) {
      acc |= raw16(chunk[j]!) << BigInt(j * bits);
    }
    out.push(acc);
  }
  return out;
}

/** Inverse of `packIndices`. `count` is the original (unpadded) number of values. */
export function unpackIndices(packed: bigint[], count: number, perFelt = 8, bits = INDEX_BITS): number[] {
  const out: number[] = [];
  const mask = (1n << BigInt(bits)) - 1n;
  for (let i = 0; i < count; i++) {
    const felt = packed[Math.floor(i / perFelt)]!;
    const shift = BigInt((i % perFelt) * bits);
    out.push(unraw16((felt >> shift) & mask));
  }
  return out;
}

// --- linedef special/tag: special(16) | tag(16)<<16 --------------------------------------------
export function packLinedefSpecial(specialType: number, tag: number): bigint {
  return packFields([raw16(specialType), raw16(tag)], [16, 16]);
}
export function unpackLinedefSpecial(packed: bigint): { specialType: number; tag: number } {
  const [specialType, tag] = unpackFields(packed, [16, 16]);
  return { specialType: unraw16(specialType!), tag: unraw16(tag!) };
}

// --- linedef flags: blocking(1) | blockMonsters(1)<<1 | twoSided(1)<<2 -------------------------
export function packLinedefFlags(blocking: 0 | 1, blockMonsters: 0 | 1, twoSided: 0 | 1): bigint {
  return packFields([BigInt(blocking), BigInt(blockMonsters), BigInt(twoSided)], [1, 1, 1]);
}
export function unpackLinedefFlags(packed: bigint): { blocking: number; blockMonsters: number; twoSided: number } {
  const [blocking, blockMonsters, twoSided] = unpackFields(packed, [1, 1, 1]);
  return { blocking: Number(blocking!), blockMonsters: Number(blockMonsters!), twoSided: Number(twoSided!) };
}

// --- linedef sides: front(16) | back(16)<<16 (0xFFFF = NO_SIDEDEF) -----------------------------
export function packLinedefSides(frontSidedef: number, backSidedef: number): bigint {
  return packFields([raw16(frontSidedef), raw16(backSidedef)], [16, 16]);
}
export function unpackLinedefSides(packed: bigint): { frontSidedef: number; backSidedef: number } {
  const [frontSidedef, backSidedef] = unpackFields(packed, [16, 16]);
  return { frontSidedef: unraw16(frontSidedef!), backSidedef: unraw16(backSidedef!) };
}

// --- sector heights: floor_biased(16) | ceiling_biased(16)<<16 ----------------------------------
export function packSectorHeights(floorHeight: number, ceilingHeight: number): bigint {
  return packFields([bias16(floorHeight), bias16(ceilingHeight)], [16, 16]);
}
export function unpackSectorHeights(packed: bigint): { floorHeight: number; ceilingHeight: number } {
  const [floorHeight, ceilingHeight] = unpackFields(packed, [16, 16]);
  return { floorHeight: unbias16(floorHeight!), ceilingHeight: unbias16(ceilingHeight!) };
}

// --- sector metadata: light_biased(16) | special(16)<<16 | tag(16)<<32 -------------------------
export function packSectorMeta(lightLevel: number, specialType: number, tag: number): bigint {
  return packFields([bias16(lightLevel), raw16(specialType), raw16(tag)], [16, 16, 16]);
}
export function unpackSectorMeta(packed: bigint): { lightLevel: number; specialType: number; tag: number } {
  const [lightLevel, specialType, tag] = unpackFields(packed, [16, 16, 16]);
  return { lightLevel: unbias16(lightLevel!), specialType: unraw16(specialType!), tag: unraw16(tag!) };
}

// --- half-plane predicate (R2-A4): ab(15) | bb(15)<<15 | cb(50)<<30 | diag(1)<<80 ---------------
// ab, bb < 2^13 + 2^13 = 2^14 in practice but bounded generously at 15 bits (predicates.ts asserts
// < 2^15); cb < 2^50 (predicates.ts asserts this exactly). Total width 81 bits, well under 2^128.
const PREDICATE_WIDTHS = [15, 15, 50, 1];
export function packPredicate(p: HalfPlane & { diag?: 0 | 1 }): bigint {
  return packFields([p.ab, p.bb, p.cb, BigInt(p.diag ?? 0)], PREDICATE_WIDTHS);
}
export function unpackPredicate(packed: bigint): LinedefPredicate {
  const [ab, bb, cb, diag] = unpackFields(packed, PREDICATE_WIDTHS);
  return { ab: ab!, bb: bb!, cb: cb!, diag: (diag === 1n ? 1 : 0) as 0 | 1 };
}

// --- linedef bbox: two felts, {left,right} and {bottom,top}, 33 bits each ----------------------
// left/right/bottom/top are biased-fixed values (x*FRACUNIT + OFF, see predicates.ts) which fit
// under 2^33 for the full int16 map-unit range (32767*65536 + 2^32 < 2^33).
const BBOX_HALF_WIDTHS = [33, 33];
export function packBBoxLR(bbox: FixedBBox): bigint {
  return packFields([bbox.left, bbox.right], BBOX_HALF_WIDTHS);
}
export function packBBoxBT(bbox: FixedBBox): bigint {
  return packFields([bbox.bottom, bbox.top], BBOX_HALF_WIDTHS);
}
export function unpackBBox(lr: bigint, bt: bigint): FixedBBox {
  const [left, right] = unpackFields(lr, BBOX_HALF_WIDTHS);
  const [bottom, top] = unpackFields(bt, BBOX_HALF_WIDTHS);
  return { left: left!, right: right!, bottom: bottom!, top: top! };
}

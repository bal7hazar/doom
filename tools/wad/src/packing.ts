/**
 * Packing of parsed WAD records into single non-negative felt252 constants
 * for the Cairo game core (roadmap P0.2, Output B). See `cairoOutput.ts` for
 * how these are laid out into `const` arrays, and the header comment it
 * generates for the full, authoritative packing spec.
 *
 * Three encoding rules cover every field found in the map lumps:
 *
 *  - "biased" fields: a genuine signed magnitude stored as a signed int16 in
 *    the WAD (coordinates, offsets, heights, node partition/bbox deltas).
 *    Encoded as `value + 32768`, which maps the full int16 range
 *    [-32768, 32767] onto the non-negative range [0, 65535]. Decoded with
 *    `unbias16`.
 *  - "raw" fields: already a non-negative uint16 in the WAD (indices, flags,
 *    enums, counts, the 0xFFFF NO_SIDEDEF/terminator sentinel). Packed as-is.
 *  - "bam16" (SEGS angle only): a circular BAM32 angle stored as the signed
 *    top 16 bits of angle_t. Bit-reinterpreted as unsigned 0..65535 by the
 *    parser already (see `mapLumps.ts#parseSegs`), so by the time it reaches
 *    this module it is handled exactly like a "raw" field.
 *
 * Every packed felt252 produced here stays strictly below 2^128: the current
 * Stwo-cairo adapter panics on any value >= 2^128 written to memory
 * (CONTEXT.md §4.3), and rule A7 (PLAN.md §1) forbids negative felts in
 * memory. Both constraints are satisfied by construction: fields are
 * non-negative 16- or 64-bit quantities and records pack at most 7 of them.
 */

export const BIAS_16 = 32768n;
export const MAX_U128 = (1n << 128n) - 1n;

export function bias16(signed: number): bigint {
  if (signed < -32768 || signed > 32767) {
    throw new RangeError(`bias16: ${signed} does not fit in a signed 16-bit range`);
  }
  return BigInt(signed) + BIAS_16;
}

export function unbias16(biased: bigint): number {
  const v = biased - BIAS_16;
  if (v < -32768n || v > 32767n) {
    throw new RangeError(`unbias16: ${biased} does not decode to a signed 16-bit value`);
  }
  return Number(v);
}

export function raw16(value: number): bigint {
  if (value < 0 || value > 0xffff) {
    throw new RangeError(`raw16: ${value} does not fit in an unsigned 16-bit range`);
  }
  return BigInt(value);
}

export function unraw16(value: bigint): number {
  if (value < 0n || value > 0xffffn) {
    throw new RangeError(`unraw16: ${value} does not decode to an unsigned 16-bit value`);
  }
  return Number(value);
}

/**
 * Packs `fields` (already-encoded non-negative bigints) into one felt252,
 * field `i` occupying bits `[offset, offset+bits[i])` with `offset` the sum
 * of the preceding widths (i.e. field 0 is the low bits). Validates each
 * field fits in its declared width and that the total stays below 2^128.
 */
export function packFields(fields: bigint[], bits: number[]): bigint {
  if (fields.length !== bits.length) {
    throw new Error(`packFields: ${fields.length} fields but ${bits.length} widths`);
  }
  let acc = 0n;
  let shift = 0n;
  for (let i = 0; i < fields.length; i++) {
    const width = bits[i]!;
    const value = fields[i]!;
    const max = (1n << BigInt(width)) - 1n;
    if (value < 0n || value > max) {
      throw new RangeError(`packFields: field ${i} value ${value} does not fit in ${width} bits`);
    }
    acc |= value << shift;
    shift += BigInt(width);
  }
  if (acc > MAX_U128) {
    throw new RangeError(`packFields: packed value ${acc} is >= 2^128`);
  }
  return acc;
}

/** Inverse of `packFields`: splits `packed` back into fields of the given widths. */
export function unpackFields(packed: bigint, bits: number[]): bigint[] {
  const out: bigint[] = [];
  let rest = packed;
  for (const width of bits) {
    const mask = (1n << BigInt(width)) - 1n;
    out.push(rest & mask);
    rest >>= BigInt(width);
  }
  if (rest !== 0n) {
    throw new RangeError(`unpackFields: ${rest} left over after unpacking widths [${bits.join(",")}]`);
  }
  return out;
}

/**
 * Packs up to 8 ASCII bytes of a lump/texture/flat name (little-endian,
 * byte 0 in bits [0,8)) into a single non-negative integer < 2^64. Shorter
 * names are NUL-padded, matching the on-disk representation. `-` (a literal
 * dash) denotes "no texture" and round-trips like any other name.
 */
export function nameToU64(name: string): bigint {
  if (name.length > 8) {
    throw new RangeError(`nameToU64: "${name}" is longer than 8 characters`);
  }
  let acc = 0n;
  for (let i = 0; i < 8; i++) {
    const byte = i < name.length ? name.charCodeAt(i) : 0;
    if (byte > 0xff) {
      throw new RangeError(`nameToU64: "${name}" contains a non-Latin1 character at index ${i}`);
    }
    acc |= BigInt(byte) << BigInt(8 * i);
  }
  return acc;
}

export function u64ToName(value: bigint): string {
  if (value < 0n || value > 0xffffffffffffffffn) {
    throw new RangeError(`u64ToName: ${value} does not fit in 64 bits`);
  }
  const bytes: number[] = [];
  for (let i = 0; i < 8; i++) {
    bytes.push(Number((value >> BigInt(8 * i)) & 0xffn));
  }
  const nul = bytes.indexOf(0);
  const slice = nul === -1 ? bytes : bytes.slice(0, nul);
  return String.fromCharCode(...slice);
}

/**
 * Browser-side little-endian reader over a `Uint8Array` (see README.md for why
 * this is not `tools/wad/src/binary.ts`). Same contract: every read is bounds
 * checked so a truncated lump fails loudly instead of returning garbage.
 */
export class BinaryReader {
  readonly bytes: Uint8Array;
  private readonly view: DataView;
  offset: number;

  constructor(bytes: Uint8Array, offset = 0) {
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this.offset = offset;
  }

  private need(size: number): number {
    if (this.offset + size > this.bytes.length) {
      throw new RangeError(
        `BinaryReader: read of ${size} bytes at offset ${this.offset} exceeds length ${this.bytes.length}`,
      );
    }
    const at = this.offset;
    this.offset += size;
    return at;
  }

  uint8(): number {
    return this.view.getUint8(this.need(1));
  }

  int16(): number {
    return this.view.getInt16(this.need(2), true);
  }

  uint16(): number {
    return this.view.getUint16(this.need(2), true);
  }

  int32(): number {
    return this.view.getInt32(this.need(4), true);
  }

  uint32(): number {
    return this.view.getUint32(this.need(4), true);
  }

  /** Fixed-size NUL-padded ASCII name (8 bytes for lumps, 4 for the WAD magic). */
  name(size: number): string {
    const at = this.need(size);
    return readName(this.bytes, at, size);
  }

  bytesOf(size: number): Uint8Array {
    const at = this.need(size);
    return this.bytes.subarray(at, at + size);
  }

  skip(size: number): void {
    this.need(size);
  }
}

/** Reads a NUL-padded, uppercase ASCII name directly out of a byte array. */
export function readName(bytes: Uint8Array, offset: number, size: number): string {
  let end = offset + size;
  for (let i = offset; i < offset + size; i++) {
    if (bytes[i] === 0) {
      end = i;
      break;
    }
  }
  let s = "";
  for (let i = offset; i < end; i++) s += String.fromCharCode(bytes[i]!);
  return s;
}

/** Reads a 32-bit LE integer at an absolute offset without moving a cursor. */
export function uint32At(view: DataView, offset: number): number {
  return view.getUint32(offset, true);
}

/**
 * Small little-endian binary reader shared by every lump parser.
 *
 * All vanilla Doom WAD structures are little-endian. Multi-byte integers are
 * either signed or unsigned 16-bit ("short"/"unsigned short" in the original
 * C structures) or 32-bit (WAD header only). This wrapper centralizes bounds
 * checking so a truncated/corrupt lump fails fast with a clear message
 * instead of returning garbage.
 *
 * Reads through a `DataView` over a plain `Uint8Array`, so this class has no
 * dependency on Node's `Buffer` and works unchanged in a browser. A Node
 * `Buffer` *is* a `Uint8Array` (it extends it), so every existing caller that
 * passes a `Buffer` (e.g. from `readFileSync`) keeps working without change.
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

  private checkAvailable(size: number): void {
    if (this.offset + size > this.bytes.length) {
      throw new RangeError(
        `BinaryReader: attempted to read ${size} bytes at offset ${this.offset}, ` +
          `but buffer length is ${this.bytes.length}`,
      );
    }
  }

  int16(): number {
    this.checkAvailable(2);
    const v = this.view.getInt16(this.offset, true);
    this.offset += 2;
    return v;
  }

  uint16(): number {
    this.checkAvailable(2);
    const v = this.view.getUint16(this.offset, true);
    this.offset += 2;
    return v;
  }

  int32(): number {
    this.checkAvailable(4);
    const v = this.view.getInt32(this.offset, true);
    this.offset += 4;
    return v;
  }

  uint32(): number {
    this.checkAvailable(4);
    const v = this.view.getUint32(this.offset, true);
    this.offset += 4;
    return v;
  }

  uint8(): number {
    this.checkAvailable(1);
    const v = this.view.getUint8(this.offset);
    this.offset += 1;
    return v;
  }

  /** Reads a fixed-size, NUL-padded ASCII lump/texture/flat name (typically 8 bytes). */
  name(size: number): string {
    this.checkAvailable(size);
    const s = readName(this.bytes, this.offset, size);
    this.offset += size;
    return s;
  }

  /** Returns the next `size` bytes as a view (no copy) and advances the cursor. */
  bytesOf(size: number): Uint8Array {
    this.checkAvailable(size);
    const v = this.bytes.subarray(this.offset, this.offset + size);
    this.offset += size;
    return v;
  }

  skip(size: number): void {
    this.checkAvailable(size);
    this.offset += size;
  }

  get remaining(): number {
    return this.bytes.length - this.offset;
  }

  get eof(): boolean {
    return this.offset >= this.bytes.length;
  }
}

/**
 * Reads a NUL-padded ASCII name of `size` bytes directly out of a byte array
 * at `offset`. Doom lump/texture/flat names are pure 7-bit ASCII, so a plain
 * per-byte `String.fromCharCode` is equivalent to Node's `"ascii"` string
 * decoding for every valid name, without depending on `Buffer`.
 */
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

/** Lowercase-hex encoding of a byte array (equivalent to Node's `Buffer#toString("hex")`). */
export function bytesToHex(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i++) {
    s += bytes[i]!.toString(16).padStart(2, "0");
  }
  return s;
}

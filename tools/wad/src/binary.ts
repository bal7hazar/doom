/**
 * Small little-endian binary reader shared by every lump parser.
 *
 * All vanilla Doom WAD structures are little-endian. Multi-byte integers are
 * either signed or unsigned 16-bit ("short"/"unsigned short" in the original
 * C structures) or 32-bit (WAD header only). This wrapper centralizes bounds
 * checking so a truncated/corrupt lump fails fast with a clear message
 * instead of returning garbage.
 */

export class BinaryReader {
  readonly buffer: Buffer;
  offset: number;

  constructor(buffer: Buffer, offset = 0) {
    this.buffer = buffer;
    this.offset = offset;
  }

  private checkAvailable(size: number): void {
    if (this.offset + size > this.buffer.length) {
      throw new RangeError(
        `BinaryReader: attempted to read ${size} bytes at offset ${this.offset}, ` +
          `but buffer length is ${this.buffer.length}`,
      );
    }
  }

  int16(): number {
    this.checkAvailable(2);
    const v = this.buffer.readInt16LE(this.offset);
    this.offset += 2;
    return v;
  }

  uint16(): number {
    this.checkAvailable(2);
    const v = this.buffer.readUInt16LE(this.offset);
    this.offset += 2;
    return v;
  }

  int32(): number {
    this.checkAvailable(4);
    const v = this.buffer.readInt32LE(this.offset);
    this.offset += 4;
    return v;
  }

  uint32(): number {
    this.checkAvailable(4);
    const v = this.buffer.readUInt32LE(this.offset);
    this.offset += 4;
    return v;
  }

  uint8(): number {
    this.checkAvailable(1);
    const v = this.buffer.readUInt8(this.offset);
    this.offset += 1;
    return v;
  }

  /** Reads a fixed-size, NUL-padded ASCII lump/texture/flat name (typically 8 bytes). */
  name(size: number): string {
    this.checkAvailable(size);
    const raw = this.buffer.subarray(this.offset, this.offset + size);
    this.offset += size;
    const nul = raw.indexOf(0);
    const bytes = nul === -1 ? raw : raw.subarray(0, nul);
    return bytes.toString("ascii");
  }

  bytes(size: number): Buffer {
    this.checkAvailable(size);
    const v = this.buffer.subarray(this.offset, this.offset + size);
    this.offset += size;
    return v;
  }

  skip(size: number): void {
    this.checkAvailable(size);
    this.offset += size;
  }

  get remaining(): number {
    return this.buffer.length - this.offset;
  }

  get eof(): boolean {
    return this.offset >= this.buffer.length;
  }
}

/** Reads a NUL-padded ASCII name of `size` bytes directly out of a Buffer at `offset`. */
export function readName(buffer: Buffer, offset: number, size: number): string {
  const raw = buffer.subarray(offset, offset + size);
  const nul = raw.indexOf(0);
  const bytes = nul === -1 ? raw : raw.subarray(0, nul);
  return bytes.toString("ascii");
}

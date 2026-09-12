import { describe, expect, it } from "vitest";
import { BinaryReader, bytesToHex, readName } from "../src/binary.js";

describe("BinaryReader", () => {
  it("reads little-endian signed and unsigned integers", () => {
    const buf = Buffer.alloc(12);
    buf.writeInt16LE(-1, 0);
    buf.writeUInt16LE(0xffff, 2);
    buf.writeInt32LE(-70000, 4);
    buf.writeUInt32LE(0xdeadbeef, 8);
    const r = new BinaryReader(buf);
    expect(r.int16()).toBe(-1);
    expect(r.uint16()).toBe(0xffff);
    expect(r.int32()).toBe(-70000);
    expect(r.uint32()).toBe(0xdeadbeef);
    expect(r.eof).toBe(true);
  });

  it("reads NUL-padded fixed-size names and trims at the first NUL", () => {
    const buf = Buffer.alloc(8);
    buf.write("SKY1", 0, "ascii");
    const r = new BinaryReader(buf);
    expect(r.name(8)).toBe("SKY1");
  });

  it("reads a full-length 8-char name with no NUL padding at all", () => {
    const buf = Buffer.from("STARTAN2", "ascii");
    const r = new BinaryReader(buf);
    expect(r.name(8)).toBe("STARTAN2");
  });

  it("throws on out-of-bounds reads instead of returning garbage", () => {
    const buf = Buffer.alloc(2);
    const r = new BinaryReader(buf);
    r.uint16();
    expect(() => r.uint16()).toThrow(RangeError);
  });

  it("readName standalone helper matches BinaryReader#name", () => {
    const buf = Buffer.from("LINEDEF\0", "ascii");
    expect(readName(buf, 0, 8)).toBe("LINEDEF");
  });

  it("reads through a DataView over a plain Uint8Array (no Buffer involved)", () => {
    // Browser-safety check: everything above this test happens to run on a
    // Node `Buffer`, which *is* a `Uint8Array`; this one proves the reader
    // works given a bare `Uint8Array`, e.g. from `await response.arrayBuffer()`.
    const bytes = new Uint8Array(12);
    const view = new DataView(bytes.buffer);
    view.setInt16(0, -1, true);
    view.setUint16(2, 0xffff, true);
    view.setInt32(4, -70000, true);
    view.setUint32(8, 0xdeadbeef, true);
    expect(bytes).not.toBeInstanceOf(Buffer);

    const r = new BinaryReader(bytes);
    expect(r.int16()).toBe(-1);
    expect(r.uint16()).toBe(0xffff);
    expect(r.int32()).toBe(-70000);
    expect(r.uint32()).toBe(0xdeadbeef);
  });

  it("readName on a plain Uint8Array trims at the first NUL, byte-for-byte like ascii", () => {
    const bytes = Uint8Array.from([0x53, 0x4b, 0x59, 0x31, 0, 0, 0, 0]); // "SKY1\0\0\0\0"
    expect(readName(bytes, 0, 8)).toBe("SKY1");
  });

  it("bytesToHex matches Node Buffer#toString(\"hex\")", () => {
    const bytes = Uint8Array.of(0x00, 0x0f, 0xa5, 0xff);
    expect(bytesToHex(bytes)).toBe(Buffer.from(bytes).toString("hex"));
  });
});

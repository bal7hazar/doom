import { describe, expect, it } from "vitest";
import { BinaryReader, readName } from "../src/binary.js";

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
});

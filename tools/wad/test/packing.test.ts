import { describe, expect, it } from "vitest";
import { bias16, MAX_U128, nameToU64, packFields, raw16, u64ToName, unbias16, unpackFields, unraw16 } from "../src/packing.js";
import {
  packBBox,
  packBlockmapHeader,
  packBlockmapWords,
  packLinedef,
  packNode,
  packRejectRows,
  packSector,
  packSeg,
  packSidedef,
  packSubsector,
  packThing,
  packVertex,
  rejectChunksPerRow,
  unpackBBox,
  unpackBlockmapHeader,
  unpackLinedef,
  unpackNode,
  unpackRejectBit,
  unpackSector,
  unpackSeg,
  unpackSidedef,
  unpackSubsector,
  unpackThing,
  unpackVertex,
} from "../src/recordPacking.js";
import { NO_SIDEDEF } from "../src/types.js";

describe("primitives", () => {
  it("bias16/unbias16 round-trip the full signed 16-bit range and stay non-negative", () => {
    for (const v of [-32768, -1, 0, 1, 32767]) {
      const biased = bias16(v);
      expect(biased >= 0n).toBe(true);
      expect(unbias16(biased)).toBe(v);
    }
  });

  it("bias16 rejects out-of-range input", () => {
    expect(() => bias16(32768)).toThrow(RangeError);
    expect(() => bias16(-32769)).toThrow(RangeError);
  });

  it("raw16/unraw16 round-trip 0..65535, including the 0xFFFF sentinel", () => {
    for (const v of [0, 1, 0x7fff, 0xfffe, 0xffff]) {
      expect(unraw16(raw16(v))).toBe(v);
    }
    expect(() => raw16(-1)).toThrow(RangeError);
    expect(() => raw16(0x10000)).toThrow(RangeError);
  });

  it("packFields/unpackFields round-trip arbitrary field widths", () => {
    const fields = [5n, 0xffffn, 1n];
    const widths = [16, 16, 8];
    const packed = packFields(fields, widths);
    expect(unpackFields(packed, widths)).toEqual(fields);
  });

  it("packFields rejects a field that overflows its declared width", () => {
    expect(() => packFields([0x10000n], [16])).toThrow(RangeError);
  });

  it("packFields rejects results >= 2^128 (rule A7 / adapter panic guard)", () => {
    expect(() => packFields([MAX_U128 + 1n], [129])).toThrow(/2\^128/);
  });

  it("unpackFields rejects leftover bits (packed value too large for the declared widths)", () => {
    expect(() => unpackFields(0x10000n, [16])).toThrow(RangeError);
  });

  it("nameToU64/u64ToName round-trip short names, 8-char names, and '-' (no texture)", () => {
    for (const name of ["-", "SKY1", "STARTAN2", "A"]) {
      expect(u64ToName(nameToU64(name))).toBe(name);
    }
    expect(nameToU64("STARTAN2") < 1n << 64n).toBe(true);
  });

  it("nameToU64 rejects names longer than 8 characters", () => {
    expect(() => nameToU64("TOOLONGNAME")).toThrow(RangeError);
  });
});

describe("per-record packing round-trips", () => {
  it("VERTEX: positive, negative, and boundary coordinates", () => {
    for (const v of [{ x: 0, y: 0 }, { x: -32768, y: 32767 }, { x: 100, y: -200 }]) {
      const packed = packVertex(v);
      expect(packed >= 0n).toBe(true);
      expect(unpackVertex(packed)).toEqual(v);
    }
  });

  it("THING: coordinates, angle, type, flags", () => {
    const t = { x: -100, y: 200, angle: 359, type: 3004, flags: 0x1f };
    expect(unpackThing(packThing(t))).toEqual(t);
  });

  it("LINEDEF: indices, flags, special, tag, and the 0xFFFF NO_SIDEDEF sentinel on both sides", () => {
    const l = {
      startVertex: 12,
      endVertex: 34,
      flags: 0x0004,
      specialType: 1,
      sectorTag: 0,
      frontSidedef: 56,
      backSidedef: NO_SIDEDEF,
    };
    const packed = packLinedef(l);
    expect(packed >= 0n).toBe(true);
    expect(unpackLinedef(packed)).toEqual(l);

    const oneSided = { ...l, frontSidedef: NO_SIDEDEF, backSidedef: NO_SIDEDEF };
    expect(unpackLinedef(packLinedef(oneSided))).toEqual(oneSided);
  });

  it("SIDEDEF: numeric fields plus three independently packed texture names", () => {
    const s = { xOffset: -8, yOffset: 16, upperTexture: "-", lowerTexture: "STARTAN2", middleTexture: "BIGDOOR2", sector: 7 };
    const packed = packSidedef(s);
    expect(unpackSidedef(packed)).toEqual(s);
  });

  it("SEG: vertex/linedef indices, raw BAM angle, direction, biased offset", () => {
    const s = { startVertex: 1, endVertex: 2, angle: 65535, linedef: 9, direction: 1, offset: -50 };
    expect(unpackSeg(packSeg(s))).toEqual(s);
  });

  it("SSECTOR: numSegs/firstSeg", () => {
    const s = { numSegs: 4, firstSeg: 100 };
    expect(unpackSubsector(packSubsector(s))).toEqual(s);
  });

  it("NODE: partition, both bboxes, and children (leaf flag bit preserved)", () => {
    const n = {
      x: -10,
      y: 20,
      dx: 64,
      dy: -64,
      rightBBox: { top: 100, bottom: -100, left: -50, right: 50 },
      leftBBox: { top: 200, bottom: 0, left: -50, right: 50 },
      rightChild: 0x8003,
      leftChild: 1,
    };
    expect(unpackNode(packNode(n))).toEqual(n);
    expect(unpackBBox(packBBox(n.rightBBox))).toEqual(n.rightBBox);
  });

  it("SECTOR: heights/light (biased), special/tag (raw), plus two texture names", () => {
    const s = {
      floorHeight: -8,
      ceilingHeight: 128,
      floorTexture: "FLOOR0_1",
      ceilingTexture: "CEIL1_1",
      lightLevel: 200,
      specialType: 9,
      tag: 1,
    };
    expect(unpackSector(packSector(s))).toEqual(s);
  });

  it("BLOCKMAP header: origin (biased), columns/rows (raw)", () => {
    const h = { originX: -712, originY: -1072, columns: 32, rows: 27 };
    expect(unpackBlockmapHeader(packBlockmapHeader(h))).toEqual(h);
  });

  it("BLOCKMAP words: identity bit-reinterpretation of every 16-bit word in the lump", () => {
    const buf = Buffer.from([0x00, 0x00, 0xff, 0xff, 0x34, 0x12]);
    const words = packBlockmapWords(buf);
    expect(words).toEqual([0n, 0xffffn, 0x1234n]);
  });

  it("REJECT rows: packs/unpacks bits across a chunk boundary (>128 sectors)", () => {
    const numSectors = 200; // needs 2 felt252 chunks/row (128 + 72 bits)
    expect(rejectChunksPerRow(numSectors)).toBe(2);
    const data = Buffer.alloc(Math.ceil((numSectors * numSectors) / 8));
    const setBit = (i: number, j: number) => {
      const bit = i * numSectors + j;
      data[bit >> 3]! |= 1 << (bit & 7);
    };
    setBit(0, 0);
    setBit(0, 127); // last bit of chunk 0
    setBit(0, 128); // first bit of chunk 1
    setBit(5, 199); // last column, second chunk
    const rows = packRejectRows(data, numSectors);
    expect(rows).toHaveLength(numSectors * 2);
    for (const chunk of rows) expect(chunk < (1n << 128n)).toBe(true);
    expect(unpackRejectBit(rows, numSectors, 0, 0)).toBe(true);
    expect(unpackRejectBit(rows, numSectors, 0, 127)).toBe(true);
    expect(unpackRejectBit(rows, numSectors, 0, 128)).toBe(true);
    expect(unpackRejectBit(rows, numSectors, 0, 1)).toBe(false);
    expect(unpackRejectBit(rows, numSectors, 5, 199)).toBe(true);
    expect(unpackRejectBit(rows, numSectors, 5, 198)).toBe(false);
  });
});

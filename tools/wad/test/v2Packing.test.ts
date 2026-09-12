import { describe, expect, it } from "vitest";
import { linedefFixedBBox, linedefPredicate } from "../src/predicates.js";
import {
  packBBoxBT,
  packBBoxLR,
  packIndices,
  packLinedefFlags,
  packLinedefSides,
  packLinedefSpecial,
  packPredicate,
  packSectorHeights,
  packSectorMeta,
  unpackBBox,
  unpackIndices,
  unpackLinedefFlags,
  unpackLinedefSides,
  unpackLinedefSpecial,
  unpackPredicate,
  unpackSectorHeights,
  unpackSectorMeta,
} from "../src/v2Packing.js";

describe("packIndices/unpackIndices", () => {
  it("round-trips a list not evenly divisible by perFelt", () => {
    const values = [0, 1, 65535, 42, 7, 999, 12345, 3, 4, 5, 6];
    const packed = packIndices(values, 4);
    expect(packed.length).toBe(Math.ceil(values.length / 4));
    expect(unpackIndices(packed, values.length, 4)).toEqual(values);
  });

  it("round-trips with the default perFelt/bits (8 values, 16 bits each)", () => {
    const values = Array.from({ length: 37 }, (_, i) => (i * 137) % 65536);
    const packed = packIndices(values);
    expect(unpackIndices(packed, values.length)).toEqual(values);
  });

  it("packs strictly fewer felts than one-per-value once perFelt > 1", () => {
    const values = Array.from({ length: 100 }, (_, i) => i);
    expect(packIndices(values, 8).length).toBe(13);
  });

  it("rejects a value that doesn't fit the declared bit width", () => {
    expect(() => packIndices([70000], 8, 16)).toThrow(RangeError);
  });
});

describe("packLinedefSpecial/unpackLinedefSpecial", () => {
  it("round-trips", () => {
    for (const [special, tag] of [[0, 0], [11, 5], [65535, 65535]]) {
      expect(unpackLinedefSpecial(packLinedefSpecial(special!, tag!))).toEqual({ specialType: special, tag });
    }
  });
});

describe("packLinedefFlags/unpackLinedefFlags", () => {
  it("round-trips every combination of the three bits", () => {
    for (const blocking of [0, 1] as const) {
      for (const blockMonsters of [0, 1] as const) {
        for (const twoSided of [0, 1] as const) {
          const packed = packLinedefFlags(blocking, blockMonsters, twoSided);
          expect(unpackLinedefFlags(packed)).toEqual({ blocking, blockMonsters, twoSided });
        }
      }
    }
  });
});

describe("packLinedefSides/unpackLinedefSides", () => {
  it("round-trips, including the 0xFFFF NO_SIDEDEF sentinel", () => {
    expect(unpackLinedefSides(packLinedefSides(0, 0xffff))).toEqual({ frontSidedef: 0, backSidedef: 0xffff });
    expect(unpackLinedefSides(packLinedefSides(1829, 0))).toEqual({ frontSidedef: 1829, backSidedef: 0 });
  });
});

describe("packSectorHeights/unpackSectorHeights", () => {
  it("round-trips the full signed int16 range", () => {
    for (const [floor, ceiling] of [[-32768, 32767], [0, 0], [128, -256]]) {
      expect(unpackSectorHeights(packSectorHeights(floor!, ceiling!))).toEqual({ floorHeight: floor, ceilingHeight: ceiling });
    }
  });
});

describe("packSectorMeta/unpackSectorMeta", () => {
  it("round-trips light/special/tag", () => {
    const packed = packSectorMeta(200, 9, 3);
    expect(unpackSectorMeta(packed)).toEqual({ lightLevel: 200, specialType: 9, tag: 3 });
  });
});

describe("packPredicate/unpackPredicate", () => {
  it("round-trips a real linedef predicate, including diag", () => {
    const pred = linedefPredicate({ x: -100, y: 200 }, { x: 300, y: -50 });
    const packed = packPredicate(pred);
    expect(unpackPredicate(packed)).toEqual(pred);
  });

  it("defaults diag to 0 for a node predicate (no diag field)", () => {
    const packed = packPredicate({ ab: 1n, bb: 2n, cb: 3n });
    expect(unpackPredicate(packed)).toEqual({ ab: 1n, bb: 2n, cb: 3n, diag: 0 });
  });
});

describe("packBBoxLR/packBBoxBT/unpackBBox", () => {
  it("round-trips a real linedef bbox", () => {
    const bbox = linedefFixedBBox({ x: -100, y: 200 }, { x: 300, y: -50 });
    const lr = packBBoxLR(bbox);
    const bt = packBBoxBT(bbox);
    expect(unpackBBox(lr, bt)).toEqual(bbox);
  });
});

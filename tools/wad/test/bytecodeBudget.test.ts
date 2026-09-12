import { describe, expect, it } from "vitest";
import { assertBudget, BudgetExceededError, bootloaderHashSteps, computeBytecodeBudget } from "../src/bytecodeBudget.js";
import { buildMapCairo } from "../src/cairoOutput.js";
import { ALL_PACKED_CONFIG, ALL_PLANAR_CONFIG, DEFAULT_EMIT_CONFIG } from "../src/emitConfig.js";
import { extractMap } from "../src/mapExtract.js";
import { Wad } from "../src/wad.js";
import { hasRealWad, readRealWad } from "./realWad.js";
import { blockmapLump, buildWad, linedefLump, nodeLump, rejectLump, sectorLump, segLump, sidedefLump, subsectorLump, thingLump, vertexLump } from "./testWad.js";
import { NODE_LEAF_FLAG } from "../src/types.js";

describe("computeBytecodeBudget", () => {
  it("counts one word per array element, summed across arrays", () => {
    const budget = computeBytecodeBudget([
      { name: "A", group: "g1", layout: "planar", count: 10 },
      { name: "B", group: "g1", layout: "planar", count: 5 },
      { name: "C", group: "g2", layout: "packed", count: 3 },
    ]);
    expect(budget.arrays.map((a) => a.words)).toEqual([10, 5, 3]);
    expect(budget.totalWords).toBe(18);
  });

  it("returns zero total for no arrays", () => {
    expect(computeBytecodeBudget([]).totalWords).toBe(0);
  });
});

describe("bootloaderHashSteps", () => {
  it("matches docs/spikes/S0.md §5.2's formula (2340 + 14.7*words)", () => {
    expect(bootloaderHashSteps(0)).toBe(2340);
    expect(bootloaderHashSteps(1000)).toBeCloseTo(2340 + 14700, 6);
  });
});

describe("assertBudget", () => {
  it("does not throw when under budget", () => {
    const budget = computeBytecodeBudget([{ name: "A", group: "g", layout: "planar", count: 100 }]);
    expect(() => assertBudget(budget, 200)).not.toThrow();
  });

  it("throws BudgetExceededError with the actual/max words when over budget", () => {
    const budget = computeBytecodeBudget([{ name: "A", group: "g", layout: "planar", count: 300 }]);
    try {
      assertBudget(budget, 200);
      expect.unreachable("assertBudget should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(BudgetExceededError);
      expect((err as BudgetExceededError).totalWords).toBe(300);
      expect((err as BudgetExceededError).maxWords).toBe(200);
    }
  });

  it("is exactly at the boundary: equal to max-words does not throw", () => {
    const budget = computeBytecodeBudget([{ name: "A", group: "g", layout: "planar", count: 200 }]);
    expect(() => assertBudget(budget, 200)).not.toThrow();
  });
});

/** A minimal but fully-formed one-room, one-thing, two-sector-reject map for exercising the full emitter. */
function smallWad(): Wad {
  const vertexes = vertexLump([[0, 0], [128, 0], [128, 128], [0, 128]]);
  const segs = segLump([
    { v1: 0, v2: 1, angle: 0, linedef: 0, direction: 0, offset: 0 },
  ]);
  const ssectors = subsectorLump([{ numSegs: 1, firstSeg: 0 }]);
  const nodes = nodeLump([
    {
      x: 0,
      y: 0,
      dx: 1,
      dy: 0,
      rightBBox: [128, 0, 0, 128],
      leftBBox: [128, 0, 0, 128],
      rightChild: NODE_LEAF_FLAG | 0,
      leftChild: NODE_LEAF_FLAG | 0,
    },
  ]);
  const linedefs = linedefLump([
    { v1: 0, v2: 1, flags: 1, special: 0, tag: 0, front: 0, back: 0xffff },
    { v1: 1, v2: 2, flags: 0, special: 11, tag: 5, front: 0, back: 0xffff },
  ]);
  const sidedefs = sidedefLump([{ xOff: 0, yOff: 0, upper: "-", lower: "-", middle: "STARTAN", sector: 0 }]);
  const sectors = sectorLump([{ floor: 0, ceiling: 128, floorTex: "FLOOR0", ceilTex: "CEIL0", light: 160, special: 0, tag: 0 }]);
  const things = thingLump([{ x: 64, y: 64, angle: 0, type: 1, flags: 7 }]);

  return Wad.fromBuffer(
    buildWad([
      { name: "T4M1", data: Buffer.alloc(0) },
      { name: "THINGS", data: things },
      { name: "LINEDEFS", data: linedefs },
      { name: "SIDEDEFS", data: sidedefs },
      { name: "VERTEXES", data: vertexes },
      { name: "SEGS", data: segs },
      { name: "SSECTORS", data: ssectors },
      { name: "NODES", data: nodes },
      { name: "SECTORS", data: sectors },
      { name: "REJECT", data: rejectLump(1, []) },
      { name: "BLOCKMAP", data: blockmapLump(0, 0, 1, 1, [[0, 1]]) },
    ]),
  );
}

describe("buildMapCairo x computeBytecodeBudget integration", () => {
  it("all-packed uses no more words than all-planar for a small synthetic map (packing trades reads for words, not the reverse)", () => {
    const map = extractMap(smallWad(), "T4M1");
    const planar = computeBytecodeBudget(buildMapCairo(map, ALL_PLANAR_CONFIG).arrays);
    const packed = computeBytecodeBudget(buildMapCairo(map, ALL_PACKED_CONFIG).arrays);
    expect(packed.totalWords).toBeLessThanOrEqual(planar.totalWords);
  });

  it("every array buildMapCairo reports is reflected in the budget total (no silent drops)", () => {
    const map = extractMap(smallWad(), "T4M1");
    const { arrays } = buildMapCairo(map, DEFAULT_EMIT_CONFIG);
    const budget = computeBytecodeBudget(arrays);
    expect(budget.arrays).toHaveLength(arrays.length);
    expect(budget.totalWords).toBe(arrays.reduce((s, a) => s + a.count, 0));
  });
});

describe.skipIf(!hasRealWad)("bytecode budget on real E1M1 (size vs. layout table, task item 3)", () => {
  const wad = Wad.fromBytes(readRealWad());
  const map = extractMap(wad, "E1M1");

  it("all-planar >= recommended mix >= all-packed in total words", () => {
    const allPlanar = computeBytecodeBudget(buildMapCairo(map, ALL_PLANAR_CONFIG).arrays).totalWords;
    const recommended = computeBytecodeBudget(buildMapCairo(map, DEFAULT_EMIT_CONFIG).arrays).totalWords;
    const allPacked = computeBytecodeBudget(buildMapCairo(map, ALL_PACKED_CONFIG).arrays).totalWords;
    expect(allPlanar).toBeGreaterThanOrEqual(recommended);
    expect(recommended).toBeGreaterThanOrEqual(allPacked);
    // Sanity magnitudes: E1M1 is dense enough that even the packed extreme
    // is several thousand words (documented in REPORT-e1m1.md's size table).
    expect(allPacked).toBeGreaterThan(1000);
    expect(allPlanar).toBeGreaterThan(recommended);
  });
});

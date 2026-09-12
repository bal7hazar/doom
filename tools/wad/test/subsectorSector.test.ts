import { describe, expect, it } from "vitest";
import { computeSubsectorSectors, SUBSECTOR_SECTOR_UNRESOLVED } from "../src/derive.js";
import { extractMap } from "../src/mapExtract.js";
import { Wad } from "../src/wad.js";
import { hasRealWad, readRealWad } from "./realWad.js";
import {
  blockmapLump,
  buildWad,
  linedefLump,
  nodeLump,
  rejectLump,
  sectorLump,
  segLump,
  sidedefLump,
  subsectorLump,
  vertexLump,
} from "./testWad.js";
import { NODE_LEAF_FLAG } from "../src/types.js";

/**
 * A tiny two-sector map: one linedef with a front sidedef facing sector 0
 * and a back sidedef facing sector 1, and two subsectors each with a seg
 * on one side of that linedef (direction 0 = front, 1 = back).
 */
function twoSectorWad(): Wad {
  const vertexes = vertexLump([
    [0, 0], [100, 0], [100, 100], [0, 100],
  ]);
  // A single two-sided linedef, referenced by both segs (one per direction).
  const linedefs = linedefLump([{ v1: 0, v2: 1, flags: 4 /* TWO_SIDED */, special: 0, tag: 0, front: 0, back: 1 }]);
  const sidedefs = sidedefLump([
    { xOff: 0, yOff: 0, upper: "-", lower: "-", middle: "-", sector: 0 }, // front -> sector 0
    { xOff: 0, yOff: 0, upper: "-", lower: "-", middle: "-", sector: 1 }, // back -> sector 1
  ]);
  const segs = segLump([
    { v1: 0, v2: 1, angle: 0, linedef: 0, direction: 0, offset: 0 }, // subsector 0: front side -> sector 0
    { v1: 1, v2: 0, angle: 0, linedef: 0, direction: 1, offset: 0 }, // subsector 1: back side -> sector 1
  ]);
  const ssectors = subsectorLump([
    { numSegs: 1, firstSeg: 0 },
    { numSegs: 1, firstSeg: 1 },
  ]);
  const nodes = nodeLump([
    {
      x: 0,
      y: 50,
      dx: 1,
      dy: 0,
      rightBBox: [100, 0, 0, 100],
      leftBBox: [100, 0, 0, 100],
      rightChild: NODE_LEAF_FLAG | 0,
      leftChild: NODE_LEAF_FLAG | 1,
    },
  ]);
  const sectors = sectorLump([
    { floor: 0, ceiling: 128, floorTex: "FLOOR0", ceilTex: "CEIL0", light: 200, special: 0, tag: 0 },
    { floor: 16, ceiling: 112, floorTex: "FLOOR1", ceilTex: "CEIL1", light: 100, special: 7, tag: 0 },
  ]);

  return Wad.fromBuffer(
    buildWad([
      { name: "T2M1", data: Buffer.alloc(0) },
      { name: "THINGS", data: Buffer.alloc(0) },
      { name: "LINEDEFS", data: linedefs },
      { name: "SIDEDEFS", data: sidedefs },
      { name: "VERTEXES", data: vertexes },
      { name: "SEGS", data: segs },
      { name: "SSECTORS", data: ssectors },
      { name: "NODES", data: nodes },
      { name: "SECTORS", data: sectors },
      { name: "REJECT", data: rejectLump(2, []) },
      { name: "BLOCKMAP", data: blockmapLump(0, 0, 1, 1, [[]]) },
    ]),
  );
}

describe("computeSubsectorSectors", () => {
  it("resolves each subsector to the sector its representative seg's sidedef faces (synthetic, direction 0 and 1)", () => {
    const map = extractMap(twoSectorWad(), "T2M1");
    expect(map.subsectorSectors).toEqual([0, 1]);
  });

  it("returns SUBSECTOR_SECTOR_UNRESOLVED (not a throw) for a subsector whose seg references missing LINEDEFS/SIDEDEFS data", () => {
    // Mirrors test/nodes.test.ts's minimal NODES/SSECTORS-only fixture: SEGS
    // reference linedef 0, but LINEDEFS is empty.
    const vertexes = vertexLump([[-10, -10], [10, -10], [0, 10], [50, 50]]);
    const segs = segLump([
      { v1: 0, v2: 1, angle: 0, linedef: 0, direction: 0, offset: 0 },
      { v1: 2, v2: 3, angle: 0, linedef: 0, direction: 0, offset: 0 },
    ]);
    const ssectors = subsectorLump([
      { numSegs: 1, firstSeg: 0 },
      { numSegs: 1, firstSeg: 1 },
    ]);
    const nodes = nodeLump([
      {
        x: 0,
        y: 0,
        dx: 1,
        dy: 0,
        rightBBox: [-10, -10, -10, 10],
        leftBBox: [50, 10, 0, 50],
        rightChild: NODE_LEAF_FLAG | 0,
        leftChild: NODE_LEAF_FLAG | 1,
      },
    ]);
    const wad = Wad.fromBuffer(
      buildWad([
        { name: "T3M1", data: Buffer.alloc(0) },
        { name: "THINGS", data: Buffer.alloc(0) },
        { name: "LINEDEFS", data: Buffer.alloc(0) },
        { name: "SIDEDEFS", data: Buffer.alloc(0) },
        { name: "VERTEXES", data: vertexes },
        { name: "SEGS", data: segs },
        { name: "SSECTORS", data: ssectors },
        { name: "NODES", data: nodes },
        { name: "SECTORS", data: Buffer.alloc(0) },
        { name: "REJECT", data: Buffer.alloc(0) },
        { name: "BLOCKMAP", data: Buffer.alloc(8) },
      ]),
    );
    const map = extractMap(wad, "T3M1");
    expect(map.subsectorSectors).toEqual([SUBSECTOR_SECTOR_UNRESOLVED, SUBSECTOR_SECTOR_UNRESOLVED]);
  });
});

describe.skipIf(!hasRealWad)("computeSubsectorSectors: correctness against SEGS (real E1M1)", () => {
  it("every subsector's SS_SECTOR matches a direct SEGS -> LINEDEF -> SIDEDEF walk, independently reimplemented", () => {
    const wad = Wad.fromBytes(readRealWad());
    const map = extractMap(wad, "E1M1");

    // Independent re-implementation (not calling derive.ts#computeSubsectorSectors)
    // of the same lookup, to actually check the production code rather than
    // itself.
    function expectedSector(ssIndex: number): number {
      const ss = map.subsectors[ssIndex]!;
      const seg = map.segs[ss.firstSeg]!;
      const line = map.linedefs[seg.linedef]!;
      const sidedefIndex = seg.direction === 1 ? line.backSidedef : line.frontSidedef;
      expect(sidedefIndex).not.toBe(0xffff);
      return map.sidedefs[sidedefIndex]!.sector;
    }

    expect(map.subsectorSectors).toHaveLength(map.subsectors.length);
    for (let i = 0; i < map.subsectors.length; i++) {
      expect(map.subsectorSectors[i]).toBe(expectedSector(i));
      expect(map.subsectorSectors[i]).not.toBe(SUBSECTOR_SECTOR_UNRESOLVED);
      expect(map.subsectorSectors[i]!).toBeGreaterThanOrEqual(0);
      expect(map.subsectorSectors[i]!).toBeLessThan(map.sectors.length);
    }
  });

  it("agrees with computeSubsectorSectors called directly with the parsed lumps", () => {
    const wad = Wad.fromBytes(readRealWad());
    const map = extractMap(wad, "E1M1");
    const recomputed = computeSubsectorSectors(map.subsectors, map.segs, map.linedefs, map.sidedefs);
    expect(recomputed).toEqual(map.subsectorSectors);
  });
});

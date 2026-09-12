import { describe, expect, it } from "vitest";
import { computeCellSubsectors, computeSubsectorBBoxes, locateSubsector } from "../src/accelerator.js";
import { extractMap } from "../src/mapExtract.js";
import { NODE_LEAF_FLAG } from "../src/types.js";
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

/** Deterministic PRNG (mulberry32), same as test/predicates.test.ts. */
function mulberry32(seed: number): () => number {
  let a = seed;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** cell (row-major, columns fastest) containing (px, py), or undefined if outside the grid. */
function cellOf(px: number, py: number, originX: number, originY: number, columns: number, rows: number): number | undefined {
  const col = Math.floor((px - originX) / 128);
  const row = Math.floor((py - originY) / 128);
  if (col < 0 || col >= columns || row < 0 || row >= rows) return undefined;
  return row * columns + col;
}

function candidatesFor(spans: { start: number[]; count: number[]; subsectors: number[] }, cell: number): number[] {
  const start = spans.start[cell]!;
  const count = spans.count[cell]!;
  return spans.subsectors.slice(start, start + count);
}

/**
 * Builds a small but non-trivial synthetic map: two square rooms side by
 * side (2 sectors, 2 subsectors) split by one BSP partition, covered by a
 * 4x2 blockmap. Each room is 256 units (2 cells) wide, so column 0 and
 * column 3 are strictly interior to one room (not touching the partition,
 * unlike columns 1/2 whose cells legitimately border both room bboxes).
 */
function twoRoomWad(): Wad {
  // Room A: x in [0,256), room B: x in [256,512); both y in [0,256).
  const vertexes = vertexLump([
    [0, 0], [256, 0], [256, 256], [0, 256], // room A corners (segs 0-3 for subsector 0)
    [256, 0], [512, 0], [512, 256], [256, 256], // room B corners (segs 4-7 for subsector 1)
  ]);
  const segOf = (v1: number, v2: number) => ({ v1, v2, angle: 0, linedef: 0, direction: 0, offset: 0 });
  const segs = segLump([
    segOf(0, 1), segOf(1, 2), segOf(2, 3), segOf(3, 0),
    segOf(4, 5), segOf(5, 6), segOf(6, 7), segOf(7, 4),
  ]);
  const ssectors = subsectorLump([
    { numSegs: 4, firstSeg: 0 },
    { numSegs: 4, firstSeg: 4 },
  ]);
  // Partition (x=256,y=0)->(dx=0,dy=1) is a vertical line pointing "up" (+y).
  // Doom's point-on-side (`right < left ? child[0] : child[1]`, see
  // accelerator.ts#locateSubsector) puts the +x side (room B, x>256) on
  // child[0] ("right" of the direction vector) and the -x side (room A,
  // x<256) on child[1] ("left") - verified against the formula directly
  // below, not assumed.
  const nodes = nodeLump([
    {
      x: 256,
      y: 0,
      dx: 0,
      dy: 1,
      rightBBox: [256, 0, 256, 512], // child[0]: room B (x in [256,512])
      leftBBox: [256, 0, 0, 256], // child[1]: room A (x in [0,256])
      rightChild: NODE_LEAF_FLAG | 1,
      leftChild: NODE_LEAF_FLAG | 0,
    },
  ]);
  const linedefs = linedefLump([{ v1: 0, v2: 1, flags: 0, special: 0, tag: 0, front: 0, back: 0xffff }]);
  const sidedefs = sidedefLump([{ xOff: 0, yOff: 0, upper: "-", lower: "-", middle: "-", sector: 0 }]);
  const sectors = sectorLump([
    { floor: 0, ceiling: 128, floorTex: "FLOOR1", ceilTex: "CEIL1", light: 160, special: 0, tag: 0 },
    { floor: 0, ceiling: 128, floorTex: "FLOOR1", ceilTex: "CEIL1", light: 160, special: 0, tag: 0 },
  ]);

  return Wad.fromBuffer(
    buildWad([
      { name: "T1M1", data: Buffer.alloc(0) },
      { name: "THINGS", data: Buffer.alloc(0) },
      { name: "LINEDEFS", data: linedefs },
      { name: "SIDEDEFS", data: sidedefs },
      { name: "VERTEXES", data: vertexes },
      { name: "SEGS", data: segs },
      { name: "SSECTORS", data: ssectors },
      { name: "NODES", data: nodes },
      { name: "SECTORS", data: sectors },
      { name: "REJECT", data: rejectLump(2, []) },
      // 4 columns x 2 rows of 128-unit cells covers exactly the two rooms.
      { name: "BLOCKMAP", data: blockmapLump(0, 0, 4, 2, Array.from({ length: 8 }, () => [])) },
    ]),
  );
}

describe("R2-A9 accelerator: conservativeness (synthetic map)", () => {
  const map = extractMap(twoRoomWad(), "T1M1");

  it("locateSubsector agrees with the geometric room split", () => {
    expect(locateSubsector(map, 64, 64)).toBe(0); // room A
    expect(locateSubsector(map, 320, 64)).toBe(1); // room B
  });

  it("every sampled point's true subsector is listed in its cell's candidates", () => {
    const { spans } = computeCellSubsectors(map);
    const rng = mulberry32(1);
    let checked = 0;
    for (let i = 0; i < 500; i++) {
      const px = Math.floor(rng() * 512);
      const py = Math.floor(rng() * 256);
      const cell = cellOf(px, py, map.blockmap.originX, map.blockmap.originY, map.blockmap.columns, map.blockmap.rows);
      if (cell === undefined) continue;
      const trueSubsector = locateSubsector(map, px, py);
      expect(candidatesFor(spans, cell)).toContain(trueSubsector);
      checked++;
    }
    expect(checked).toBeGreaterThan(400);
  });

  it("a cell strictly inside one room (not touching the partition) is resolved by a single subsector", () => {
    const { spans, stats } = computeCellSubsectors(map);
    // Cell (0,0) covers x in [0,128), y in [0,128): strictly inside room A,
    // its right edge (x=128) well short of the partition at x=256.
    const cell = cellOf(64, 64, map.blockmap.originX, map.blockmap.originY, map.blockmap.columns, map.blockmap.rows)!;
    expect(candidatesFor(spans, cell)).toEqual([0]);
    // Columns 1/2 border the partition, so their bboxes touch both rooms
    // (conservative, as documented) - only columns 0/3 are unambiguous.
    expect(stats.singleSubsectorCells).toBe(4);
    expect(stats.cells).toBe(8);
  });
});

describe.skipIf(!hasRealWad)("R2-A9 accelerator: conservativeness (real E1M1)", () => {
  const wad = Wad.fromBytes(readRealWad());
  const map = extractMap(wad, "E1M1");
  const { spans, stats } = computeCellSubsectors(map);
  const subsectorBBoxes = computeSubsectorBBoxes(map);

  it("every sampled point's true subsector (BSP ground truth) is listed in its cell's candidates", () => {
    const rng = mulberry32(42);
    let checked = 0;
    let skippedVoid = 0;
    for (let row = 0; row < map.blockmap.rows; row++) {
      for (let col = 0; col < map.blockmap.columns; col++) {
        const cell = row * map.blockmap.columns + col;
        const candidates = candidatesFor(spans, cell);
        // 3 random samples per cell (plus the center) keeps this test fast
        // while still covering all 864 E1M1 cells.
        const samples: [number, number][] = [
          [map.blockmap.originX + col * 128 + 64, map.blockmap.originY + row * 128 + 64],
        ];
        for (let s = 0; s < 3; s++) {
          samples.push([
            map.blockmap.originX + col * 128 + Math.floor(rng() * 128),
            map.blockmap.originY + row * 128 + Math.floor(rng() * 128),
          ]);
        }
        for (const [px, py] of samples) {
          const trueSubsector = locateSubsector(map, px, py);
          // The BSP's partition planes tile the whole infinite plane, so
          // locateSubsector always returns *some* leaf even for a point in
          // the "void" outside the map's actual (non-rectangular) drawn
          // area - a blockmap cell near the map's bounding-box corners can
          // contain such points. The conservativeness proof (see
          // accelerator.ts) only claims a point *inside a subsector's real
          // polygon* is covered; a cheap proxy for "is this actually inside
          // real geometry" is "does the returned subsector's own bbox even
          // contain the point" - if not, this sample is void space, and is
          // skipped rather than asserted on (gameplay never queries void
          // positions: mobjs are always kept inside sector geometry).
          const box = subsectorBBoxes[trueSubsector]!;
          if (px < box.minX || px > box.maxX || py < box.minY || py > box.maxY) {
            skippedVoid++;
            continue;
          }
          expect(candidates, `cell ${cell} (col ${col}, row ${row}), point (${px},${py})`).toContain(trueSubsector);
          checked++;
        }
      }
    }
    // E1M1's actual footprint is a small, irregular fraction of its
    // rectangular bounding box (the blockmap grid covers the box, not the
    // footprint - see REPORT-e1m1.md's low average linedefs/cell), so a
    // sizeable share of uniformly-random samples across the whole grid do
    // land in void space and get skipped above; both counts are still
    // asserted so a regression that broke sampling entirely (e.g. every
    // point resolving to void, or none) would be caught.
    const samplesTotal = map.blockmap.columns * map.blockmap.rows * 4;
    expect(checked).toBeGreaterThan(1000);
    expect(skippedVoid).toBeGreaterThan(0);
    expect(skippedVoid).toBeLessThan(samplesTotal);
  });

  it("reports sane summary statistics", () => {
    expect(stats.cells).toBe(map.blockmap.columns * map.blockmap.rows);
    expect(stats.maxLength).toBeGreaterThan(0);
    expect(stats.maxLength).toBeLessThanOrEqual(map.subsectors.length);
    expect(stats.averageLength).toBeGreaterThan(0);
    expect(stats.averageLength).toBeLessThanOrEqual(stats.maxLength);
    expect(stats.singleSubsectorCells).toBeGreaterThan(0);
    expect(stats.singleSubsectorCells).toBeLessThanOrEqual(stats.cells);
  });
});

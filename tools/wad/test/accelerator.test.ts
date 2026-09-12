import { describe, expect, it } from "vitest";
import { computeCellAccelerator, locateSubsector, locateSubsectorFrom } from "../src/accelerator.js";
import type { CellSubsectorSpans } from "../src/accelerator.js";
import { extractMap, MapData } from "../src/mapExtract.js";
import { BLOCKMAP_UNIT, NODE_LEAF_FLAG } from "../src/types.js";
import { Wad } from "../src/wad.js";
import { describeIfRealWad, readRealWad } from "./realWad.js";
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

/**
 * ## Why the previous version of this test did not catch the seg-bbox bug
 *
 * The accelerator used to derive a subsector's extent from the bounding box
 * of its SEGS' vertices (see git history / REPORT-e1m1.md's old "Method"
 * section). That is unsound: a vanilla node builder emits *no* minisegs, so
 * a subsector's true BSP region routinely reaches far outside the box of
 * its own segs (E1M1 subsector 630's segs span y in [-36, 4]; its region
 * reaches y = -214).
 *
 * The real-E1M1 suite here used to sample random points per cell and skip
 * any point whose *true* subsector didn't contain it by that same seg bbox
 * - the reasoning being "gameplay never queries void space, so treat a
 * point outside its own answer's bbox as void and don't assert on it".
 * That skip test was circular: it used the very data structure under test
 * (the seg bbox) as its own oracle for "is this a real query". Since
 * subsector 630's *true* region extends far outside its seg bbox, every
 * sample landing in that extra region was misclassified as void and
 * discarded - so the accelerator's failure to list subsector 630 for those
 * cells was never actually asserted on. 81 of 200 points in a lattice over
 * the whole map landed in exactly this kind of blind spot.
 *
 * The fix (`accelerator.ts#computeCellAccelerator`) builds the candidate
 * lists (and `CELL_NODE`) from the map's BSP **regions** instead of seg
 * bboxes - see that module's header for the full method, mirrored from
 * `cairo/doom/doom_map/scripts/gen_level.py`. A region-based accelerator
 * has no "void" case at all: the BSP's partitions tile the entire plane, so
 * every point belongs to exactly one subsector's true region, and the test
 * below asserts on a **dense lattice covering every cell**, no skip logic
 * of any kind, checked against an independent ground truth
 * (`locateSubsector`, a plain BSP descent). `legacySegBboxAccelerator`
 * below reproduces the old (buggy) method verbatim, purely so this test
 * file can prove the new dense-lattice check actually fails against it -
 * i.e. that the fixed test would have caught the original bug.
 */

/** cell (row-major, columns fastest) containing (px, py), or undefined if outside the grid. */
function cellOf(px: number, py: number, originX: number, originY: number, columns: number, rows: number): number | undefined {
  const col = Math.floor((px - originX) / BLOCKMAP_UNIT);
  const row = Math.floor((py - originY) / BLOCKMAP_UNIT);
  if (col < 0 || col >= columns || row < 0 || row >= rows) return undefined;
  return row * columns + col;
}

function candidatesFor(spans: CellSubsectorSpans, cell: number): number[] {
  const start = spans.start[cell]!;
  const count = spans.count[cell]!;
  return spans.subsectors.slice(start, start + count);
}

/**
 * Every point of a dense `samplesPerAxis x samplesPerAxis` lattice inside
 * every blockmap cell must have its true subsector (an independent BSP
 * descent via `locateSubsector`) listed in that cell's candidates. Unlike
 * the old test, there is no skip condition: a region-based candidate list
 * is conservative for *every* point in the plane, not just points "inside
 * real geometry".
 */
function assertDenseLatticeIsConservative(map: MapData, spans: CellSubsectorSpans, samplesPerAxis: number): number {
  const { originX, originY, columns, rows } = map.blockmap;
  let checked = 0;
  for (let row = 0; row < rows; row++) {
    for (let col = 0; col < columns; col++) {
      const cell = row * columns + col;
      const candidates = candidatesFor(spans, cell);
      for (let i = 0; i < samplesPerAxis; i++) {
        for (let j = 0; j < samplesPerAxis; j++) {
          const px = originX + col * BLOCKMAP_UNIT + Math.floor(((i + 0.5) * BLOCKMAP_UNIT) / samplesPerAxis);
          const py = originY + row * BLOCKMAP_UNIT + Math.floor(((j + 0.5) * BLOCKMAP_UNIT) / samplesPerAxis);
          const trueSubsector = locateSubsector(map, px, py);
          expect(candidates, `cell ${cell} (col ${col}, row ${row}), point (${px},${py})`).toContain(trueSubsector);
          checked++;
        }
      }
    }
  }
  return checked;
}

// ---------------------------------------------------------------------------
// The regressed (pre-fix) seg-bbox method, reproduced only so this test file
// can demonstrate the dense-lattice check above actually fails against it.
// ---------------------------------------------------------------------------

interface BBox2D {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

function legacySubsectorSegBBoxes(map: MapData): BBox2D[] {
  return map.subsectors.map((ss) => {
    const box: BBox2D = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
    for (let i = 0; i < ss.numSegs; i++) {
      const seg = map.segs[ss.firstSeg + i];
      if (!seg) continue;
      for (const vi of [seg.startVertex, seg.endVertex]) {
        const v = map.vertexes[vi];
        if (!v) continue;
        if (v.x < box.minX) box.minX = v.x;
        if (v.x > box.maxX) box.maxX = v.x;
        if (v.y < box.minY) box.minY = v.y;
        if (v.y > box.maxY) box.maxY = v.y;
      }
    }
    return box;
  });
}

/** Verbatim reproduction of the accelerator's original (non-conservative) method. */
function legacySegBboxAccelerator(map: MapData): { spans: CellSubsectorSpans } {
  const boxes = legacySubsectorSegBBoxes(map);
  const { originX, originY, columns, rows } = map.blockmap;
  const start: number[] = [];
  const count: number[] = [];
  const subsectors: number[] = [];
  const intersects = (a: BBox2D, b: BBox2D) => a.minX <= b.maxX && a.maxX >= b.minX && a.minY <= b.maxY && a.maxY >= b.minY;
  for (let row = 0; row < rows; row++) {
    const cellMinY = originY + row * BLOCKMAP_UNIT;
    const cellMaxY = cellMinY + BLOCKMAP_UNIT;
    for (let col = 0; col < columns; col++) {
      const cellMinX = originX + col * BLOCKMAP_UNIT;
      const cellMaxX = cellMinX + BLOCKMAP_UNIT;
      const cellBox: BBox2D = { minX: cellMinX, maxX: cellMaxX, minY: cellMinY, maxY: cellMaxY };
      start.push(subsectors.length);
      let n = 0;
      for (let s = 0; s < boxes.length; s++) {
        if (intersects(boxes[s]!, cellBox)) {
          subsectors.push(s);
          n++;
        }
      }
      count.push(n);
    }
  }
  return { spans: { start, count, subsectors } };
}

/**
 * Builds a small but non-trivial synthetic map: two square rooms side by
 * side (2 sectors, 2 subsectors) split by one BSP partition, covered by a
 * 4x2 blockmap. Each room is 256 units (2 cells) wide.
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
  // Partition (x=256,y=0)->(dx=0,dy=1) is a vertical line at x=256, extending
  // over all y. Doom's point-on-side (`right < left ? child[0] : child[1]`,
  // see accelerator.ts#pointSide) puts the +x side (room B, x>256) on
  // child[0] ("right") and the -x side, including the boundary x=256 itself
  // (room A), on child[1] ("left") - so room A's true BSP region is the
  // closed half-plane x<=256, room B's the open half-plane x>256.
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

  it("dense lattice: every sampled point's true subsector is listed in its cell's candidates", () => {
    const { spans } = computeCellAccelerator(map);
    const checked = assertDenseLatticeIsConservative(map, spans, 8);
    expect(checked).toBe(map.blockmap.columns * map.blockmap.rows * 8 * 8);
  });

  it("columns not touching the partition resolve to a single subsector; the straddling column lists both", () => {
    const { spans, stats } = computeCellAccelerator(map);
    const cellAt = (col: number) => cellOf(col * 128 + 1, 1, map.blockmap.originX, map.blockmap.originY, map.blockmap.columns, map.blockmap.rows)!;
    // Column 0 (x in [0,128)) and column 1 (x in [128,256)) both lie
    // entirely in room A's closed region x<=256: single subsector 0.
    expect(candidatesFor(spans, cellAt(0))).toEqual([0]);
    expect(candidatesFor(spans, cellAt(1))).toEqual([0]);
    // Column 2 (x in [256,384)) straddles the partition at x=256: both.
    expect(candidatesFor(spans, cellAt(2))).toEqual([0, 1]);
    // Column 3 (x in [384,512)) lies entirely in room B's open region x>256.
    expect(candidatesFor(spans, cellAt(3))).toEqual([1]);
    expect(stats.cells).toBe(8);
    expect(stats.singleSubsectorCells).toBe(6); // 3 unambiguous columns x 2 rows
    expect(stats.maxLength).toBe(2);
    expect(stats.emptyCells).toBe(0);
  });

  it("CELL_NODE reproduces a root descent exactly, from every cell's lattice point", () => {
    const { cellNode } = computeCellAccelerator(map);
    const { originX, originY, columns, rows } = map.blockmap;
    for (let row = 0; row < rows; row++) {
      for (let col = 0; col < columns; col++) {
        const cell = row * columns + col;
        for (let i = 0; i < 4; i++) {
          for (let j = 0; j < 4; j++) {
            const px = originX + col * BLOCKMAP_UNIT + Math.floor(((i + 0.5) * BLOCKMAP_UNIT) / 4);
            const py = originY + row * BLOCKMAP_UNIT + Math.floor(((j + 0.5) * BLOCKMAP_UNIT) / 4);
            expect(locateSubsectorFrom(map, cellNode[cell]!, px, py)).toBe(locateSubsector(map, px, py));
          }
        }
      }
    }
  });

});

describeIfRealWad("R2-A9 accelerator: conservativeness (real E1M1)", () => {
  const wad = Wad.fromBytes(readRealWad());
  const map = extractMap(wad, "E1M1");
  const { spans, stats, cellNode } = computeCellAccelerator(map);

  it("dense lattice: every sampled point's true subsector is listed in its cell's candidates, no skip logic", () => {
    // 6x6 = 36 points per cell, every one of the 864 E1M1 cells: dense and
    // exhaustive, unlike the old random+skip sampling this replaces.
    const checked = assertDenseLatticeIsConservative(map, spans, 6);
    expect(checked).toBe(map.blockmap.columns * map.blockmap.rows * 36);
  });

  it("CELL_NODE reproduces a root descent exactly, from a lattice of points per cell", () => {
    const { originX, originY, columns, rows } = map.blockmap;
    for (let row = 0; row < rows; row++) {
      for (let col = 0; col < columns; col++) {
        const cell = row * columns + col;
        for (let i = 0; i < 3; i++) {
          for (let j = 0; j < 3; j++) {
            const px = originX + col * BLOCKMAP_UNIT + Math.floor(((i + 0.5) * BLOCKMAP_UNIT) / 3);
            const py = originY + row * BLOCKMAP_UNIT + Math.floor(((j + 0.5) * BLOCKMAP_UNIT) / 3);
            expect(locateSubsectorFrom(map, cellNode[cell]!, px, py)).toBe(locateSubsector(map, px, py));
          }
        }
      }
    }
  });

  it(
    "reproduces the exact original bug report: the legacy seg-bbox method omits subsector 630 " +
      "for cells whose region reaches it, which the fixed dense-lattice check catches",
    () => {
      const legacy = legacySegBboxAccelerator(map);
      // Find a point whose true (BSP ground-truth) subsector is 630 but
      // which lies outside subsector 630's own seg bbox (the module header
      // and REPORT-e1m1.md document 630's segs spanning y in [-36,4] while
      // its region reaches y = -214) - i.e. exactly the kind of point the
      // old test's circular "is this real geometry" filter used to discard.
      const box = legacySubsectorSegBBoxes(map)[630]!;
      let violation: { cell: number; x: number; y: number } | undefined;
      const { originX, originY, columns, rows } = map.blockmap;
      outer: for (let row = 0; row < rows && !violation; row++) {
        for (let col = 0; col < columns; col++) {
          for (let i = 0; i < 6 && !violation; i++) {
            for (let j = 0; j < 6; j++) {
              const x = originX + col * BLOCKMAP_UNIT + Math.floor(((i + 0.5) * BLOCKMAP_UNIT) / 6);
              const y = originY + row * BLOCKMAP_UNIT + Math.floor(((j + 0.5) * BLOCKMAP_UNIT) / 6);
              if (locateSubsector(map, x, y) !== 630) continue;
              if (x >= box.minX && x <= box.maxX && y >= box.minY && y <= box.maxY) continue; // inside the seg bbox: not a counterexample
              const cell = cellOf(x, y, originX, originY, columns, rows);
              if (cell === undefined) continue;
              if (!candidatesFor(legacy.spans, cell).includes(630)) {
                violation = { cell, x, y };
                break outer;
              }
            }
          }
        }
      }
      expect(violation, "expected at least one lattice point where the legacy seg-bbox method omits subsector 630").toBeDefined();
      // And the fixed, region-based accelerator does list it there.
      expect(candidatesFor(spans, violation!.cell)).toContain(630);
    },
  );

  it("reports sane summary statistics, including the D22 descent-depth cut", () => {
    expect(stats.cells).toBe(map.blockmap.columns * map.blockmap.rows);
    expect(stats.maxLength).toBeGreaterThan(0);
    expect(stats.maxLength).toBeLessThanOrEqual(map.subsectors.length);
    expect(stats.averageLength).toBeGreaterThan(0);
    expect(stats.averageLength).toBeLessThanOrEqual(stats.maxLength);
    expect(stats.singleSubsectorCells).toBeGreaterThan(0);
    expect(stats.singleSubsectorCells).toBeLessThanOrEqual(stats.cells);
    // A region-based accelerator never has "empty" cells: the BSP tiles the
    // whole plane, so every cell's region always meets at least one subsector.
    expect(stats.emptyCells).toBe(0);
    // docs/DECISIONS.md D22's headline numbers for E1M1 (measured
    // independently by cairo/doom/doom_map/scripts/gen_level.py against the
    // same WAD data - see REPORT-e1m1.md and that crate's README for the
    // cross-check).
    expect(stats.totalEntries).toBe(3565);
    expect(stats.averageLength).toBeCloseTo(4.13, 2);
    expect(stats.maxLength).toBe(21);
    expect(stats.meanDepthFromRoot).toBeGreaterThan(stats.meanDepthFromCellNode);
    expect(stats.meanDepthFromRoot).toBeCloseTo(11.36, 1);
    expect(stats.meanDepthFromCellNode).toBeCloseTo(4.15, 1);
  });
});

/**
 * Cell -> subsector accelerator (RISKS.md R2-A9, docs/spikes/S1.md §7
 * "bsp"). S1 measured `sector_at` (a full BSP descent) at ~1 014 steps,
 * 35% of an optimized tic, and showed that a *partial* shortcut (treat a
 * blockmap cell as uniform only when no linedef crosses it) is a net
 * pessimization on a real playthrough because the shortcut fails most of
 * the time and the failed test still costs ~130 steps (§5.7). S1's
 * recommendation is a *complete* accelerator that answers in one lookup in
 * every cell: for each blockmap cell, the list of subsectors whose
 * geometry can overlap that cell.
 *
 * Method (documented per the task, and proved conservative by
 * `test/accelerator.test.ts`): a subsector is a convex polygon whose
 * boundary is exactly its SEGS (real wall segs and BSP-partition segs
 * alike - the vanilla node builder always closes the polygon with SEGS
 * entries, so no other data is needed). This module computes each
 * subsector's axis-aligned bounding box as the union of its segs' vertex
 * coordinates, then lists a subsector for a cell whenever the two boxes
 * intersect.
 *
 * Why this is conservative (never omits the true subsector of any point in
 * the cell): for *any* polygon (convex or not), every point inside it is a
 * convex combination of its vertices, so its x and y coordinates each lie
 * between the min and max of the vertex coordinates - i.e. the polygon is
 * always a subset of its own vertex bounding box. So if point `p` lies in
 * subsector `S` and in blockmap cell `C`, then `p` is in `bbox(S)` (by the
 * fact above) and in `bbox(C)` (by construction), so `bbox(S)` and
 * `bbox(C)` share the point `p` and therefore intersect - meaning this
 * module's intersection test will include `S` in cell `C`'s list. The
 * bbox is an over-approximation of the polygon, so the list can (and does,
 * see the report) include subsectors that don't actually reach the cell;
 * it can never omit the true one. `SEGS` are not part of the Cairo output
 * (dropped to shrink the bytecode, R2-A12); this accelerator is exactly
 * the runtime replacement for the BSP-descent + SEGS lookup that used to
 * require them.
 */

import { MapData } from "./mapExtract.js";
import { BLOCKMAP_UNIT, NODE_LEAF_FLAG } from "./types.js";

export interface BBox2D {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

function emptyBBox(): BBox2D {
  return { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
}

function extend(box: BBox2D, x: number, y: number): void {
  if (x < box.minX) box.minX = x;
  if (x > box.maxX) box.maxX = x;
  if (y < box.minY) box.minY = y;
  if (y > box.maxY) box.maxY = y;
}

/** Per-subsector bounding box, computed as the union of its SEGS' vertex coordinates. */
export function computeSubsectorBBoxes(map: MapData): BBox2D[] {
  return map.subsectors.map((ss) => {
    const box = emptyBBox();
    for (let i = 0; i < ss.numSegs; i++) {
      const seg = map.segs[ss.firstSeg + i];
      if (!seg) continue;
      const v1 = map.vertexes[seg.startVertex];
      const v2 = map.vertexes[seg.endVertex];
      if (v1) extend(box, v1.x, v1.y);
      if (v2) extend(box, v2.x, v2.y);
    }
    return box;
  });
}

function bboxesIntersect(a: BBox2D, b: BBox2D): boolean {
  return a.minX <= b.maxX && a.maxX >= b.minX && a.minY <= b.maxY && a.maxY >= b.minY;
}

export interface CellSubsectorSpans {
  /** Per cell (row-major, columns fastest, matching Blockmap.cells): start offset into `subsectors`. */
  start: number[];
  /** Per cell: number of candidate subsectors. */
  count: number[];
  /** Flattened candidate subsector indices, `count[cell]` of them starting at `start[cell]`. */
  subsectors: number[];
}

export interface AcceleratorStats {
  cells: number;
  totalEntries: number;
  averageLength: number;
  maxLength: number;
  singleSubsectorCells: number;
  emptyCells: number;
}

/**
 * Builds the per-cell candidate-subsector spans and their summary
 * statistics (average/max list length, number of cells resolved by a
 * single subsector - the quantities the task and REPORT-e1m1.md ask for).
 */
export function computeCellSubsectors(map: MapData): { spans: CellSubsectorSpans; stats: AcceleratorStats } {
  const boxes = computeSubsectorBBoxes(map);
  const { originX, originY, columns, rows } = map.blockmap;

  const start: number[] = [];
  const count: number[] = [];
  const subsectors: number[] = [];

  let maxLength = 0;
  let singleSubsectorCells = 0;
  let emptyCells = 0;

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
        if (bboxesIntersect(boxes[s]!, cellBox)) {
          subsectors.push(s);
          n++;
        }
      }
      count.push(n);
      if (n > maxLength) maxLength = n;
      if (n === 1) singleSubsectorCells++;
      if (n === 0) emptyCells++;
    }
  }

  const cells = columns * rows;
  const stats: AcceleratorStats = {
    cells,
    totalEntries: subsectors.length,
    averageLength: cells > 0 ? subsectors.length / cells : 0,
    maxLength,
    singleSubsectorCells,
    emptyCells,
  };
  return { spans: { start, count, subsectors }, stats };
}

/**
 * Ground truth used only for tests: finds the subsector containing (px,py)
 * by descending the BSP tree exactly as the game engine's
 * `R_PointInSubsector` does (mirrors `spikes/s1/tools/extract.py`'s
 * `ss_of`). Defined for every point in the plane (BSP partitions extend to
 * infinity), used here to prove the accelerator never omits the true
 * subsector for a sampled point.
 */
export function locateSubsector(map: MapData, px: number, py: number): number {
  if (map.nodes.length === 0) {
    throw new Error("locateSubsector: map has no NODES");
  }
  let child = (map.nodes.length - 1) | 0;
  // The root is the last NODES entry (vanilla convention); walk down until
  // we hit a leaf (subsector) child.
  while ((child & NODE_LEAF_FLAG) === 0) {
    const node = map.nodes[child];
    if (!node) throw new Error(`locateSubsector: node index ${child} out of range`);
    const dx = px - node.x;
    const dy = py - node.y;
    const left = node.dy * dx;
    const right = dy * node.dx;
    child = right < left ? node.rightChild : node.leftChild;
  }
  return child & 0x7fff;
}

/**
 * Cell -> subsector accelerator (RISKS.md R2-A9, docs/spikes/S1.md §7
 * "bsp", docs/DECISIONS.md D22). S1 measured `sector_at` (a full BSP
 * descent) at ~1 014 steps, 35% of an optimized tic, and showed that a
 * *partial* shortcut (treat a blockmap cell as uniform only when no linedef
 * crosses it) is a net pessimization on a real playthrough because the
 * shortcut fails most of the time and the failed test still costs ~130
 * steps (§5.7). S1's recommendation is a *complete* accelerator that
 * answers in one lookup in every cell.
 *
 * ## History: the seg-bbox method was not conservative
 *
 * The original implementation derived a subsector's extent from the
 * bounding box of its SEGS' vertices, on the argument that a vanilla node
 * builder always closes a subsector's polygon with SEGS (wall segs and
 * internal partition segs alike) - so the polygon, and hence its region,
 * would be a subset of that bbox. **That argument's premise is false**: a
 * vanilla node builder emits *no* minisegs at all (every one of E1M1's 2 057
 * segs references a real linedef), so a subsector's actual BSP *region*
 * (the intersection of half-planes on the path from the root) routinely
 * extends far beyond the box of its own segs - e.g. E1M1 subsector 630 has
 * two parallel segs spanning y in [-36, 4] while its region reaches
 * y = -214. On a 200-point lattice over E1M1, 81 of 200 points landed in a
 * cell whose seg-bbox candidate list omitted the subsector a real BSP
 * descent (`R_PointInSubsector`) returned for them - i.e. the list was not
 * conservative for the query the physics engine actually makes.
 *
 * The property test that should have caught this (`test/accelerator.test.ts`)
 * did not, because its only check against the real WAD skipped any sampled
 * point whose true subsector didn't contain it *by that same seg bbox* -
 * a circular "is this real geometry" filter built from the very data being
 * tested. Since subsector 630's region reaches far outside its own seg
 * bbox, every sample landing in that extra region was misclassified as
 * "void" and discarded before the conservativeness assertion ever ran on
 * it. See `test/accelerator.test.ts` for the fixed test (a dense lattice
 * over every cell, checked against an independent BSP descent, with no
 * skip logic at all - a region-based accelerator has no "void": the BSP's
 * partitions tile the entire plane, so every point belongs to exactly one
 * subsector's true region).
 *
 * ## The fix: build from BSP regions, not seg bboxes
 *
 * This module now mirrors `cairo/doom/doom_map/scripts/gen_level.py`
 * exactly (see that file's `collect_subsectors`/`cell_start_nodes`, and
 * `cairo/doom/doom_map/README.md`'s "R2-A9, and a correction to the WAD
 * tool's accelerator"): a subsector's region is reconstructed by
 * descending the BSP tree, recursing into *both* children of a node
 * whenever the query box's four corners fall on both sides of that node's
 * partition (a partition is a linear function, so its sign over an
 * axis-aligned box is decided entirely by the box's own corners - no
 * clipping or polygon reconstruction is needed, unlike
 * `client/src/map/bsp.ts#buildSubsectorPolygons`, which this module does
 * *not* import, to keep `tools/wad` independent of the client). That is
 * exact (a subsector is listed for a cell iff its region meets the cell),
 * hence conservative, and it needs no SEGS at all.
 *
 * The same descent gives the second half of R2-A9 for free: `CELL_NODE`,
 * the deepest node whose region *contains* the whole cell (the descent
 * stops as soon as the box straddles a partition instead of always
 * reaching a leaf). Starting a point-location descent there instead of at
 * the root answers exactly what a descent from the root answers, for every
 * point of that cell, after skipping every level both the cell and its
 * true subsector agree on - docs/DECISIONS.md D22 measured this cutting
 * the mean BSP descent from 11.36 to 4.15 levels on E1M1, a 45% cut on
 * P_TryMove's cost according to spikes/S1.md §5.6.
 *
 * D22 also removed the R2-A9 candidate-list arrays from `doom_map`'s own
 * compiled level (`CELL_NODE` alone reproduces a full descent's answer
 * exactly, so the candidate list added nothing there); `tools/wad`'s Cairo
 * emission keeps them available but **off by default** for the same reason
 * (`emitConfig.ts#DEFAULT_EMIT_CONFIG.emitAccelCandidates`). They stay
 * useful here as an O(1)-candidates alternative for tooling/tests that
 * don't want a BSP descent at all, and are exercised by
 * `test/accelerator.test.ts`'s conservativeness proof either way.
 */

import { MapData } from "./mapExtract.js";
import { BLOCKMAP_UNIT, Node, NODE_LEAF_FLAG } from "./types.js";

export interface CellSubsectorSpans {
  /** Per cell (row-major, columns fastest, matching Blockmap.cells): start offset into `subsectors`. */
  start: number[];
  /** Per cell: number of candidate subsectors. */
  count: number[];
  /** Flattened candidate subsector indices, `count[cell]` of them starting at `start[cell]`, sorted ascending. */
  subsectors: number[];
}

export interface AcceleratorStats {
  cells: number;
  totalEntries: number;
  averageLength: number;
  maxLength: number;
  singleSubsectorCells: number;
  /**
   * Always 0 for the region-based accelerator: the BSP's partitions tile
   * the whole plane, so every cell's region always meets at least one
   * subsector. Kept for report/API compatibility with the old bbox-based
   * accelerator, where this counted cells outside every subsector's seg
   * bbox.
   */
  emptyCells: number;
  /** Mean BSP descent depth from the root, over each cell's center point. */
  meanDepthFromRoot: number;
  /** Mean BSP descent depth from that cell's `CELL_NODE`, over each cell's center point. */
  meanDepthFromCellNode: number;
}

export interface CellAccelerator {
  spans: CellSubsectorSpans;
  stats: AcceleratorStats;
  /**
   * Per cell: the deepest node id (native WAD form - a node index, or a
   * leaf subsector id with `NODE_LEAF_FLAG` set) whose BSP region contains
   * the whole cell. `cellNodeSubsectorAt` starts a descent there instead of
   * at the root and reaches exactly the same leaf.
   */
  cellNode: number[];
}

/** 0 = front (right child), 1 = back (left child); a point exactly on the partition is back. Mirrors `R_PointOnSide`/`gen_level.py#node_side`. */
function pointSide(node: Node, x: number, y: number): 0 | 1 {
  const left = node.dy * (x - node.x);
  const right = (y - node.y) * node.dx;
  return right < left ? 0 : 1;
}

/** Doom's `children[0]` is the right (front, side 0) child. */
function childOf(node: Node, side: 0 | 1): number {
  return side === 0 ? node.rightChild : node.leftChild;
}

/**
 * The distinct sides of `node`'s partition that the box's four corners fall
 * on. A partition is a linear function, so its extremes over an
 * axis-aligned box are attained at the corners: one element means the whole
 * box is on that side, two that it straddles the partition.
 */
function boxSides(node: Node, x0: number, y0: number, x1: number, y1: number): Set<0 | 1> {
  return new Set<0 | 1>([
    pointSide(node, x0, y0),
    pointSide(node, x1, y0),
    pointSide(node, x0, y1),
    pointSide(node, x1, y1),
  ]);
}

/** Every subsector whose BSP **region** meets the box - exactly (see the module header). */
function collectSubsectors(
  nodes: Node[],
  cur: number,
  x0: number,
  y0: number,
  x1: number,
  y1: number,
  out: Set<number>,
): void {
  if ((cur & NODE_LEAF_FLAG) !== 0) {
    out.add(cur & 0x7fff);
    return;
  }
  const node = nodes[cur];
  if (!node) return;
  for (const side of boxSides(node, x0, y0, x1, y1)) {
    collectSubsectors(nodes, childOf(node, side), x0, y0, x1, y1, out);
  }
}

/**
 * The deepest node id whose region contains the whole box: descend for as
 * long as the box lies entirely on one side of the current node, stop the
 * moment it straddles (or a leaf is reached).
 */
function cellNodeFor(nodes: Node[], root: number, x0: number, y0: number, x1: number, y1: number): number {
  let cur = root;
  while ((cur & NODE_LEAF_FLAG) === 0) {
    const node = nodes[cur];
    if (!node) break;
    const sides = boxSides(node, x0, y0, x1, y1);
    if (sides.size !== 1) break;
    const [side] = sides;
    cur = childOf(node, side!);
  }
  return cur;
}

/** Number of BSP levels walked from `start` to the leaf containing `(x, y)`. */
function descentDepth(nodes: Node[], start: number, x: number, y: number): number {
  let cur = start;
  let depth = 0;
  while ((cur & NODE_LEAF_FLAG) === 0) {
    const node = nodes[cur];
    if (!node) break;
    cur = childOf(node, pointSide(node, x, y));
    depth++;
  }
  return depth;
}

/**
 * Builds both halves of R2-A9 from the map's BSP regions (see the module
 * header for the method and why it replaces the old seg-bbox approach):
 * the per-cell candidate-subsector spans (`CellSubsectorSpans`, exact and
 * therefore conservative), the deepest containing node per cell
 * (`CELL_NODE`), their summary statistics, and the mean BSP descent depth
 * from the root vs. from `CELL_NODE` (docs/DECISIONS.md D22).
 */
export function computeCellAccelerator(map: MapData): CellAccelerator {
  const { nodes } = map;
  const { originX, originY, columns, rows } = map.blockmap;
  const unit = BLOCKMAP_UNIT;
  // A map with no BSP nodes at all is a degenerate single-subsector map
  // (mirrors client/src/map/bsp.ts's own degenerate case): every cell's
  // region is that one subsector, reachable in zero descent steps.
  const root = nodes.length === 0 ? NODE_LEAF_FLAG | 0 : nodes.length - 1;

  const start: number[] = [];
  const count: number[] = [];
  const subsectors: number[] = [];
  const cellNode: number[] = [];

  let maxLength = 0;
  let singleSubsectorCells = 0;
  let emptyCells = 0;
  let depthRootSum = 0;
  let depthCellNodeSum = 0;

  for (let row = 0; row < rows; row++) {
    const y0 = originY + row * unit;
    const y1 = y0 + unit;
    for (let col = 0; col < columns; col++) {
      const x0 = originX + col * unit;
      const x1 = x0 + unit;

      const found = new Set<number>();
      collectSubsectors(nodes, root, x0, y0, x1, y1, found);
      const sorted = [...found].sort((a, b) => a - b);

      start.push(subsectors.length);
      for (const s of sorted) subsectors.push(s);
      count.push(sorted.length);

      if (sorted.length > maxLength) maxLength = sorted.length;
      if (sorted.length === 1) singleSubsectorCells++;
      if (sorted.length === 0) emptyCells++;

      const cn = cellNodeFor(nodes, root, x0, y0, x1, y1);
      cellNode.push(cn);

      const mx = x0 + unit / 2;
      const my = y0 + unit / 2;
      depthRootSum += descentDepth(nodes, root, mx, my);
      depthCellNodeSum += descentDepth(nodes, cn, mx, my);
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
    meanDepthFromRoot: cells > 0 ? depthRootSum / cells : 0,
    meanDepthFromCellNode: cells > 0 ? depthCellNodeSum / cells : 0,
  };

  return { spans: { start, count, subsectors }, stats, cellNode };
}

/**
 * Ground truth used by tests and by the accelerator itself: finds the
 * subsector containing (px,py) by descending the BSP tree exactly as the
 * game engine's `R_PointInSubsector` does (mirrors
 * `cairo/doom/doom_map/scripts/gen_level.py#locate_subsector`). Defined for
 * every point in the plane (BSP partitions extend to infinity, so there is
 * no "void" case), used here to prove the accelerator never omits the true
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
    child = childOf(node, pointSide(node, px, py));
  }
  return child & 0x7fff;
}

/**
 * Same answer as `locateSubsector`, but starting the descent at `cellNode`
 * instead of the root - what a Cairo consumer does with `CELL_NODE`. Used
 * by tests to prove `CELL_NODE` always reproduces a root descent exactly.
 */
export function locateSubsectorFrom(map: MapData, cellNode: number, px: number, py: number): number {
  let child = cellNode;
  while ((child & NODE_LEAF_FLAG) === 0) {
    const node = map.nodes[child];
    if (!node) throw new Error(`locateSubsectorFrom: node index ${child} out of range`);
    child = childOf(node, pointSide(node, px, py));
  }
  return child & 0x7fff;
}

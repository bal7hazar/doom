import { NODE_LEAF_FLAG, NO_SIDEDEF, type LevelJson } from "./level.js";

export interface Point2 {
  x: number;
  y: number;
}

export interface SubsectorPolygon {
  subsector: number;
  sector: number;
  /** Convex, counter-clockwise in map coordinates (x right, y up). */
  points: Point2[];
}

/**
 * Rebuilds the exact convex polygon of every subsector by walking the BSP tree
 * and clipping a starting rectangle against each partition line.
 *
 * Why not earcut over sector edge loops? Because `SSECTORS` does not store the
 * implicit edges the node builder introduced: a subsector's segs only cover the
 * parts of its boundary that lie on real linedefs, so the polygon is *open* and
 * cannot be triangulated directly. Reconstructing it from the tree is both
 * exact and cheap - the leaf region is, by construction of the BSP, the
 * intersection of the half-planes on the path from the root - and it yields
 * convex polygons, so triangulation is a fan and needs no library at all.
 * That is the "or equivalent" in "earcut or equivalent", with one fewer
 * dependency and no ear-clipping robustness questions on 182 sectors whose
 * boundaries include unclosed loops and self-touching vertices.
 *
 * Sidedness follows `R_PointOnSide` exactly:
 *
 *     s(p) = node.dy * (p.x - node.x) - node.dx * (p.y - node.y)
 *     s(p) > 0  =>  right (front) child, otherwise left (back) child
 *
 * so the right child gets `s >= 0` and the left child `s <= 0`; points exactly
 * on the line belong to both polygons, which is what makes adjacent subsectors
 * share an edge with no crack between them.
 */
export function buildSubsectorPolygons(level: LevelJson): SubsectorPolygon[] {
  const out: SubsectorPolygon[] = new Array(level.subsectors.length);
  const bb = level.boundingBox;
  // A margin keeps the starting rectangle strictly outside the map, so no
  // partition line is ever collinear with a starting edge.
  const m = 256;
  const root: Point2[] = [
    { x: bb.minX - m, y: bb.minY - m },
    { x: bb.maxX + m, y: bb.minY - m },
    { x: bb.maxX + m, y: bb.maxY + m },
    { x: bb.minX - m, y: bb.maxY + m },
  ];

  if (level.nodes.length === 0) {
    // Degenerate single-subsector map: nothing to clip.
    if (level.subsectors.length === 1) {
      out[0] = { subsector: 0, sector: subsectorSector(level, 0), points: root };
    }
    return out.filter(Boolean);
  }

  const visit = (child: number, poly: Point2[]): void => {
    if (poly.length < 3) return;
    if ((child & NODE_LEAF_FLAG) !== 0) {
      const ss = child & 0x7fff;
      if (ss < level.subsectors.length) {
        out[ss] = { subsector: ss, sector: subsectorSector(level, ss), points: poly };
      }
      return;
    }
    const node = level.nodes[child];
    if (!node) return;
    visit(node.rightChild, clipHalfPlane(poly, node, +1));
    visit(node.leftChild, clipHalfPlane(poly, node, -1));
  };

  visit(level.nodes.length - 1, root);
  return out.filter(Boolean);
}

/** `sign > 0` keeps `s(p) >= 0` (right/front side), `sign < 0` keeps `s(p) <= 0`. */
function clipHalfPlane(
  poly: Point2[],
  node: { x: number; y: number; dx: number; dy: number },
  sign: number,
): Point2[] {
  const s = (p: Point2): number => sign * (node.dy * (p.x - node.x) - node.dx * (p.y - node.y));
  const out: Point2[] = [];
  for (let i = 0; i < poly.length; i++) {
    const a = poly[i]!;
    const b = poly[(i + 1) % poly.length]!;
    const sa = s(a);
    const sb = s(b);
    if (sa >= 0) out.push(a);
    if ((sa > 0 && sb < 0) || (sa < 0 && sb > 0)) {
      const t = sa / (sa - sb);
      out.push({ x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y) });
    }
  }
  return dedupe(out);
}

/**
 * Drops points that coincide with their predecessor. Sutherland-Hodgman on a
 * half-plane that just grazes a vertex emits it twice, and a duplicated vertex
 * makes the fan produce zero-area triangles.
 */
function dedupe(points: Point2[]): Point2[] {
  const out: Point2[] = [];
  for (const p of points) {
    const last = out[out.length - 1];
    if (last && Math.abs(last.x - p.x) < 1e-6 && Math.abs(last.y - p.y) < 1e-6) continue;
    out.push(p);
  }
  const first = out[0];
  const last = out[out.length - 1];
  if (out.length > 1 && first && last && Math.abs(first.x - last.x) < 1e-6 && Math.abs(first.y - last.y) < 1e-6) {
    out.pop();
  }
  return out;
}

/**
 * The sector a subsector belongs to: the front sector of its first seg, where
 * "front" follows the seg's direction bit (0 = same direction as the linedef).
 */
export function subsectorSector(level: LevelJson, subsectorIndex: number): number {
  const ss = level.subsectors[subsectorIndex];
  if (!ss || ss.numSegs === 0) return 0;
  const seg = level.segs[ss.firstSeg];
  if (!seg) return 0;
  const line = level.linedefs[seg.linedef];
  if (!line) return 0;
  const sideIndex = seg.direction === 0 ? line.frontSidedef : line.backSidedef;
  if (sideIndex === NO_SIDEDEF) return 0;
  return level.sidedefs[sideIndex]?.sector ?? 0;
}

/** Signed area (positive = counter-clockwise). Used to orient fans consistently. */
export function signedArea(points: Point2[]): number {
  let a = 0;
  for (let i = 0; i < points.length; i++) {
    const p = points[i]!;
    const q = points[(i + 1) % points.length]!;
    a += p.x * q.y - q.x * p.y;
  }
  return a / 2;
}

/**
 * Triangulates a convex polygon as a fan. Returns flat index triples into
 * `points`; a polygon of fewer than 3 points yields nothing.
 */
export function fanTriangulate(points: Point2[]): number[] {
  if (points.length < 3) return [];
  const out: number[] = [];
  for (let i = 1; i + 1 < points.length; i++) out.push(0, i, i + 1);
  return out;
}

/** Point-in-subsector lookup down the BSP, the same walk `R_PointInSubsector` does. */
export function pointInSubsector(level: LevelJson, x: number, y: number): number {
  if (level.nodes.length === 0) return 0;
  let node = level.nodes.length - 1;
  for (;;) {
    if ((node & NODE_LEAF_FLAG) !== 0) return node & 0x7fff;
    const n = level.nodes[node];
    if (!n) return 0;
    const s = n.dy * (x - n.x) - n.dx * (y - n.y);
    node = s > 0 ? n.rightChild : n.leftChild;
  }
}

/** The sector containing a point, via the BSP. */
export function pointInSector(level: LevelJson, x: number, y: number): number {
  return subsectorSector(level, pointInSubsector(level, x, y));
}

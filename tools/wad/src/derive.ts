import { Linedef, Seg, Sidedef, Subsector, Vertex } from "./types.js";

export interface MapBoundingBox {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

export function computeBoundingBox(vertexes: Vertex[]): MapBoundingBox {
  if (vertexes.length === 0) {
    throw new Error("computeBoundingBox: no vertexes");
  }
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const v of vertexes) {
    if (v.x < minX) minX = v.x;
    if (v.y < minY) minY = v.y;
    if (v.x > maxX) maxX = v.x;
    if (v.y > maxY) maxY = v.y;
  }
  return { minX, minY, maxX, maxY };
}

/**
 * For every sector, the indices of every linedef that has that sector on its
 * front and/or back side. Useful to the client (and to future Cairo physics
 * code) to iterate "walls of sector S" without scanning all linedefs.
 */
export function computeSectorLines(linedefs: Linedef[], sidedefSectors: number[]): number[][] {
  const numSectors = Math.max(0, ...sidedefSectors.map((s) => s + 1));
  const out: number[][] = Array.from({ length: numSectors }, () => []);
  linedefs.forEach((line, lineIndex) => {
    const sectorsForLine = new Set<number>();
    if (line.frontSidedef !== 0xffff) {
      const sector = sidedefSectors[line.frontSidedef];
      if (sector !== undefined) sectorsForLine.add(sector);
    }
    if (line.backSidedef !== 0xffff) {
      const sector = sidedefSectors[line.backSidedef];
      if (sector !== undefined) sectorsForLine.add(sector);
    }
    for (const sector of sectorsForLine) {
      out[sector]?.push(lineIndex);
    }
  });
  return out;
}

/**
 * Maps every subsector to the sector it lies in (WAD tool v2, task item 1;
 * RISKS.md R2-A9/R2-A12): looks at the subsector's first seg, the linedef
 * that seg belongs to, and the sidedef facing the seg's side - exactly the
 * indirection vanilla Doom's `R_PointInSubsector` -> `sector_t*` lookup
 * performs once at map load. Doing it here at extraction time means the
 * Cairo core never needs SEGS (or the sidedef/linedef chain) at runtime:
 * it can index straight from a subsector index into a `SS_SECTOR` array.
 *
 * A subsector's segs all belong to the same sector by construction (they
 * bound one convex leaf of the BSP split), so the first seg is
 * representative of the whole subsector.
 *
 * A well-formed map always resolves every subsector; the `0xFFFF` sentinel
 * (matching `NO_SIDEDEF`) is returned instead of throwing only so this
 * function tolerates the deliberately-incomplete synthetic WADs used by
 * unit tests that exercise NODES/SSECTORS in isolation (e.g.
 * `test/nodes.test.ts`), which omit LINEDEFS/SIDEDEFS entirely.
 */
export const SUBSECTOR_SECTOR_UNRESOLVED = 0xffff;

export function computeSubsectorSectors(
  subsectors: Subsector[],
  segs: Seg[],
  linedefs: Linedef[],
  sidedefs: Sidedef[],
): number[] {
  return subsectors.map((ss) => {
    const seg = segs[ss.firstSeg];
    if (!seg) return SUBSECTOR_SECTOR_UNRESOLVED;
    const line = linedefs[seg.linedef];
    if (!line) return SUBSECTOR_SECTOR_UNRESOLVED;
    // seg.direction: 0 = seg runs the same way as the linedef (front side),
    // 1 = opposite (back side) - matches spikes/s1/tools/extract.py's
    // `ld['side1'] if sg['side'] else ld['side0']`.
    const sidedefIndex = seg.direction ? line.backSidedef : line.frontSidedef;
    if (sidedefIndex === 0xffff) return SUBSECTOR_SECTOR_UNRESOLVED;
    const sidedef = sidedefs[sidedefIndex];
    if (!sidedef) return SUBSECTOR_SECTOR_UNRESOLVED;
    return sidedef.sector;
  });
}

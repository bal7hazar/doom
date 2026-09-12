import { Linedef, Vertex } from "./types.js";

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

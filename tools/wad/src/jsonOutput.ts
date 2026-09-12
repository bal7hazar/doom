import { AssetIndex, MapData } from "./mapExtract.js";
import { BLOCKMAP_UNIT } from "./types.js";

/**
 * Output A (roadmap P0.2): the full map, in original map units (no bias
 * encoding - this is plain JSON for the TypeScript client, not Cairo), plus
 * derived data useful for rendering/collision: bounding box, blockmap grid
 * geometry, and per-sector line lists.
 */
export function buildMapJson(map: MapData, assets: AssetIndex) {
  return {
    map: map.name,
    counts: {
      things: map.things.length,
      linedefs: map.linedefs.length,
      sidedefs: map.sidedefs.length,
      vertexes: map.vertexes.length,
      segs: map.segs.length,
      subsectors: map.subsectors.length,
      nodes: map.nodes.length,
      sectors: map.sectors.length,
    },
    boundingBox: map.boundingBox,
    things: map.things,
    linedefs: map.linedefs,
    sidedefs: map.sidedefs,
    vertexes: map.vertexes,
    segs: map.segs,
    subsectors: map.subsectors,
    nodes: map.nodes,
    sectors: map.sectors,
    reject: {
      numSectors: map.reject.numSectors,
      // Hex-encoded raw bit matrix; decode with mapLumps.ts#rejectBit.
      dataHex: map.reject.data.toString("hex"),
    },
    blockmap: {
      unit: BLOCKMAP_UNIT,
      originX: map.blockmap.originX,
      originY: map.blockmap.originY,
      columns: map.blockmap.columns,
      rows: map.blockmap.rows,
      cellOffsets: map.blockmap.cellOffsets,
      cells: map.blockmap.cells,
    },
    derived: {
      sectorLines: map.sectorLines,
    },
    assets: assets,
  };
}

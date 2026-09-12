import { CellSubsectorSpans } from "./accelerator.js";
import { bytesToHex } from "./binary.js";
import { AssetIndex, MapData } from "./mapExtract.js";
import { BLOCKMAP_UNIT } from "./types.js";

/**
 * Output A (roadmap P0.2, extended by WAD tool v2): the full map, in
 * original map units (no bias encoding - this is plain JSON for the
 * TypeScript client, not Cairo), plus derived data useful for
 * rendering/collision: bounding box, blockmap grid geometry, per-sector
 * line lists, the subsector -> sector map, and the R2-A9 cell -> subsector
 * accelerator spans. SEGS and texture/flat names are kept here even though
 * `cairoOutput.ts` v2 drops them from the Cairo output - the client still
 * needs them for rendering.
 */
export function buildMapJson(map: MapData, assets: AssetIndex, cellSubsectors?: CellSubsectorSpans) {
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
      dataHex: bytesToHex(map.reject.data),
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
      // subsectorSectors[ss] = sector index subsector `ss` lies in (see
      // derive.ts#computeSubsectorSectors); this is the same data
      // cairoOutput.ts emits as SS_SECTOR/SS_SECTOR_PACKED.
      subsectorSectors: map.subsectorSectors,
      // R2-A9 accelerator (accelerator.ts#computeCellAccelerator), omitted
      // when the caller doesn't need it (e.g. a lightweight JSON build).
      ...(cellSubsectors ? { cellSubsectors } : {}),
    },
    assets: assets,
  };
}

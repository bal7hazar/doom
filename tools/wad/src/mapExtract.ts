import { listFlats, listSprites } from "./assets/markers.js";
import { parseColormap } from "./assets/colormap.js";
import { parsePlaypal } from "./assets/playpal.js";
import { parsePnames, parseTextureLump } from "./assets/textures.js";
import { computeBoundingBox, computeSectorLines, computeSubsectorSectors, MapBoundingBox } from "./derive.js";
import {
  parseBlockmap,
  parseLinedefs,
  parseNodes,
  parseReject,
  parseSectors,
  parseSegs,
  parseSidedefs,
  parseSubsectors,
  parseThings,
  parseVertexes,
} from "./mapLumps.js";
import {
  Blockmap,
  Linedef,
  Node,
  Reject,
  Sector,
  Seg,
  Sidedef,
  Subsector,
  Thing,
  Vertex,
} from "./types.js";
import { Wad } from "./wad.js";

/** The ten vanilla map lumps, in the fixed order they always follow the map marker lump. */
const MAP_LUMP_ORDER = [
  "THINGS",
  "LINEDEFS",
  "SIDEDEFS",
  "VERTEXES",
  "SEGS",
  "SSECTORS",
  "NODES",
  "SECTORS",
  "REJECT",
  "BLOCKMAP",
] as const;

export interface MapData {
  name: string;
  things: Thing[];
  linedefs: Linedef[];
  sidedefs: Sidedef[];
  vertexes: Vertex[];
  segs: Seg[];
  subsectors: Subsector[];
  nodes: Node[];
  sectors: Sector[];
  reject: Reject;
  blockmap: Blockmap;
  blockmapLumpBuffer: Uint8Array;
  boundingBox: MapBoundingBox;
  /** sectorLines[s] = indices into `linedefs` bordering sector `s`. */
  sectorLines: number[][];
  /**
   * subsectorSectors[ss] = sector index that subsector `ss` lies in (WAD
   * tool v2, task item 1): resolved via SEGS/LINEDEFS/SIDEDEFS at
   * extraction time so the Cairo output can drop SEGS entirely and still
   * answer "which sector is this subsector in" with a single array read.
   * See `derive.ts#computeSubsectorSectors`.
   */
  subsectorSectors: number[];
}

export function extractMap(wad: Wad, mapName: string): MapData {
  const entries = wad.lumpsAfter(mapName, MAP_LUMP_ORDER.length);
  entries.forEach((entry, i) => {
    const expected = MAP_LUMP_ORDER[i];
    if (entry.name !== expected) {
      throw new Error(
        `Map "${mapName}": expected lump #${i} after the marker to be ${expected}, found ${entry.name}. ` +
          `This WAD may not follow the vanilla map lump order.`,
      );
    }
  });
  const data = Object.fromEntries(
    entries.map((e) => [e.name, wad.lumpData(e)]),
  ) as Record<(typeof MAP_LUMP_ORDER)[number], Uint8Array>;

  const things = parseThings(data.THINGS);
  const linedefs = parseLinedefs(data.LINEDEFS);
  const sidedefs = parseSidedefs(data.SIDEDEFS);
  const vertexes = parseVertexes(data.VERTEXES);
  const segs = parseSegs(data.SEGS);
  const subsectors = parseSubsectors(data.SSECTORS);
  const nodes = parseNodes(data.NODES);
  const sectors = parseSectors(data.SECTORS);
  const reject = parseReject(data.REJECT, sectors.length);
  const blockmap = parseBlockmap(data.BLOCKMAP);

  const boundingBox = computeBoundingBox(vertexes);
  const sectorLines = computeSectorLines(
    linedefs,
    sidedefs.map((s) => s.sector),
  );
  const subsectorSectors = computeSubsectorSectors(subsectors, segs, linedefs, sidedefs);

  return {
    name: mapName,
    things,
    linedefs,
    sidedefs,
    vertexes,
    segs,
    subsectors,
    nodes,
    sectors,
    reject,
    blockmap,
    blockmapLumpBuffer: data.BLOCKMAP,
    boundingBox,
    sectorLines,
    subsectorSectors,
  };
}

export interface AssetIndex {
  playpalPaletteCount: number;
  colormapMapCount: number;
  pnamesCount: number;
  texture1Count: number;
  texture2Count: number | undefined;
  flats: { name: string; size: number }[];
  sprites: { name: string; size: number }[];
  /** Distinct 8-char texture/flat names actually referenced by this map's sidedefs/sectors. */
  referencedTextures: string[];
  referencedFlats: string[];
}

export function extractAssetIndex(wad: Wad, map: MapData): AssetIndex {
  const playpal = parsePlaypal(wad.lumpDataByName("PLAYPAL"));
  const colormap = parseColormap(wad.lumpDataByName("COLORMAP"));
  const pnames = parsePnames(wad.lumpDataByName("PNAMES"));
  const texture1 = parseTextureLump(wad.lumpDataByName("TEXTURE1"));
  const texture2Entry = wad.findLump("TEXTURE2");
  const texture2 = texture2Entry ? parseTextureLump(wad.lumpData(texture2Entry)) : undefined;
  const flats = listFlats(wad).map((f) => ({ name: f.name, size: f.size }));
  const sprites = listSprites(wad).map((s) => ({ name: s.name, size: s.size }));

  const referencedTextures = new Set<string>();
  for (const sd of map.sidedefs) {
    for (const t of [sd.upperTexture, sd.lowerTexture, sd.middleTexture]) {
      if (t !== "-" && t !== "") referencedTextures.add(t);
    }
  }
  const referencedFlats = new Set<string>();
  for (const sec of map.sectors) {
    referencedFlats.add(sec.floorTexture);
    referencedFlats.add(sec.ceilingTexture);
  }

  return {
    playpalPaletteCount: playpal.paletteCount,
    colormapMapCount: colormap.mapCount,
    pnamesCount: pnames.names.length,
    texture1Count: texture1.textures.length,
    texture2Count: texture2?.textures.length,
    flats,
    sprites,
    referencedTextures: [...referencedTextures].sort(),
    referencedFlats: [...referencedFlats].sort(),
  };
}

/**
 * The level JSON produced by `tools/wad` (`npm run extract`), typed.
 *
 * These interfaces are a *mirror* of tools/wad's `buildMapJson()` output, not a
 * second parser: the client never touches raw map lumps. Field names, units and
 * sentinels (`0xFFFF` for "no sidedef") are exactly the tool's.
 */

export interface JsonVertex {
  x: number;
  y: number;
}

export interface JsonThing {
  x: number;
  y: number;
  /** Degrees, 0 = east, counter-clockwise. */
  angle: number;
  /** doomednum. */
  type: number;
  flags: number;
}

export interface JsonLinedef {
  startVertex: number;
  endVertex: number;
  flags: number;
  specialType: number;
  sectorTag: number;
  frontSidedef: number;
  backSidedef: number;
}

export interface JsonSidedef {
  xOffset: number;
  yOffset: number;
  upperTexture: string;
  lowerTexture: string;
  middleTexture: string;
  sector: number;
}

export interface JsonSeg {
  startVertex: number;
  endVertex: number;
  angle: number;
  linedef: number;
  direction: number;
  offset: number;
}

export interface JsonSubsector {
  numSegs: number;
  firstSeg: number;
}

export interface JsonBBox {
  top: number;
  bottom: number;
  left: number;
  right: number;
}

export interface JsonNode {
  x: number;
  y: number;
  dx: number;
  dy: number;
  rightBBox: JsonBBox;
  leftBBox: JsonBBox;
  rightChild: number;
  leftChild: number;
}

export interface JsonSector {
  floorHeight: number;
  ceilingHeight: number;
  floorTexture: string;
  ceilingTexture: string;
  lightLevel: number;
  specialType: number;
  tag: number;
}

export interface LevelJson {
  map: string;
  counts: Record<string, number>;
  boundingBox: { minX: number; minY: number; maxX: number; maxY: number };
  things: JsonThing[];
  linedefs: JsonLinedef[];
  sidedefs: JsonSidedef[];
  vertexes: JsonVertex[];
  segs: JsonSeg[];
  subsectors: JsonSubsector[];
  nodes: JsonNode[];
  sectors: JsonSector[];
  reject: { numSectors: number; dataHex: string };
  blockmap: {
    unit: number;
    originX: number;
    originY: number;
    columns: number;
    rows: number;
    cellOffsets: number[];
    cells: number[][];
  };
  derived: { sectorLines: number[][] };
  assets: {
    playpalPaletteCount: number;
    colormapMapCount: number;
    pnamesCount: number;
    texture1Count: number;
    texture2Count?: number;
    flats: { name: string; size: number }[];
    sprites: { name: string; size: number }[];
    referencedTextures: string[];
    referencedFlats: string[];
  };
}

export const NO_SIDEDEF = 0xffff;
export const NODE_LEAF_FLAG = 0x8000;

export const LinedefFlag = {
  BLOCKING: 0x0001,
  BLOCK_MONSTERS: 0x0002,
  TWO_SIDED: 0x0004,
  UPPER_UNPEGGED: 0x0008,
  LOWER_UNPEGGED: 0x0010,
  SECRET: 0x0020,
  BLOCK_SOUND: 0x0040,
  NOT_ON_MAP: 0x0080,
  ALREADY_ON_MAP: 0x0100,
} as const;

/** The flat name vanilla treats as "this is open sky, draw the sky texture". */
export const SKY_FLAT = "F_SKY1";

/**
 * Sectors whose floor or ceiling can move at run time, so the renderer knows
 * which wall geometry to rebuild each frame instead of rebuilding all of it.
 *
 * A sector is considered dynamic when
 *  - it carries a non-zero tag (some linedef special can address it), or
 *  - it is the *back* sector of a tagless linedef with a manual door/lift
 *    special (D1/DR/S1 doors act on the sector behind the line), or
 *  - its own special makes its light blink (1, 2, 3, 12, 13, 17) - not strictly
 *    a geometry change, but it keeps the set in one place.
 *
 * Over-approximating is harmless (a few more quads rebuilt per frame);
 * under-approximating would freeze a door, so the manual-door rule is
 * deliberately generous: every non-zero special on a two-sided line counts.
 */
export function findDynamicSectors(level: LevelJson): Set<number> {
  const dynamic = new Set<number>();
  for (let i = 0; i < level.sectors.length; i++) {
    const s = level.sectors[i]!;
    if (s.tag !== 0) dynamic.add(i);
    if ([1, 2, 3, 8, 12, 13, 17].includes(s.specialType)) dynamic.add(i);
  }
  for (const line of level.linedefs) {
    if (line.specialType === 0) continue;
    if (line.sectorTag !== 0) {
      for (let i = 0; i < level.sectors.length; i++) {
        if (level.sectors[i]!.tag === line.sectorTag) dynamic.add(i);
      }
    } else if (line.backSidedef !== NO_SIDEDEF) {
      const back = level.sidedefs[line.backSidedef];
      if (back) dynamic.add(back.sector);
    }
  }
  return dynamic;
}

/** Convenience accessor: the sector a sidedef index faces, or `undefined`. */
export function sidedefSector(level: LevelJson, sidedefIndex: number): number | undefined {
  if (sidedefIndex === NO_SIDEDEF) return undefined;
  return level.sidedefs[sidedefIndex]?.sector;
}

/** Player 1 start (`doomednum` 1). Throws if the map has none. */
export function playerStart(level: LevelJson): JsonThing {
  const start = level.things.find((t) => t.type === 1);
  if (!start) throw new Error(`Map ${level.map} has no Player 1 start`);
  return start;
}

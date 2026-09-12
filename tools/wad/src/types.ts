/**
 * Typed records for the vanilla Doom map lump formats. Field comments
 * document the on-disk semantics (units, sign, what the value means to the
 * game engine), not just the type. All coordinates are in map units (1 map
 * unit ~= 1/16 of a foot, i.e. a player is 56 units tall); angles for THINGS
 * are in degrees (0-359, 0 = east, increasing counter-clockwise); heights
 * are in map units (z axis).
 */

/** VERTEXES lump entry (4 bytes): a single 2D point used by linedefs and segs. */
export interface Vertex {
  x: number; // int16, map units
  y: number; // int16, map units
}

/**
 * THINGS lump entry (10 bytes): a monster, item, decoration, or player start.
 * `type` is the "doomednum" (e.g. 1 = Player 1 start, 3004 = zombieman).
 */
export interface Thing {
  x: number; // int16, map units
  y: number; // int16, map units
  angle: number; // uint16, degrees, facing direction (0 = east, CCW)
  type: number; // uint16, doomednum identifying the thing's kind
  flags: number; // uint16, skill/behavior bitfield, see ThingFlag
}

/** THINGS.flags bits (vanilla Doom / Boom does not add more for THINGS). */
export const ThingFlag = {
  EASY: 0x0001, // present on skill 1-2 (ITYTD, HNTR)
  MEDIUM: 0x0002, // present on skill 3 (HMP)
  HARD: 0x0004, // present on skill 4-5 (UV, NM)
  AMBUSH: 0x0008, // "deaf" monster: does not wake on sound, only on sight
  MULTIPLAYER_ONLY: 0x0010, // absent from single-player games
} as const;

/**
 * LINEDEFS lump entry (14 bytes): an edge between two vertices that may be
 * impassable, trigger a special, and/or bound one or two sidedefs (sectors).
 * `frontSidedef`/`backSidedef` are 0xFFFF ("NO_SIDEDEF") when absent, e.g. a
 * one-sided wall has no back sidedef.
 */
export interface Linedef {
  startVertex: number; // uint16 index into VERTEXES
  endVertex: number; // uint16 index into VERTEXES
  flags: number; // uint16 bitfield, see LinedefFlag
  specialType: number; // uint16, vanilla linedef special (0 = none)
  sectorTag: number; // uint16, links this line's special to sector(s) sharing the tag
  frontSidedef: number; // uint16 index into SIDEDEFS, or 0xFFFF if none
  backSidedef: number; // uint16 index into SIDEDEFS, or 0xFFFF if none
}

export const NO_SIDEDEF = 0xffff;

export const LinedefFlag = {
  BLOCKING: 0x0001, // blocks players and monsters
  BLOCK_MONSTERS: 0x0002, // blocks monsters only
  TWO_SIDED: 0x0004, // has a sector on both sides (not a solid wall)
  UPPER_UNPEGGED: 0x0008, // upper texture is anchored to the ceiling, not the floor
  LOWER_UNPEGGED: 0x0010, // lower texture is anchored to the floor, not the ceiling
  SECRET: 0x0020, // shown as a normal wall on the automap (secret area hint)
  BLOCK_SOUND: 0x0040, // stops monster hearing propagation across this line
  NOT_ON_MAP: 0x0080, // never shown on the automap, even if seen
  ALREADY_ON_MAP: 0x0100, // always shown on the automap, even if not seen
} as const;

/**
 * SIDEDEFS lump entry (30 bytes): texturing and offsets for one side of a
 * linedef, and which sector it faces (used for floor/ceiling/light lookups).
 * Texture names are "-" (a literal dash, meaning "no texture") when unused.
 */
export interface Sidedef {
  xOffset: number; // int16, texture x offset in map units
  yOffset: number; // int16, texture y offset in map units
  upperTexture: string; // 8-char name, wall above a lower neighboring ceiling
  lowerTexture: string; // 8-char name, wall below a higher neighboring floor
  middleTexture: string; // 8-char name, the only texture on a one-sided wall
  sector: number; // uint16 index into SECTORS this sidedef faces
}

/**
 * SEGS lump entry (12 bytes): a fragment of a linedef used by a subsector,
 * as produced by the BSP builder (node builder), for rendering and for
 * point-in-subsector / collision queries at run time.
 */
export interface Seg {
  startVertex: number; // uint16 index into VERTEXES
  endVertex: number; // uint16 index into VERTEXES
  /**
   * BAM angle of the seg's direction, stored as the *top 16 bits* of a
   * 32-bit Binary Angle Measurement (angle_t). The on-disk field is a
   * signed 16-bit integer for historical/type reasons, but the value is a
   * circular quantity: reinterpreting its bit pattern as unsigned 16-bit
   * (0..65535, representing 0..360 degrees) recovers the true angle -
   * *not* the +32768 bias used for genuine signed magnitudes elsewhere in
   * this file. See `packing.ts` (`bamAngle16`).
   */
  angle: number; // uint16 after bit-reinterpretation, BAM units (65536 = 360deg)
  linedef: number; // uint16 index into LINEDEFS this seg is part of
  direction: number; // 0 = seg runs same direction as linedef, 1 = opposite
  offset: number; // int16, distance in map units from the linedef's start vertex
}

/** SSECTORS ("subsectors") lump entry (4 bytes): a convex leaf of the BSP tree. */
export interface Subsector {
  numSegs: number; // uint16, count of consecutive SEGS entries in this subsector
  firstSeg: number; // uint16 index of the first seg (segs are contiguous per subsector)
}

/** Axis-aligned bounding box in map units, as stored per BSP node child. */
export interface BBox {
  top: number; // int16, max y
  bottom: number; // int16, min y
  left: number; // int16, min x
  right: number; // int16, max x
}

/**
 * NODES lump entry (28 bytes): one node of the BSP tree used to partition
 * the map for rendering and for point-location queries (`point_in_subsector`).
 * `rightChild`/`leftChild` are either the index of another node, or, when bit
 * 15 is set, `(child & 0x7FFF)` is the index of a leaf SSECTOR.
 */
export interface Node {
  x: number; // int16, partition line start x
  y: number; // int16, partition line start y
  dx: number; // int16, partition line delta x
  dy: number; // int16, partition line delta y
  rightBBox: BBox;
  leftBBox: BBox;
  rightChild: number; // uint16, node index or (0x8000 | subsector index)
  leftChild: number; // uint16, node index or (0x8000 | subsector index)
}

export const NODE_LEAF_FLAG = 0x8000;

/**
 * SECTORS lump entry (26 bytes): a horizontal region with its own floor and
 * ceiling heights/textures, a light level, and an optional special effect
 * (damage floor, blinking light, secret, door-linked by tag, ...).
 */
export interface Sector {
  floorHeight: number; // int16, map units (z of the floor plane)
  ceilingHeight: number; // int16, map units (z of the ceiling plane)
  floorTexture: string; // 8-char flat name
  ceilingTexture: string; // 8-char flat name
  lightLevel: number; // int16, 0-255 nominal brightness
  specialType: number; // uint16, vanilla sector special (0 = none)
  tag: number; // uint16, links linedef specials targeting this sector
}

/**
 * REJECT lump: a numSectors x numSectors bit matrix (row-major, LSB-first
 * within each byte), size = ceil(numSectors * numSectors / 8) bytes.
 * Bit (i * numSectors + j) set to 1 means sector j is *not* visible from
 * sector i (a fast-reject hint for P_CheckSight, before the exact BSP/line
 * of sight test). It is a conservative *may-be-visible* table: 0 does not
 * guarantee visibility, but 1 guarantees invisibility.
 */
export interface Reject {
  numSectors: number;
  data: Uint8Array;
}

/**
 * BLOCKMAP lump: a uniform grid over the map (cells are `BLOCKMAP_UNIT`
 * (128) map units square) used to enumerate nearby linedefs quickly during
 * collision detection and hitscans, instead of testing every linedef.
 */
export const BLOCKMAP_UNIT = 128;

export interface Blockmap {
  originX: number; // int16, map-unit x of the grid's (0,0) cell corner
  originY: number; // int16, map-unit y of the grid's (0,0) cell corner
  columns: number; // uint16, grid width in cells
  rows: number; // uint16, grid height in cells
  /** columns*rows entries: word offset (from the start of the BLOCKMAP lump,
   * in 2-byte units) of each cell's blocklist. */
  cellOffsets: number[];
  /** Per cell, the list of linedef indices overlapping that cell, decoded
   * from its blocklist (the leading 0x0000 sentinel and trailing 0xFFFF
   * terminator are consumed here and not included). */
  cells: number[][];
}

/**
 * Per-record-type packing built on the primitives in `packing.ts`. Each
 * `packX`/`unpackX` pair is exercised by round-trip tests in
 * `test/packing.test.ts`. See that file's header and `cairoOutput.ts` for
 * the authoritative, generated documentation of each layout.
 */
import { bias16, nameToU64, packFields, raw16, u64ToName, unbias16, unpackFields, unraw16 } from "./packing.js";
import {
  BBox,
  Linedef,
  Node,
  Sector,
  Seg,
  Sidedef,
  Subsector,
  Thing,
  Vertex,
} from "./types.js";

// --- VERTEX: x_biased(16) | y_biased(16) << 16 -----------------------------------------------
export function packVertex(v: Vertex): bigint {
  return packFields([bias16(v.x), bias16(v.y)], [16, 16]);
}
export function unpackVertex(packed: bigint): Vertex {
  const [x, y] = unpackFields(packed, [16, 16]);
  return { x: unbias16(x!), y: unbias16(y!) };
}

// --- THING: x_biased(16) | y_biased(16)<<16 | angle(16)<<32 | type(16)<<48 | flags(16)<<64 ----
export function packThing(t: Thing): bigint {
  return packFields([bias16(t.x), bias16(t.y), raw16(t.angle), raw16(t.type), raw16(t.flags)], [16, 16, 16, 16, 16]);
}
export function unpackThing(packed: bigint): Thing {
  const [x, y, angle, type, flags] = unpackFields(packed, [16, 16, 16, 16, 16]);
  return { x: unbias16(x!), y: unbias16(y!), angle: unraw16(angle!), type: unraw16(type!), flags: unraw16(flags!) };
}

// --- LINEDEF: v1(16) | v2(16)<<16 | flags(16)<<32 | special(16)<<48 | tag(16)<<64
//              | front_side(16)<<80 | back_side(16)<<96   (0xFFFF = no sidedef) --------------
export function packLinedef(l: Linedef): bigint {
  return packFields(
    [
      raw16(l.startVertex),
      raw16(l.endVertex),
      raw16(l.flags),
      raw16(l.specialType),
      raw16(l.sectorTag),
      raw16(l.frontSidedef),
      raw16(l.backSidedef),
    ],
    [16, 16, 16, 16, 16, 16, 16],
  );
}
export function unpackLinedef(packed: bigint): Linedef {
  const [startVertex, endVertex, flags, specialType, sectorTag, frontSidedef, backSidedef] = unpackFields(
    packed,
    [16, 16, 16, 16, 16, 16, 16],
  );
  return {
    startVertex: unraw16(startVertex!),
    endVertex: unraw16(endVertex!),
    flags: unraw16(flags!),
    specialType: unraw16(specialType!),
    sectorTag: unraw16(sectorTag!),
    frontSidedef: unraw16(frontSidedef!),
    backSidedef: unraw16(backSidedef!),
  };
}

// --- SIDEDEF main fields: x_offset_biased(16) | y_offset_biased(16)<<16 | sector(16)<<32 ------
export interface SidedefMain {
  xOffset: number;
  yOffset: number;
  sector: number;
}
export function packSidedefMain(s: SidedefMain): bigint {
  return packFields([bias16(s.xOffset), bias16(s.yOffset), raw16(s.sector)], [16, 16, 16]);
}
export function unpackSidedefMain(packed: bigint): SidedefMain {
  const [xOffset, yOffset, sector] = unpackFields(packed, [16, 16, 16]);
  return { xOffset: unbias16(xOffset!), yOffset: unbias16(yOffset!), sector: unraw16(sector!) };
}
// Texture names are packed independently (see nameToU64) into parallel
// SIDEDEF_UPPER_TEXTURES / SIDEDEF_LOWER_TEXTURES / SIDEDEF_MIDDLE_TEXTURES
// arrays rather than crammed into the same felt as the numeric fields: three
// 64-bit names plus 48 bits of numeric fields would sit right at the edge of
// the 2^128 ceiling, so keeping them separate leaves comfortable headroom
// and keeps every constant easy to eyeball.
export function packSidedefTexture(name: string): bigint {
  return nameToU64(name);
}
export function unpackSidedefTexture(packed: bigint): string {
  return u64ToName(packed);
}
export function packSidedef(s: Sidedef): { main: bigint; upper: bigint; lower: bigint; middle: bigint } {
  return {
    main: packSidedefMain(s),
    upper: packSidedefTexture(s.upperTexture),
    lower: packSidedefTexture(s.lowerTexture),
    middle: packSidedefTexture(s.middleTexture),
  };
}
export function unpackSidedef(packed: { main: bigint; upper: bigint; lower: bigint; middle: bigint }): Sidedef {
  const main = unpackSidedefMain(packed.main);
  return {
    ...main,
    upperTexture: unpackSidedefTexture(packed.upper),
    lowerTexture: unpackSidedefTexture(packed.lower),
    middleTexture: unpackSidedefTexture(packed.middle),
  };
}

// --- SEG: v1(16) | v2(16)<<16 | angle(16)<<32 | linedef(16)<<48 | direction(16)<<64
//          | offset_biased(16)<<80 ----------------------------------------------------------
export function packSeg(s: Seg): bigint {
  return packFields(
    [raw16(s.startVertex), raw16(s.endVertex), raw16(s.angle), raw16(s.linedef), raw16(s.direction), bias16(s.offset)],
    [16, 16, 16, 16, 16, 16],
  );
}
export function unpackSeg(packed: bigint): Seg {
  const [startVertex, endVertex, angle, linedef, direction, offset] = unpackFields(packed, [16, 16, 16, 16, 16, 16]);
  return {
    startVertex: unraw16(startVertex!),
    endVertex: unraw16(endVertex!),
    angle: unraw16(angle!),
    linedef: unraw16(linedef!),
    direction: unraw16(direction!),
    offset: unbias16(offset!),
  };
}

// --- SSECTOR: num_segs(16) | first_seg(16)<<16 -------------------------------------------------
export function packSubsector(s: Subsector): bigint {
  return packFields([raw16(s.numSegs), raw16(s.firstSeg)], [16, 16]);
}
export function unpackSubsector(packed: bigint): Subsector {
  const [numSegs, firstSeg] = unpackFields(packed, [16, 16]);
  return { numSegs: unraw16(numSegs!), firstSeg: unraw16(firstSeg!) };
}

// --- NODE: split across three felts to stay well clear of the 2^128 ceiling -------------------
// partition: x_biased(16) | y_biased(16)<<16 | dx_biased(16)<<32 | dy_biased(16)<<48
export function packNodePartition(n: Pick<Node, "x" | "y" | "dx" | "dy">): bigint {
  return packFields([bias16(n.x), bias16(n.y), bias16(n.dx), bias16(n.dy)], [16, 16, 16, 16]);
}
export function unpackNodePartition(packed: bigint): Pick<Node, "x" | "y" | "dx" | "dy"> {
  const [x, y, dx, dy] = unpackFields(packed, [16, 16, 16, 16]);
  return { x: unbias16(x!), y: unbias16(y!), dx: unbias16(dx!), dy: unbias16(dy!) };
}
// bbox: top_biased(16) | bottom_biased(16)<<16 | left_biased(16)<<32 | right_biased(16)<<48
export function packBBox(b: BBox): bigint {
  return packFields([bias16(b.top), bias16(b.bottom), bias16(b.left), bias16(b.right)], [16, 16, 16, 16]);
}
export function unpackBBox(packed: bigint): BBox {
  const [top, bottom, left, right] = unpackFields(packed, [16, 16, 16, 16]);
  return { top: unbias16(top!), bottom: unbias16(bottom!), left: unbias16(left!), right: unbias16(right!) };
}
// children: right_child(16) | left_child(16)<<16  (leaf flag 0x8000 preserved verbatim per child)
export function packNodeChildren(n: Pick<Node, "rightChild" | "leftChild">): bigint {
  return packFields([raw16(n.rightChild), raw16(n.leftChild)], [16, 16]);
}
export function unpackNodeChildren(packed: bigint): Pick<Node, "rightChild" | "leftChild"> {
  const [rightChild, leftChild] = unpackFields(packed, [16, 16]);
  return { rightChild: unraw16(rightChild!), leftChild: unraw16(leftChild!) };
}
export function packNode(n: Node): { partition: bigint; rightBBox: bigint; leftBBox: bigint; children: bigint } {
  return {
    partition: packNodePartition(n),
    rightBBox: packBBox(n.rightBBox),
    leftBBox: packBBox(n.leftBBox),
    children: packNodeChildren(n),
  };
}
export function unpackNode(packed: { partition: bigint; rightBBox: bigint; leftBBox: bigint; children: bigint }): Node {
  return {
    ...unpackNodePartition(packed.partition),
    rightBBox: unpackBBox(packed.rightBBox),
    leftBBox: unpackBBox(packed.leftBBox),
    ...unpackNodeChildren(packed.children),
  };
}

// --- SECTOR main: floor_biased(16) | ceil_biased(16)<<16 | light_biased(16)<<32
//                  | special(16)<<48 | tag(16)<<64 --------------------------------------------
export interface SectorMain {
  floorHeight: number;
  ceilingHeight: number;
  lightLevel: number;
  specialType: number;
  tag: number;
}
export function packSectorMain(s: SectorMain): bigint {
  return packFields(
    [bias16(s.floorHeight), bias16(s.ceilingHeight), bias16(s.lightLevel), raw16(s.specialType), raw16(s.tag)],
    [16, 16, 16, 16, 16],
  );
}
export function unpackSectorMain(packed: bigint): SectorMain {
  const [floorHeight, ceilingHeight, lightLevel, specialType, tag] = unpackFields(packed, [16, 16, 16, 16, 16]);
  return {
    floorHeight: unbias16(floorHeight!),
    ceilingHeight: unbias16(ceilingHeight!),
    lightLevel: unbias16(lightLevel!),
    specialType: unraw16(specialType!),
    tag: unraw16(tag!),
  };
}
export function packSector(s: Sector): { main: bigint; floorTexture: bigint; ceilingTexture: bigint } {
  return {
    main: packSectorMain(s),
    floorTexture: nameToU64(s.floorTexture),
    ceilingTexture: nameToU64(s.ceilingTexture),
  };
}
export function unpackSector(packed: { main: bigint; floorTexture: bigint; ceilingTexture: bigint }): Sector {
  const main = unpackSectorMain(packed.main);
  return { ...main, floorTexture: u64ToName(packed.floorTexture), ceilingTexture: u64ToName(packed.ceilingTexture) };
}

// --- REJECT: bit rows chunked into <=128-bit felts ---------------------------------------------
export const REJECT_CHUNK_BITS = 128;

/** Number of 128-bit chunks needed to hold one row of `numSectors` bits. */
export function rejectChunksPerRow(numSectors: number): number {
  return Math.ceil(numSectors / REJECT_CHUNK_BITS);
}

/**
 * Packs the REJECT bit matrix into `numSectors * rejectChunksPerRow(numSectors)`
 * felts, row-major, chunk 0 (bits for sectors [0,128)) before chunk 1 (sectors
 * [128,256)), etc. Bit `b` of a chunk (LSB-first) is sector `chunkIndex*128+b`.
 */
export function packRejectRows(data: Uint8Array, numSectors: number): bigint[] {
  const chunksPerRow = rejectChunksPerRow(numSectors);
  const out: bigint[] = [];
  for (let i = 0; i < numSectors; i++) {
    for (let c = 0; c < chunksPerRow; c++) {
      let chunk = 0n;
      const colBase = c * REJECT_CHUNK_BITS;
      const colCount = Math.min(REJECT_CHUNK_BITS, numSectors - colBase);
      for (let b = 0; b < colCount; b++) {
        const j = colBase + b;
        const bitIndex = i * numSectors + j;
        const byte = data[bitIndex >> 3] ?? 0;
        const bit = (byte >> (bitIndex & 7)) & 1;
        if (bit) chunk |= 1n << BigInt(b);
      }
      out.push(chunk);
    }
  }
  return out;
}

export function unpackRejectBit(rows: bigint[], numSectors: number, i: number, j: number): boolean {
  const chunksPerRow = rejectChunksPerRow(numSectors);
  const chunkIndex = Math.floor(j / REJECT_CHUNK_BITS);
  const bitInChunk = j % REJECT_CHUNK_BITS;
  const chunk = rows[i * chunksPerRow + chunkIndex]!;
  return ((chunk >> BigInt(bitInChunk)) & 1n) === 1n;
}

// --- BLOCKMAP -----------------------------------------------------------------------------------
// header: origin_x_biased(16) | origin_y_biased(16)<<16 | columns(16)<<32 | rows(16)<<48
export interface BlockmapHeaderFields {
  originX: number;
  originY: number;
  columns: number;
  rows: number;
}
export function packBlockmapHeader(h: BlockmapHeaderFields): bigint {
  return packFields([bias16(h.originX), bias16(h.originY), raw16(h.columns), raw16(h.rows)], [16, 16, 16, 16]);
}
export function unpackBlockmapHeader(packed: bigint): BlockmapHeaderFields {
  const [originX, originY, columns, rows] = unpackFields(packed, [16, 16, 16, 16]);
  return { originX: unbias16(originX!), originY: unbias16(originY!), columns: unraw16(columns!), rows: unraw16(rows!) };
}

/**
 * Packs every 16-bit word of the raw BLOCKMAP lump (header + cell offset
 * table + blocklists, in on-disk order) as its unsigned bit-reinterpretation
 * (0..65535). This is the authoritative array a Cairo blockmap walker
 * indexes into: `cellOffsets[i]` (also exposed decoded in the JSON output)
 * is a word offset directly into this array, exactly as in the original
 * format, so no additional bias/adjustment is needed at lookup time.
 */
export function packBlockmapWords(lumpBuffer: Uint8Array): bigint[] {
  if (lumpBuffer.length % 2 !== 0) {
    throw new Error(`packBlockmapWords: BLOCKMAP lump size ${lumpBuffer.length} is odd`);
  }
  const view = new DataView(lumpBuffer.buffer, lumpBuffer.byteOffset, lumpBuffer.byteLength);
  const words: bigint[] = [];
  for (let off = 0; off < lumpBuffer.length; off += 2) {
    words.push(BigInt(view.getUint16(off, true)));
  }
  return words;
}

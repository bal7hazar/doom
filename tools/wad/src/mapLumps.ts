import { BinaryReader } from "./binary.js";
import {
  BBox,
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

export const RECORD_SIZE = {
  THINGS: 10,
  LINEDEFS: 14,
  SIDEDEFS: 30,
  VERTEXES: 4,
  SEGS: 12,
  SSECTORS: 4,
  NODES: 28,
  SECTORS: 26,
} as const;

function assertExactMultiple(lumpName: string, bufferLength: number, recordSize: number): number {
  if (bufferLength % recordSize !== 0) {
    throw new Error(
      `${lumpName} lump size ${bufferLength} is not a multiple of the record size ${recordSize}`,
    );
  }
  return bufferLength / recordSize;
}

export function parseVertexes(buffer: Uint8Array): Vertex[] {
  const count = assertExactMultiple("VERTEXES", buffer.length, RECORD_SIZE.VERTEXES);
  const r = new BinaryReader(buffer);
  const out: Vertex[] = [];
  for (let i = 0; i < count; i++) {
    out.push({ x: r.int16(), y: r.int16() });
  }
  return out;
}

export function parseThings(buffer: Uint8Array): Thing[] {
  const count = assertExactMultiple("THINGS", buffer.length, RECORD_SIZE.THINGS);
  const r = new BinaryReader(buffer);
  const out: Thing[] = [];
  for (let i = 0; i < count; i++) {
    out.push({
      x: r.int16(),
      y: r.int16(),
      angle: r.uint16(),
      type: r.uint16(),
      flags: r.uint16(),
    });
  }
  return out;
}

export function parseLinedefs(buffer: Uint8Array): Linedef[] {
  const count = assertExactMultiple("LINEDEFS", buffer.length, RECORD_SIZE.LINEDEFS);
  const r = new BinaryReader(buffer);
  const out: Linedef[] = [];
  for (let i = 0; i < count; i++) {
    out.push({
      startVertex: r.uint16(),
      endVertex: r.uint16(),
      flags: r.uint16(),
      specialType: r.uint16(),
      sectorTag: r.uint16(),
      frontSidedef: r.uint16(),
      backSidedef: r.uint16(),
    });
  }
  return out;
}

export function parseSidedefs(buffer: Uint8Array): Sidedef[] {
  const count = assertExactMultiple("SIDEDEFS", buffer.length, RECORD_SIZE.SIDEDEFS);
  const r = new BinaryReader(buffer);
  const out: Sidedef[] = [];
  for (let i = 0; i < count; i++) {
    out.push({
      xOffset: r.int16(),
      yOffset: r.int16(),
      upperTexture: r.name(8),
      lowerTexture: r.name(8),
      middleTexture: r.name(8),
      sector: r.uint16(),
    });
  }
  return out;
}

export function parseSegs(buffer: Uint8Array): Seg[] {
  const count = assertExactMultiple("SEGS", buffer.length, RECORD_SIZE.SEGS);
  const r = new BinaryReader(buffer);
  const out: Seg[] = [];
  for (let i = 0; i < count; i++) {
    const startVertex = r.uint16();
    const endVertex = r.uint16();
    // Stored as a signed int16 holding the top 16 bits of a BAM32 angle;
    // reinterpret the bit pattern as unsigned to recover the circular value.
    const angleRaw = r.int16();
    const angle = angleRaw < 0 ? angleRaw + 0x10000 : angleRaw;
    const linedef = r.uint16();
    const direction = r.int16();
    const offset = r.int16();
    out.push({ startVertex, endVertex, angle, linedef, direction, offset });
  }
  return out;
}

export function parseSubsectors(buffer: Uint8Array): Subsector[] {
  const count = assertExactMultiple("SSECTORS", buffer.length, RECORD_SIZE.SSECTORS);
  const r = new BinaryReader(buffer);
  const out: Subsector[] = [];
  for (let i = 0; i < count; i++) {
    out.push({ numSegs: r.uint16(), firstSeg: r.uint16() });
  }
  return out;
}

function readBBox(r: BinaryReader): BBox {
  // Classic on-disk order: top, bottom, left, right.
  return { top: r.int16(), bottom: r.int16(), left: r.int16(), right: r.int16() };
}

export function parseNodes(buffer: Uint8Array): Node[] {
  const count = assertExactMultiple("NODES", buffer.length, RECORD_SIZE.NODES);
  const r = new BinaryReader(buffer);
  const out: Node[] = [];
  for (let i = 0; i < count; i++) {
    const x = r.int16();
    const y = r.int16();
    const dx = r.int16();
    const dy = r.int16();
    const rightBBox = readBBox(r);
    const leftBBox = readBBox(r);
    const rightChild = r.uint16();
    const leftChild = r.uint16();
    out.push({ x, y, dx, dy, rightBBox, leftBBox, rightChild, leftChild });
  }
  return out;
}

export function parseSectors(buffer: Uint8Array): Sector[] {
  const count = assertExactMultiple("SECTORS", buffer.length, RECORD_SIZE.SECTORS);
  const r = new BinaryReader(buffer);
  const out: Sector[] = [];
  for (let i = 0; i < count; i++) {
    out.push({
      floorHeight: r.int16(),
      ceilingHeight: r.int16(),
      floorTexture: r.name(8),
      ceilingTexture: r.name(8),
      lightLevel: r.int16(),
      specialType: r.uint16(),
      tag: r.uint16(),
    });
  }
  return out;
}

/** `numSectors` must come from the parsed SECTORS lump, it cannot be derived from REJECT alone. */
export function parseReject(buffer: Uint8Array, numSectors: number): Reject {
  const expectedSize = Math.ceil((numSectors * numSectors) / 8);
  if (buffer.length < expectedSize) {
    throw new Error(
      `REJECT lump too small for ${numSectors} sectors: expected >= ${expectedSize} bytes, got ${buffer.length}`,
    );
  }
  return { numSectors, data: buffer.subarray(0, expectedSize) };
}

/** Is sector `j` flagged unreachable-from-sight from sector `i`? (1 = reject/not visible). */
export function rejectBit(reject: Reject, i: number, j: number): boolean {
  const bitIndex = i * reject.numSectors + j;
  const byteIndex = bitIndex >> 3;
  const bitInByte = bitIndex & 7;
  const byte = reject.data[byteIndex];
  if (byte === undefined) return false;
  return ((byte >> bitInByte) & 1) === 1;
}

const BLOCKMAP_HEADER_SIZE = 8;

export function parseBlockmap(buffer: Uint8Array): Blockmap {
  if (buffer.length < BLOCKMAP_HEADER_SIZE) {
    throw new Error(`BLOCKMAP lump too small: ${buffer.length} bytes`);
  }
  const r = new BinaryReader(buffer);
  const originX = r.int16();
  const originY = r.int16();
  const columns = r.uint16();
  const rows = r.uint16();
  const cellCount = columns * rows;

  const offsetsEnd = BLOCKMAP_HEADER_SIZE + cellCount * 2;
  if (offsetsEnd > buffer.length) {
    throw new Error(
      `BLOCKMAP offsets table [${BLOCKMAP_HEADER_SIZE}, ${offsetsEnd}) exceeds lump size ${buffer.length}`,
    );
  }
  const cellOffsets: number[] = [];
  for (let i = 0; i < cellCount; i++) {
    cellOffsets.push(r.uint16());
  }

  const cells: number[][] = [];
  for (let i = 0; i < cellCount; i++) {
    const byteOffset = cellOffsets[i]! * 2;
    if (byteOffset < 0 || byteOffset + 2 > buffer.length) {
      throw new Error(
        `BLOCKMAP cell ${i} offset ${cellOffsets[i]} (byte ${byteOffset}) is outside the lump (size ${buffer.length})`,
      );
    }
    const cellReader = new BinaryReader(buffer, byteOffset);
    const sentinel = cellReader.int16();
    if (sentinel !== 0) {
      throw new Error(`BLOCKMAP cell ${i}: expected leading 0x0000 sentinel, got ${sentinel}`);
    }
    const lines: number[] = [];
    // Vanilla format terminates each blocklist with -1 (0xFFFF); guard against
    // a missing terminator running off the end of the lump.
    for (;;) {
      if (cellReader.remaining < 2) {
        throw new Error(`BLOCKMAP cell ${i}: blocklist ran off the end of the lump without a terminator`);
      }
      const v = cellReader.int16();
      if (v === -1) break;
      lines.push(v);
    }
    cells.push(lines);
  }

  return { originX, originY, columns, rows, cellOffsets, cells };
}

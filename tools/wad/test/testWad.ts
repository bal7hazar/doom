/**
 * Builds small, deterministic, in-memory synthetic WAD buffers for
 * hermetic unit tests that must not depend on the real freedoom1.wad
 * download (see test/extract.e2e.test.ts for the real-file integration test).
 */

function name8(s: string): Buffer {
  const buf = Buffer.alloc(8);
  buf.write(s, "ascii");
  return buf;
}

export interface SyntheticLump {
  name: string;
  data: Buffer;
}

/** Builds a minimal valid IWAD from a list of (name, data) lumps, in order. */
export function buildWad(lumps: SyntheticLump[]): Buffer {
  const header = Buffer.alloc(12);
  header.write("IWAD", 0, "ascii");
  header.writeInt32LE(lumps.length, 4);

  const dataChunks: Buffer[] = [];
  let offset = 12;
  const directoryEntries: Buffer[] = [];
  for (const lump of lumps) {
    const entry = Buffer.alloc(16);
    entry.writeInt32LE(lump.data.length > 0 ? offset : 0, 0);
    entry.writeInt32LE(lump.data.length, 4);
    name8(lump.name).copy(entry, 8);
    directoryEntries.push(entry);
    dataChunks.push(lump.data);
    offset += lump.data.length;
  }
  header.writeInt32LE(offset, 8); // infotableofs = right after all lump data

  return Buffer.concat([header, ...dataChunks, ...directoryEntries]);
}

export function vertexLump(points: [number, number][]): Buffer {
  const buf = Buffer.alloc(points.length * 4);
  points.forEach(([x, y], i) => {
    buf.writeInt16LE(x, i * 4);
    buf.writeInt16LE(y, i * 4 + 2);
  });
  return buf;
}

export function thingLump(
  things: { x: number; y: number; angle: number; type: number; flags: number }[],
): Buffer {
  const buf = Buffer.alloc(things.length * 10);
  things.forEach((t, i) => {
    const o = i * 10;
    buf.writeInt16LE(t.x, o);
    buf.writeInt16LE(t.y, o + 2);
    buf.writeUInt16LE(t.angle, o + 4);
    buf.writeUInt16LE(t.type, o + 6);
    buf.writeUInt16LE(t.flags, o + 8);
  });
  return buf;
}

export function linedefLump(
  lines: {
    v1: number;
    v2: number;
    flags: number;
    special: number;
    tag: number;
    front: number;
    back: number;
  }[],
): Buffer {
  const buf = Buffer.alloc(lines.length * 14);
  lines.forEach((l, i) => {
    const o = i * 14;
    buf.writeUInt16LE(l.v1, o);
    buf.writeUInt16LE(l.v2, o + 2);
    buf.writeUInt16LE(l.flags, o + 4);
    buf.writeUInt16LE(l.special, o + 6);
    buf.writeUInt16LE(l.tag, o + 8);
    buf.writeUInt16LE(l.front, o + 10);
    buf.writeUInt16LE(l.back, o + 12);
  });
  return buf;
}

export function sidedefLump(
  sides: { xOff: number; yOff: number; upper: string; lower: string; middle: string; sector: number }[],
): Buffer {
  const buf = Buffer.alloc(sides.length * 30);
  sides.forEach((s, i) => {
    const o = i * 30;
    buf.writeInt16LE(s.xOff, o);
    buf.writeInt16LE(s.yOff, o + 2);
    name8(s.upper).copy(buf, o + 4);
    name8(s.lower).copy(buf, o + 12);
    name8(s.middle).copy(buf, o + 20);
    buf.writeUInt16LE(s.sector, o + 28);
  });
  return buf;
}

export function sectorLump(
  sectors: {
    floor: number;
    ceiling: number;
    floorTex: string;
    ceilTex: string;
    light: number;
    special: number;
    tag: number;
  }[],
): Buffer {
  const buf = Buffer.alloc(sectors.length * 26);
  sectors.forEach((s, i) => {
    const o = i * 26;
    buf.writeInt16LE(s.floor, o);
    buf.writeInt16LE(s.ceiling, o + 2);
    name8(s.floorTex).copy(buf, o + 4);
    name8(s.ceilTex).copy(buf, o + 12);
    buf.writeInt16LE(s.light, o + 20);
    buf.writeUInt16LE(s.special, o + 22);
    buf.writeUInt16LE(s.tag, o + 24);
  });
  return buf;
}

export function segLump(
  segs: { v1: number; v2: number; angle: number; linedef: number; direction: number; offset: number }[],
): Buffer {
  const buf = Buffer.alloc(segs.length * 12);
  segs.forEach((s, i) => {
    const o = i * 12;
    buf.writeUInt16LE(s.v1, o);
    buf.writeUInt16LE(s.v2, o + 2);
    buf.writeInt16LE(s.angle, o + 4);
    buf.writeUInt16LE(s.linedef, o + 6);
    buf.writeInt16LE(s.direction, o + 8);
    buf.writeInt16LE(s.offset, o + 10);
  });
  return buf;
}

export function subsectorLump(subs: { numSegs: number; firstSeg: number }[]): Buffer {
  const buf = Buffer.alloc(subs.length * 4);
  subs.forEach((s, i) => {
    buf.writeUInt16LE(s.numSegs, i * 4);
    buf.writeUInt16LE(s.firstSeg, i * 4 + 2);
  });
  return buf;
}

export function nodeLump(
  nodes: {
    x: number;
    y: number;
    dx: number;
    dy: number;
    rightBBox: [number, number, number, number];
    leftBBox: [number, number, number, number];
    rightChild: number;
    leftChild: number;
  }[],
): Buffer {
  const buf = Buffer.alloc(nodes.length * 28);
  nodes.forEach((n, i) => {
    const o = i * 28;
    buf.writeInt16LE(n.x, o);
    buf.writeInt16LE(n.y, o + 2);
    buf.writeInt16LE(n.dx, o + 4);
    buf.writeInt16LE(n.dy, o + 6);
    n.rightBBox.forEach((v, j) => buf.writeInt16LE(v, o + 8 + j * 2));
    n.leftBBox.forEach((v, j) => buf.writeInt16LE(v, o + 16 + j * 2));
    buf.writeUInt16LE(n.rightChild, o + 24);
    buf.writeUInt16LE(n.leftChild, o + 26);
  });
  return buf;
}

export function rejectLump(numSectors: number, setBits: [number, number][]): Buffer {
  const size = Math.ceil((numSectors * numSectors) / 8);
  const buf = Buffer.alloc(size);
  for (const [i, j] of setBits) {
    const bit = i * numSectors + j;
    buf[bit >> 3]! |= 1 << (bit & 7);
  }
  return buf;
}

/** cells[row][col] = list of linedef indices in that cell (row-major, columns fastest). */
export function blockmapLump(originX: number, originY: number, columns: number, rows: number, cells: number[][]): Buffer {
  if (cells.length !== columns * rows) {
    throw new Error(`blockmapLump: ${cells.length} cells given but columns*rows = ${columns * rows}`);
  }
  const headerSize = 8;
  const offsetsSize = columns * rows * 2;
  const blockBuffers = cells.map((lines) => {
    const b = Buffer.alloc(2 + lines.length * 2 + 2);
    b.writeInt16LE(0, 0);
    lines.forEach((l, i) => b.writeInt16LE(l, 2 + i * 2));
    b.writeInt16LE(-1, 2 + lines.length * 2);
    return b;
  });

  const header = Buffer.alloc(headerSize);
  header.writeInt16LE(originX, 0);
  header.writeInt16LE(originY, 2);
  header.writeUInt16LE(columns, 4);
  header.writeUInt16LE(rows, 6);

  const offsets = Buffer.alloc(offsetsSize);
  let wordOffset = (headerSize + offsetsSize) / 2;
  blockBuffers.forEach((b, i) => {
    offsets.writeUInt16LE(wordOffset, i * 2);
    wordOffset += b.length / 2;
  });

  return Buffer.concat([header, offsets, ...blockBuffers]);
}

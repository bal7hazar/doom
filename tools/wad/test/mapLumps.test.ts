import { describe, expect, it } from "vitest";
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
  RECORD_SIZE,
  rejectBit,
} from "../src/mapLumps.js";
import { NODE_LEAF_FLAG, NO_SIDEDEF } from "../src/types.js";
import {
  blockmapLump,
  linedefLump,
  nodeLump,
  rejectLump,
  sectorLump,
  segLump,
  sidedefLump,
  subsectorLump,
  thingLump,
  vertexLump,
} from "./testWad.js";

describe("lump size validation vs record size", () => {
  it("VERTEXES: size must be a multiple of 4", () => {
    expect(() => parseVertexes(Buffer.alloc(5))).toThrow(/multiple of the record size/);
    expect(parseVertexes(Buffer.alloc(RECORD_SIZE.VERTEXES * 3))).toHaveLength(3);
  });
  it("THINGS: size must be a multiple of 10", () => {
    expect(() => parseThings(Buffer.alloc(11))).toThrow(/multiple of the record size/);
  });
  it("LINEDEFS: size must be a multiple of 14", () => {
    expect(() => parseLinedefs(Buffer.alloc(15))).toThrow(/multiple of the record size/);
  });
  it("SIDEDEFS: size must be a multiple of 30", () => {
    expect(() => parseSidedefs(Buffer.alloc(31))).toThrow(/multiple of the record size/);
  });
  it("SEGS: size must be a multiple of 12", () => {
    expect(() => parseSegs(Buffer.alloc(13))).toThrow(/multiple of the record size/);
  });
  it("SSECTORS: size must be a multiple of 4", () => {
    expect(() => parseSubsectors(Buffer.alloc(5))).toThrow(/multiple of the record size/);
  });
  it("NODES: size must be a multiple of 28", () => {
    expect(() => parseNodes(Buffer.alloc(29))).toThrow(/multiple of the record size/);
  });
  it("SECTORS: size must be a multiple of 26", () => {
    expect(() => parseSectors(Buffer.alloc(27))).toThrow(/multiple of the record size/);
  });
});

describe("parseVertexes", () => {
  it("round-trips coordinates including negative values", () => {
    const vs = parseVertexes(vertexLump([[0, 0], [-100, 200], [32767, -32768]]));
    expect(vs).toEqual([
      { x: 0, y: 0 },
      { x: -100, y: 200 },
      { x: 32767, y: -32768 },
    ]);
  });
});

describe("parseThings", () => {
  it("parses coordinates, angle, type and flags", () => {
    const ts = parseThings(thingLump([{ x: 10, y: -20, angle: 90, type: 1, flags: 7 }]));
    expect(ts).toEqual([{ x: 10, y: -20, angle: 90, type: 1, flags: 7 }]);
  });
});

describe("parseLinedefs", () => {
  it("parses vertex indices within range and preserves the NO_SIDEDEF sentinel", () => {
    const numVertexes = 4;
    const ls = parseLinedefs(
      linedefLump([{ v1: 0, v2: 3, flags: 1, special: 0, tag: 0, front: 0, back: NO_SIDEDEF }]),
    );
    expect(ls[0]!.startVertex).toBeGreaterThanOrEqual(0);
    expect(ls[0]!.startVertex).toBeLessThan(numVertexes);
    expect(ls[0]!.endVertex).toBeLessThan(numVertexes);
    expect(ls[0]!.backSidedef).toBe(NO_SIDEDEF);
  });
});

describe("parseSidedefs", () => {
  it("parses offsets, texture names (incl. '-' for none), and sector index", () => {
    const sds = parseSidedefs(
      sidedefLump([{ xOff: -8, yOff: 16, upper: "-", lower: "STARTAN2", middle: "-", sector: 5 }]),
    );
    expect(sds).toEqual([{ xOffset: -8, yOffset: 16, upperTexture: "-", lowerTexture: "STARTAN2", middleTexture: "-", sector: 5 }]);
  });
});

describe("parseSectors and REJECT", () => {
  it("parses heights, textures, light, special and tag", () => {
    const secs = parseSectors(
      sectorLump([{ floor: 0, ceiling: 128, floorTex: "FLOOR0_1", ceilTex: "CEIL1_1", light: 200, special: 9, tag: 1 }]),
    );
    expect(secs).toEqual([
      { floorHeight: 0, ceilingHeight: 128, floorTexture: "FLOOR0_1", ceilingTexture: "CEIL1_1", lightLevel: 200, specialType: 9, tag: 1 },
    ]);
  });

  it("REJECT: size matches ceil(numSectors^2/8) and bits decode as expected", () => {
    const numSectors = 3; // 9 bits -> 2 bytes
    const reject = parseReject(rejectLump(numSectors, [[0, 2], [2, 2]]), numSectors);
    expect(reject.data).toHaveLength(2);
    expect(rejectBit(reject, 0, 2)).toBe(true);
    expect(rejectBit(reject, 2, 2)).toBe(true);
    expect(rejectBit(reject, 0, 0)).toBe(false);
    expect(rejectBit(reject, 1, 1)).toBe(false);
  });

  it("REJECT: throws if the lump is smaller than the matrix requires", () => {
    expect(() => parseReject(Buffer.alloc(1), 10)).toThrow(/too small/);
  });
});

describe("parseSegs (BAM angle bit-reinterpretation)", () => {
  it("reinterprets the signed on-disk angle as an unsigned 0..65535 BAM value", () => {
    const segs = parseSegs(segLump([
      { v1: 0, v2: 1, angle: 0, linedef: 0, direction: 0, offset: 0 },
      { v1: 0, v2: 1, angle: -1, linedef: 0, direction: 0, offset: 0 }, // top bit set -> 65535
      { v1: 0, v2: 1, angle: -32768, linedef: 0, direction: 0, offset: 0 }, // -> 32768 (180deg)
      { v1: 0, v2: 1, angle: 32767, linedef: 0, direction: 0, offset: 0 }, // stays 32767
    ]));
    expect(segs.map((s) => s.angle)).toEqual([0, 65535, 32768, 32767]);
  });
});

describe("parseSubsectors", () => {
  it("parses numSegs/firstSeg", () => {
    expect(parseSubsectors(subsectorLump([{ numSegs: 4, firstSeg: 12 }]))).toEqual([
      { numSegs: 4, firstSeg: 12 },
    ]);
  });
});

describe("parseNodes", () => {
  it("parses the partition line, both bboxes (top/bottom/left/right order), and children", () => {
    const nodes = parseNodes(
      nodeLump([
        {
          x: 0,
          y: 0,
          dx: 64,
          dy: 0,
          rightBBox: [100, -100, -50, 50], // top, bottom, left, right
          leftBBox: [200, 0, -50, 50],
          rightChild: NODE_LEAF_FLAG | 3,
          leftChild: 1,
        },
      ]),
    );
    expect(nodes[0]!.rightBBox).toEqual({ top: 100, bottom: -100, left: -50, right: 50 });
    expect(nodes[0]!.leftBBox).toEqual({ top: 200, bottom: 0, left: -50, right: 50 });
    expect(nodes[0]!.rightChild & NODE_LEAF_FLAG).toBe(NODE_LEAF_FLAG);
    expect(nodes[0]!.rightChild & 0x7fff).toBe(3);
    expect(nodes[0]!.leftChild).toBe(1);
  });
});

describe("parseBlockmap", () => {
  it("parses header, cell offsets (within the lump), and blocklists", () => {
    const buf = blockmapLump(-32, -32, 3, 1, [[5], [], [7, 8]]);
    const bm = parseBlockmap(buf);
    expect(bm.originX).toBe(-32);
    expect(bm.originY).toBe(-32);
    expect(bm.columns).toBe(3);
    expect(bm.rows).toBe(1);
    expect(bm.cells).toEqual([[5], [], [7, 8]]);
    // Every offset must address a position inside the lump.
    for (const cellOffset of bm.cellOffsets) {
      expect(cellOffset * 2).toBeGreaterThanOrEqual(0);
      expect(cellOffset * 2).toBeLessThan(buf.length);
    }
  });

  it("throws if a cell offset points outside the lump", () => {
    const buf = blockmapLump(0, 0, 1, 1, [[]]);
    buf.writeUInt16LE(0xffff, 8); // corrupt the single cell's offset
    expect(() => parseBlockmap(buf)).toThrow(/outside the lump/);
  });

  it("throws if a blocklist is missing its 0xFFFF terminator", () => {
    // Hand-build a blockmap whose only cell has no terminator.
    const header = Buffer.alloc(8);
    header.writeInt16LE(0, 0);
    header.writeInt16LE(0, 2);
    header.writeUInt16LE(1, 4);
    header.writeUInt16LE(1, 6);
    const offsets = Buffer.alloc(2);
    offsets.writeUInt16LE(5, 0); // word offset 5 = byte 10
    const block = Buffer.alloc(4);
    block.writeInt16LE(0, 0); // sentinel
    block.writeInt16LE(3, 2); // one linedef index, then EOF (no terminator)
    expect(() => parseBlockmap(Buffer.concat([header, offsets, block]))).toThrow(/terminator/);
  });
});

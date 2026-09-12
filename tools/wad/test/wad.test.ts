import { describe, expect, it } from "vitest";
import { Wad } from "../src/wad.js";
import { buildWad, vertexLump } from "./testWad.js";

describe("Wad container: header, directory, lump lookup", () => {
  it("parses the header and directory of a minimal synthetic WAD", () => {
    const buf = buildWad([
      { name: "E1M1", data: Buffer.alloc(0) },
      { name: "VERTEXES", data: vertexLump([[0, 0], [64, 0], [64, 64]]) },
    ]);
    const wad = Wad.fromBuffer(buf);
    expect(wad.header.identification).toBe("IWAD");
    expect(wad.header.numLumps).toBe(2);
    expect(wad.lumps).toHaveLength(2);
    expect(wad.lumps[0]!.name).toBe("E1M1");
    expect(wad.lumps[0]!.size).toBe(0);
    expect(wad.lumps[1]!.name).toBe("VERTEXES");
    expect(wad.lumps[1]!.size).toBe(12);
  });

  it("looks up lump data by name", () => {
    const buf = buildWad([{ name: "VERTEXES", data: vertexLump([[1, 2]]) }]);
    const wad = Wad.fromBuffer(buf);
    const data = wad.lumpDataByName("VERTEXES");
    expect(data.readInt16LE(0)).toBe(1);
    expect(data.readInt16LE(2)).toBe(2);
  });

  it("throws a clear error for a missing lump", () => {
    const wad = Wad.fromBuffer(buildWad([{ name: "FOO", data: Buffer.alloc(0) }]));
    expect(() => wad.lumpDataByName("BAR")).toThrow(/not found/);
  });

  it("returns the N lumps following a marker in directory order (lumpsAfter)", () => {
    const wad = Wad.fromBuffer(
      buildWad([
        { name: "E1M1", data: Buffer.alloc(0) },
        { name: "THINGS", data: Buffer.alloc(10) },
        { name: "LINEDEFS", data: Buffer.alloc(14) },
      ]),
    );
    const after = wad.lumpsAfter("E1M1", 2);
    expect(after.map((l) => l.name)).toEqual(["THINGS", "LINEDEFS"]);
  });

  it("lumpsAfter throws if fewer than `count` lumps remain", () => {
    const wad = Wad.fromBuffer(buildWad([{ name: "E1M1", data: Buffer.alloc(0) }]));
    expect(() => wad.lumpsAfter("E1M1", 3)).toThrow(/Expected 3 lumps/);
  });

  it("collects lumps strictly between a marker pair, skipping nested sub-range markers", () => {
    const wad = Wad.fromBuffer(
      buildWad([
        { name: "F_START", data: Buffer.alloc(0) },
        { name: "F1_START", data: Buffer.alloc(0) },
        { name: "FLAT1", data: Buffer.alloc(4096) },
        { name: "F1_END", data: Buffer.alloc(0) },
        { name: "FLAT2", data: Buffer.alloc(4096) },
        { name: "F_END", data: Buffer.alloc(0) },
      ]),
    );
    const flats = wad.lumpsBetweenMarkers("F_START", "F_END");
    expect(flats.map((l) => l.name)).toEqual(["FLAT1", "FLAT2"]);
  });

  it("rejects a buffer that isn't a WAD file", () => {
    expect(() => Wad.fromBuffer(Buffer.from("not a wad at all"))).toThrow(/identification/);
  });

  it("rejects a directory that runs past the end of the file", () => {
    const buf = Buffer.alloc(12);
    buf.write("IWAD", 0, "ascii");
    buf.writeInt32LE(5, 4); // claims 5 lumps
    buf.writeInt32LE(12, 8); // directory starts right after header, but no data follows
    expect(() => Wad.fromBuffer(buf)).toThrow(/exceeds file length/);
  });
});

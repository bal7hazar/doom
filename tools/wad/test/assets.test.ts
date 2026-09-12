import { describe, expect, it } from "vitest";
import { parseColormap } from "../src/assets/colormap.js";
import { parsePlaypal } from "../src/assets/playpal.js";
import { parsePatchHeader, parsePnames, parseTextureLump } from "../src/assets/textures.js";
import { listFlats, listSprites } from "../src/assets/markers.js";
import { Wad } from "../src/wad.js";
import { buildWad } from "./testWad.js";

describe("PLAYPAL", () => {
  it("parses N palettes of 256 RGB triples", () => {
    const buf = Buffer.alloc(768 * 2);
    buf[0] = 10;
    buf[1] = 20;
    buf[2] = 30; // palette 0, color 0
    buf[768] = 1; // palette 1, color 0, red channel
    const pal = parsePlaypal(buf);
    expect(pal.paletteCount).toBe(2);
    expect(pal.palettes[0]![0]).toEqual({ r: 10, g: 20, b: 30 });
    expect(pal.palettes[1]![0]).toEqual({ r: 1, g: 0, b: 0 });
  });

  it("rejects a size that isn't a multiple of 768", () => {
    expect(() => parsePlaypal(Buffer.alloc(100))).toThrow(/multiple of 768/);
  });
});

describe("COLORMAP", () => {
  it("parses N maps of 256 byte remaps", () => {
    const buf = Buffer.alloc(256 * 2);
    buf[0] = 5;
    buf[256] = 9;
    const cm = parseColormap(buf);
    expect(cm.mapCount).toBe(2);
    expect(cm.maps[0]![0]).toBe(5);
    expect(cm.maps[1]![0]).toBe(9);
  });
});

describe("PNAMES / TEXTURE1", () => {
  it("parses patch names and texture definitions with their patch placements", () => {
    const pnamesBuf = Buffer.alloc(4 + 8 * 2);
    pnamesBuf.writeInt32LE(2, 0);
    pnamesBuf.write("WALL00_1", 4, "ascii");
    pnamesBuf.write("WALL00_2", 12, "ascii");
    const pnames = parsePnames(pnamesBuf);
    expect(pnames.names).toEqual(["WALL00_1", "WALL00_2"]);

    // One texture, one patch: header(4 count + 4 offset) + maptexture_t(22 + 10)
    const texBuf = Buffer.alloc(4 + 4 + 22 + 10);
    texBuf.writeInt32LE(1, 0); // numtextures
    texBuf.writeInt32LE(8, 4); // offset of the single definition
    let o = 8;
    texBuf.write("MYWALL", o, "ascii");
    o += 8;
    texBuf.writeInt32LE(0, o); // masked
    o += 4;
    texBuf.writeInt16LE(64, o); // width
    o += 2;
    texBuf.writeInt16LE(128, o); // height
    o += 2;
    texBuf.writeInt32LE(0, o); // columndirectory
    o += 4;
    texBuf.writeInt16LE(1, o); // patchcount
    o += 2;
    texBuf.writeInt16LE(0, o); // originx
    o += 2;
    texBuf.writeInt16LE(0, o); // originy
    o += 2;
    texBuf.writeInt16LE(0, o); // patch index into PNAMES
    o += 2;
    texBuf.writeInt16LE(1, o); // stepdir (unused)
    o += 2;
    texBuf.writeInt16LE(0, o); // colormap (unused)

    const tex = parseTextureLump(texBuf);
    expect(tex.textures).toEqual([
      { name: "MYWALL", width: 64, height: 128, patches: [{ originX: 0, originY: 0, patch: 0 }] },
    ]);
  });
});

describe("Patch header", () => {
  it("parses width/height/offsets", () => {
    const buf = Buffer.alloc(8);
    buf.writeUInt16LE(64, 0);
    buf.writeUInt16LE(128, 2);
    buf.writeInt16LE(-1, 4);
    buf.writeInt16LE(2, 6);
    expect(parsePatchHeader(buf)).toEqual({ width: 64, height: 128, leftOffset: -1, topOffset: 2 });
  });
});

describe("flats/sprites marker ranges", () => {
  it("lists flats between F_START/F_END and sprites between S_START/S_END", () => {
    const wad = Wad.fromBuffer(
      buildWad([
        { name: "F_START", data: Buffer.alloc(0) },
        { name: "FLAT1", data: Buffer.alloc(4096) },
        { name: "FLAT2", data: Buffer.alloc(4096) },
        { name: "F_END", data: Buffer.alloc(0) },
        { name: "S_START", data: Buffer.alloc(0) },
        { name: "TROOA1", data: Buffer.alloc(200) },
        { name: "S_END", data: Buffer.alloc(0) },
      ]),
    );
    expect(listFlats(wad).map((f) => f.name)).toEqual(["FLAT1", "FLAT2"]);
    expect(listSprites(wad).map((s) => s.name)).toEqual(["TROOA1"]);
  });
});

import { describe, expect, it } from "vitest";
import {
  fakeContrast,
  INVULNERABILITY_COLORMAP,
  lightColormapRow,
  NUM_LIGHT_COLORMAPS,
  parseColormap,
} from "../src/assets/colormap.js";
import { parsePlaypal, selectPalette } from "../src/assets/playpal.js";
import { parsePatchHeader, parsePnames, parseTextureLump } from "../src/assets/textures.js";
import { listFlats, listSprites } from "../src/assets/markers.js";
import { selectSpriteLump, spriteRotation, type SpriteFrame } from "../src/assets/spriteFrames.js";
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

  it("also returns a flat RGBA8 view ready for texImage2D, alpha always 255", () => {
    const buf = Buffer.alloc(768);
    buf[0] = 10;
    buf[1] = 20;
    buf[2] = 30;
    const pal = parsePlaypal(buf);
    expect(pal.rgba).toHaveLength(1);
    expect(pal.rgba[0]).toHaveLength(256 * 4);
    expect(Array.from(pal.rgba[0]!.subarray(0, 4))).toEqual([10, 20, 30, 255]);
  });

  it("picks the red ramp while damaged and the gold ramp on a pickup (ST_doPaletteStuff)", () => {
    expect(selectPalette(0, 0, false)).toBe(0);
    expect(selectPalette(1, 0, false)).toBe(2);
    expect(selectPalette(255, 0, false)).toBe(8); // clamped to NUMREDPALS
    expect(selectPalette(0, 1, false)).toBe(10);
    expect(selectPalette(0, 255, false)).toBe(12);
    expect(selectPalette(0, 0, true)).toBe(13);
    // Damage wins over a pickup, as in ST_doPaletteStuff.
    expect(selectPalette(4, 4, true)).toBe(2);
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

  it("also returns a flat byte block one row can be sliced out of", () => {
    const buf = Buffer.alloc(256 * 2);
    buf[0] = 5;
    buf[256] = 9;
    const cm = parseColormap(buf);
    expect(cm.data).toHaveLength(512);
    expect(cm.data[0]).toBe(5);
    expect(cm.data[256]).toBe(9);
  });

  it("NUM_LIGHT_COLORMAPS/INVULNERABILITY_COLORMAP match vanilla NUMCOLORMAPS", () => {
    expect(NUM_LIGHT_COLORMAPS).toBe(32);
    expect(INVULNERABILITY_COLORMAP).toBe(32);
  });
});

describe("light ramp (R_InitLightTables in closed form)", () => {
  it("is full bright next to the eye and clamps to the ramp at range", () => {
    expect(lightColormapRow(255, 32)).toBe(0);
    expect(lightColormapRow(255, 100000)).toBe(0); // startmap 0 for light 255
    expect(lightColormapRow(0, 100000)).toBe(31); // startmap 60, clamped
  });

  it("darkens monotonically with distance and brightens with light level", () => {
    let previous = -1;
    for (const d of [16, 32, 64, 128, 256, 512, 1024, 4096]) {
      const row = lightColormapRow(160, d);
      expect(row).toBeGreaterThanOrEqual(previous);
      previous = row;
    }
    for (let light = 0; light <= 240; light += 16) {
      expect(lightColormapRow(light + 16, 512)).toBeLessThanOrEqual(lightColormapRow(light, 512));
    }
  });

  it("applies fake contrast the way R_StoreWallRange does", () => {
    expect(fakeContrast(160, 64, 0)).toBe(144); // horizontal wall: one darker
    expect(fakeContrast(160, 0, 64)).toBe(176); // vertical wall: one brighter
    expect(fakeContrast(160, 64, 64)).toBe(160); // diagonal: unchanged
    expect(fakeContrast(0, 64, 0)).toBe(0); // clamped at the bottom
    expect(fakeContrast(255, 0, 64)).toBe(240); // clamped at the top
  });
});

describe("selectSpriteLump (R_ProjectSprite lump/mirror pick)", () => {
  it("picks the single view for a non-rotating frame regardless of angle", () => {
    const frame: SpriteFrame = { rotate: false, lump: [42, -1, -1, -1, -1, -1, -1, -1], flip: new Array(8).fill(false) };
    expect(selectSpriteLump(frame, 0x12345678, 0)).toEqual({ lump: 42, flip: false });
  });

  it("picks the mirrored rotation when the frame's flip table says so", () => {
    const viewToThing = 0;
    const thingAngle = 0;
    const rot = spriteRotation(viewToThing, thingAngle); // whichever bucket this pair lands in
    const lump = [0, 1, 2, 3, 4, 5, 6, 7];
    const flip = new Array(8).fill(false);
    flip[rot] = true; // only the bucket the pair actually selects is mirrored
    const frame: SpriteFrame = { rotate: true, lump, flip };
    expect(selectSpriteLump(frame, viewToThing, thingAngle)).toEqual({ lump: rot, flip: true });
  });

  it("returns null when the selected rotation has no lump", () => {
    const frame: SpriteFrame = { rotate: true, lump: new Array(8).fill(-1), flip: new Array(8).fill(false) };
    expect(selectSpriteLump(frame, 0, 0)).toBeNull();
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

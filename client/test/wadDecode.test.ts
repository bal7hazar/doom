import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  blitPicture as blit,
  decodeFlat,
  decodePatch as decodePicture,
  emptyPicture,
  fakeContrast,
  lightColormapRow,
  parseColormap,
  parsePlaypal,
  selectPalette,
  spriteRotation,
  Wad,
} from "@hellproof/wad";
import { firstDifference, fromBase64, loadFixture } from "./fixture.js";

const fixture = loadFixture();

describe.skipIf(!fixture)("picture decoding against the tools/wad reference", () => {
  const f = fixture!;

  it("decodes a patch to exactly the same pixels and mask", () => {
    // The expected values come from the fixture generator
    // (test/fixtures/generate.ts), which decodes with this same
    // `@hellproof/wad` package; this is a regression check against the
    // committed fixture, not a cross-check between two implementations
    // (there is only one now - see tools/wad/README.md's "Library" section).
    const decoded = decodePicture(fromBase64(f.patch.raw));
    expect({
      width: decoded.width,
      height: decoded.height,
      leftOffset: decoded.leftOffset,
      topOffset: decoded.topOffset,
    }).toEqual({
      width: f.patch.decoded.width,
      height: f.patch.decoded.height,
      leftOffset: f.patch.decoded.leftOffset,
      topOffset: f.patch.decoded.topOffset,
    });
    expect(firstDifference(decoded.pixels, fromBase64(f.patch.decoded.pixels))).toBe(-1);
    expect(firstDifference(decoded.mask, fromBase64(f.patch.decoded.mask))).toBe(-1);
  });

  it("decodes a patch consistently with the raw post structure", () => {
    // Independent of either decoder: walk the lump's columns by hand and check
    // that the covered pixel count and one sampled post land where they should.
    const raw = fromBase64(f.patch.raw);
    const view = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
    const width = view.getUint16(0, true);
    const height = view.getUint16(2, true);
    const decoded = decodePicture(raw);

    let covered = 0;
    let checkedPosts = 0;
    for (let x = 0; x < width; x++) {
      let p = view.getUint32(8 + x * 4, true);
      for (;;) {
        const top = view.getUint8(p);
        if (top === 0xff) break;
        const length = view.getUint8(p + 1);
        for (let i = 0; i < length; i++) {
          const y = top + i;
          if (y >= height) continue;
          covered++;
          if (checkedPosts < 200) {
            expect(decoded.pixels[y * width + x]).toBe(raw[p + 3 + i]);
            expect(decoded.mask[y * width + x]).toBe(255);
          }
        }
        checkedPosts++;
        p += length + 4;
      }
    }
    expect(decoded.mask.reduce((n, v) => n + (v > 0 ? 1 : 0), 0)).toBe(covered);
    // A sprite is mostly empty: the mask must not be uniformly set.
    expect(covered).toBeLessThan(width * height);
    expect(covered).toBeGreaterThan(0);
  });

  it("decodes a flat as a fully opaque square of raw bytes", () => {
    const raw = fromBase64(f.flat.raw);
    const decoded = decodeFlat(raw);
    expect(decoded.width).toBe(f.flat.decoded.width);
    expect(decoded.height).toBe(f.flat.decoded.height);
    expect(decoded.width * decoded.height).toBe(raw.length);
    expect(firstDifference(decoded.pixels, raw)).toBe(-1);
    expect(decoded.mask.every((v) => v === 255)).toBe(true);
    expect(firstDifference(decoded.pixels, fromBase64(f.flat.decoded.pixels))).toBe(-1);
  });

  it("rejects a flat whose size is not a square", () => {
    expect(() => decodeFlat(new Uint8Array(4095))).toThrow(/square/);
  });
});

describe("composite texture blitting", () => {
  it("lets later patches overwrite earlier ones and leaves gaps transparent", () => {
    const dst = emptyPicture(4, 2);
    const a = { ...emptyPicture(2, 2), pixels: Uint8Array.of(1, 1, 1, 1), mask: Uint8Array.of(255, 255, 255, 255) };
    const b = { ...emptyPicture(2, 2), pixels: Uint8Array.of(2, 2, 2, 2), mask: Uint8Array.of(255, 0, 255, 0) };
    blit(dst, a, 0, 0);
    blit(dst, b, 1, 0);
    // Row 0: patch A covers x=0..1; B is blitted at x=1 but only its first
    // column has coverage, so it overwrites x=1 and leaves x=2 untouched.
    expect(Array.from(dst.pixels.subarray(0, 4))).toEqual([1, 2, 0, 0]);
    expect(Array.from(dst.mask.subarray(0, 4))).toEqual([255, 255, 0, 0]);
  });

  it("clips a patch that hangs off the texture", () => {
    const dst = emptyPicture(2, 2);
    const src = { ...emptyPicture(2, 2), pixels: Uint8Array.of(9, 9, 9, 9), mask: Uint8Array.of(255, 255, 255, 255) };
    blit(dst, src, 1, 1);
    expect(Array.from(dst.pixels)).toEqual([0, 0, 0, 9]);
  });
});

describe.skipIf(!fixture)("PLAYPAL and COLORMAP", () => {
  const f = fixture!;

  it("parses every palette as 256 RGBA colours", () => {
    const wad = Wad.fromBytes(new Uint8Array(readFileSync(f.wad.path)));
    const playpal = parsePlaypal(wad.lumpDataByName("PLAYPAL"));
    expect(playpal.paletteCount).toBe(f.palette.count);
    for (const p of playpal.rgba) {
      expect(p.length).toBe(256 * 4);
      expect(p[3]).toBe(255);
    }
    f.palette.palette0.forEach((c, i) => {
      expect(Array.from(playpal.rgba[0]!.subarray(i * 4, i * 4 + 3))).toEqual([c.r, c.g, c.b]);
    });
  });

  it("parses COLORMAP as a flat block one row can be indexed out of", () => {
    const wad = Wad.fromBytes(new Uint8Array(readFileSync(f.wad.path)));
    const colormap = parseColormap(wad.lumpDataByName("COLORMAP"));
    expect(colormap.mapCount).toBe(f.colormap.mapCount);
    expect(Array.from(colormap.data.subarray(0, 16))).toEqual(f.colormap.row0);
    expect(Array.from(colormap.data.subarray(16 * 256, 16 * 256 + 16))).toEqual(f.colormap.row16);
    expect(Array.from(colormap.data.subarray(31 * 256, 31 * 256 + 16))).toEqual(f.colormap.row31);
  });

  it("darkens monotonically from row 0 to row 31", () => {
    // Freedoom generates its own COLORMAP, so row 0 is not bit-identical to
    // vanilla's identity map. What the shader relies on is the *ordering*:
    // higher rows must be uniformly darker, ending near black.
    const wad = Wad.fromBytes(new Uint8Array(readFileSync(f.wad.path)));
    const colormap = parseColormap(wad.lumpDataByName("COLORMAP"));
    const playpal = parsePlaypal(wad.lumpDataByName("PLAYPAL"));
    const palette = playpal.rgba[0]!;
    const luminance = (row: number): number => {
      let sum = 0;
      for (let i = 0; i < 256; i++) {
        const c = colormap.data[row * 256 + i]! * 4;
        sum += 0.299 * palette[c]! + 0.587 * palette[c + 1]! + 0.114 * palette[c + 2]!;
      }
      return sum / 256;
    };
    let previous = Infinity;
    for (let row = 0; row < 32; row++) {
      const l = luminance(row);
      expect(l).toBeLessThanOrEqual(previous + 0.5);
      previous = l;
    }
    expect(luminance(0)).toBeGreaterThan(luminance(31) * 4);
    // Row 31 collapses the palette onto very few distinct entries.
    expect(new Set(colormap.data.subarray(31 * 256, 32 * 256)).size).toBeLessThan(24);
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

  it("matches the vanilla table it was derived from", () => {
    // startmap = (15 - (light>>4)) * 4; correction = floor(1280/distance).
    for (const light of [0, 48, 112, 160, 208, 255]) {
      for (const dist of [40, 90, 200, 700, 3000]) {
        const startmap = (15 - Math.min(15, light >> 4)) * 4;
        const expected = Math.max(0, Math.min(31, Math.floor(startmap - 1280 / dist)));
        expect(lightColormapRow(light, dist)).toBe(expected);
      }
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

describe("palette flash selection", () => {
  it("picks the red ramp while damaged and the gold ramp on a pickup", () => {
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

describe("sprite rotation selection (R_ProjectSprite)", () => {
  const ANG45 = 0x20000000;

  it.skipIf(!fixture)("matches the tools/wad implementation on every bucket", () => {
    for (const c of fixture!.sprites.rotationCases) {
      expect(spriteRotation(c.viewToThing, c.thingAngle)).toBe(c.expected);
    }
  });

  it("shows the front view when the camera is in front of the thing", () => {
    // A thing facing east (angle 0) seen from the east: the viewer-to-thing
    // vector points west, so rotation 0 - the sprite's front - is chosen.
    expect(spriteRotation(ANG45 * 4, 0)).toBe(0);
  });

  it("shows the back view when the camera is behind the thing", () => {
    expect(spriteRotation(0, 0)).toBe(4);
  });

  it("walks all eight buckets exactly once around the circle", () => {
    const seen = new Set<number>();
    for (let i = 0; i < 8; i++) seen.add(spriteRotation((i * ANG45) >>> 0, 0));
    expect([...seen].sort((a, b) => a - b)).toEqual([0, 1, 2, 3, 4, 5, 6, 7]);
  });

  it("centres each bucket: the boundary is at 22.5°, not 0°", () => {
    // The (ANG45/2)*9 bias means a thing seen from exactly its facing angle is
    // solidly inside bucket 4, not straddling two buckets.
    const justBefore = spriteRotation((ANG45 / 2 - 1) >>> 0, 0);
    const justAfter = spriteRotation((ANG45 / 2 + 1) >>> 0, 0);
    expect(justBefore).not.toBe(justAfter);
    expect(spriteRotation(0, 0)).toBe(spriteRotation((ANG45 / 2 - 1) >>> 0, 0));
  });

  it("is invariant under a rotation of both the camera and the thing", () => {
    for (const offset of [0x12345678, 0x80000000, 0xfedcba98]) {
      expect(spriteRotation((0x40000000 + offset) >>> 0, offset >>> 0)).toBe(
        spriteRotation(0x40000000, 0),
      );
    }
  });
});

describe.skipIf(!fixture)("sprite frame tables (R_InitSpriteDefs)", () => {
  const f = fixture!;

  it("builds eight rotations for a monster and one view for an item", () => {
    expect(f.sprites.TROO.frameA?.rotate).toBe(true);
    expect(f.sprites.TROO.frameA?.lump.every((l) => l >= 0)).toBe(true);
    expect(f.sprites.BON1.frameA?.rotate).toBe(false);
    // A single-view frame repeats the same lump in all eight slots.
    expect(new Set(f.sprites.BON1.frameA?.lump).size).toBe(1);
  });

  it("marks the mirrored rotations of the 8-character lump names", () => {
    // e.g. TROOA2A8: rotation 2 direct, rotation 8 flipped.
    const flips = f.sprites.TROO.frameA?.flip ?? [];
    expect(flips.some(Boolean)).toBe(true);
    const names = f.sprites.TROO.lumpNames;
    for (let rot = 0; rot < 8; rot++) {
      const name = names[rot];
      if (!name || name.length !== 8) continue;
      // The flipped half of a double-name lump is the second pair.
      const second = Number(name[7]);
      expect(flips[rot]).toBe(second === rot + 1);
    }
  });
});

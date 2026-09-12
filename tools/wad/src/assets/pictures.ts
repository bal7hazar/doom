import { BinaryReader } from "../binary.js";
import { Wad } from "../wad.js";
import { parsePnames, parseTextureLump, TextureDef } from "./textures.js";

/**
 * Picture decoding for the WAD tool: patches, flats and composed wall
 * textures, i.e. the "stretch goal" `playpal.ts` refers to.
 *
 * Output is palette indices plus a separate 1-bit coverage mask, never RGB:
 * Doom pictures have no alpha channel, index 0 is a real colour, and every
 * consumer (a PNG dump, the client's GPU atlas, a fidelity harness) wants to
 * apply `PLAYPAL`/`COLORMAP` itself. `toRgba()` is provided for the cases that
 * do want pixels.
 *
 * `BinaryReader` reads through a `DataView` over a plain `Uint8Array`, and
 * this module imports nothing from `node:*`, so it works unchanged in the
 * browser: the web client imports these decoders directly from
 * `@hellproof/wad` instead of carrying its own copy (see git history and
 * tools/wad/README.md for the P2.1/P2.2 duplication this replaced).
 */

export interface Picture {
  width: number;
  height: number;
  /** Pixels to shift left of the draw origin. */
  leftOffset: number;
  /** Pixels to shift above the draw origin. */
  topOffset: number;
  /** Row-major `width * height` palette indices. */
  pixels: Uint8Array;
  /** Row-major coverage: 255 where a post supplied a pixel, 0 elsewhere. */
  mask: Uint8Array;
}

/**
 * Decodes a `patch_t` lump.
 *
 * `uint16 width, uint16 height, int16 leftoffset, int16 topoffset`, then
 * `width` × `uint32` column offsets relative to the lump start. Each column is
 * a chain of posts: `uint8 topdelta` (0xFF terminates), `uint8 length`, a pad
 * byte, `length` pixels, a pad byte.
 *
 * A post whose `topdelta` does not exceed the previous one is treated as a
 * continuation ("tall patch" convention), which lets a column exceed 254 rows.
 * Patches with strictly increasing deltas - all vanilla-sized ones - are
 * unaffected.
 */
export function decodePatch(buffer: Uint8Array): Picture {
  const r = new BinaryReader(buffer);
  const width = r.uint16();
  const height = r.uint16();
  const leftOffset = r.int16();
  const topOffset = r.int16();
  if (width <= 0 || height <= 0 || width > 4096 || height > 4096) {
    throw new Error(`Patch: implausible dimensions ${width}x${height}`);
  }
  const columnOffsets: number[] = [];
  for (let x = 0; x < width; x++) columnOffsets.push(r.uint32());

  const pixels = new Uint8Array(width * height);
  const mask = new Uint8Array(width * height);

  for (let x = 0; x < width; x++) {
    let p = columnOffsets[x]!;
    if (p < 0 || p >= buffer.length) {
      throw new Error(`Patch: column ${x} offset ${p} out of bounds (${buffer.length})`);
    }
    let lastTop = -1;
    for (;;) {
      const topDelta = buffer[p]!;
      if (topDelta === 0xff) break;
      const length = buffer[p + 1]!;
      const top = topDelta <= lastTop ? lastTop + topDelta : topDelta;
      lastTop = top;
      const dataStart = p + 3;
      if (dataStart + length > buffer.length) {
        throw new Error(`Patch: post in column ${x} runs past the end of the lump`);
      }
      for (let i = 0; i < length; i++) {
        const y = top + i;
        if (y < 0 || y >= height) continue;
        pixels[y * width + x] = buffer[dataStart + i]!;
        mask[y * width + x] = 255;
      }
      p = dataStart + length + 1;
    }
  }

  return { width, height, leftOffset, topOffset, pixels, mask };
}

/** Decodes a flat: a raw, fully opaque square of palette indices (64×64 in vanilla). */
export function decodeFlat(buffer: Uint8Array): Picture {
  const side = Math.round(Math.sqrt(buffer.length));
  if (side === 0 || side * side !== buffer.length) {
    throw new Error(`Flat: size ${buffer.length} is not a square number of pixels`);
  }
  const mask = new Uint8Array(buffer.length);
  mask.fill(255);
  return {
    width: side,
    height: side,
    leftOffset: 0,
    topOffset: 0,
    pixels: Uint8Array.from(buffer),
    mask,
  };
}

/** Blits `src` over `dst` at (dx, dy), honouring `src`'s coverage mask. */
export function blitPicture(dst: Picture, src: Picture, dx: number, dy: number): void {
  for (let sy = 0; sy < src.height; sy++) {
    const y = dy + sy;
    if (y < 0 || y >= dst.height) continue;
    for (let sx = 0; sx < src.width; sx++) {
      const x = dx + sx;
      if (x < 0 || x >= dst.width) continue;
      const so = sy * src.width + sx;
      if (src.mask[so] === 0) continue;
      dst.pixels[y * dst.width + x] = src.pixels[so]!;
      dst.mask[y * dst.width + x] = 255;
    }
  }
}

export function emptyPicture(width: number, height: number): Picture {
  return {
    width,
    height,
    leftOffset: 0,
    topOffset: 0,
    pixels: new Uint8Array(width * height),
    mask: new Uint8Array(width * height),
  };
}

/**
 * Composes a wall texture from its patches, as `R_GenerateComposite` does:
 * patches in definition order, later ones overwriting earlier ones where they
 * have coverage, everything else left transparent (two-sided middle textures
 * depend on it).
 */
export function composeTexture(
  wad: Wad,
  def: TextureDef,
  pnames: string[],
  patchCache: Map<string, Picture> = new Map(),
): Picture {
  const out = emptyPicture(def.width, def.height);
  for (const placement of def.patches) {
    const name = pnames[placement.patch];
    if (name === undefined) {
      throw new Error(
        `Texture ${def.name}: patch index ${placement.patch} outside PNAMES (${pnames.length})`,
      );
    }
    let picture = patchCache.get(name);
    if (!picture) {
      const entry = wad.findLump(name);
      if (!entry) continue; // a texture may name a patch the IWAD does not ship
      picture = decodePatch(wad.lumpData(entry));
      patchCache.set(name, picture);
    }
    blitPicture(out, picture, placement.originX, placement.originY);
  }
  return out;
}

/** Every `TEXTURE1`/`TEXTURE2` definition of a WAD, keyed by upper-case name. */
export function readTextureDefs(wad: Wad): Map<string, TextureDef> {
  const defs = new Map<string, TextureDef>();
  for (const lumpName of ["TEXTURE1", "TEXTURE2"]) {
    const entry = wad.findLump(lumpName);
    if (!entry) continue;
    for (const def of parseTextureLump(wad.lumpData(entry)).textures) {
      defs.set(def.name.toUpperCase(), def);
    }
  }
  return defs;
}

export function readPnames(wad: Wad): string[] {
  return parsePnames(wad.lumpDataByName("PNAMES")).names.map((n) => n.toUpperCase());
}

/**
 * Expands a picture to RGBA8 through one `PLAYPAL` palette. Transparent texels
 * get alpha 0; `colormapRow`, when given, applies a `COLORMAP` light row first.
 */
export function toRgba(
  picture: Picture,
  palette: { r: number; g: number; b: number }[],
  colormapRow?: number[],
): Uint8Array {
  const out = new Uint8Array(picture.width * picture.height * 4);
  for (let i = 0; i < picture.width * picture.height; i++) {
    const index = colormapRow ? (colormapRow[picture.pixels[i]!] ?? 0) : picture.pixels[i]!;
    const color = palette[index];
    if (!color) continue;
    out[i * 4] = color.r;
    out[i * 4 + 1] = color.g;
    out[i * 4 + 2] = color.b;
    out[i * 4 + 3] = picture.mask[i]! > 0 ? 255 : 0;
  }
  return out;
}

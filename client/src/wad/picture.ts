import { BinaryReader } from "./binary.js";

/**
 * A decoded picture: palette indices plus a 1-bit coverage mask. Doom pictures
 * have no alpha channel; a pixel is either present (drawn with `pixels[i]` as a
 * `PLAYPAL` index) or absent (see-through). Index 0 is a *real* colour, so the
 * mask cannot be folded into the index — hence the separate array, which maps
 * one-to-one onto the RG8 atlas the renderer uploads (R = index, G = mask).
 */
export interface Picture {
  width: number;
  height: number;
  /** Pixels to shift left of the draw origin (sprite/HUD anchoring). */
  leftOffset: number;
  /** Pixels to shift above the draw origin. */
  topOffset: number;
  /** Row-major `width * height` palette indices. */
  pixels: Uint8Array;
  /** Row-major `width * height` coverage: 255 = opaque, 0 = transparent. */
  mask: Uint8Array;
}

/**
 * Decodes a `patch_t` picture lump (walls' patches, sprites, HUD graphics).
 *
 * Layout: `uint16 width, uint16 height, int16 leftoffset, int16 topoffset`,
 * then `width` × `uint32` column offsets relative to the start of the lump.
 * A column is a run of posts: `uint8 topdelta` (0xFF ends the column),
 * `uint8 length`, one padding byte, `length` pixel bytes, one padding byte.
 *
 * The "tall patch" convention (a post whose `topdelta` is not greater than the
 * previous one continues from it, letting a column exceed 254 rows) is honoured
 * because a handful of Freedoom sky/backdrop patches use it; vanilla-sized
 * patches are unaffected since their deltas are strictly increasing.
 */
export function decodePicture(bytes: Uint8Array): Picture {
  const r = new BinaryReader(bytes);
  const width = r.uint16();
  const height = r.uint16();
  const leftOffset = r.int16();
  const topOffset = r.int16();
  if (width <= 0 || height <= 0 || width > 4096 || height > 4096) {
    throw new Error(`Picture: implausible dimensions ${width}x${height}`);
  }

  const columnOffsets = new Array<number>(width);
  for (let x = 0; x < width; x++) columnOffsets[x] = r.uint32();

  const pixels = new Uint8Array(width * height);
  const mask = new Uint8Array(width * height);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

  for (let x = 0; x < width; x++) {
    let p = columnOffsets[x]!;
    if (p < 0 || p >= bytes.length) {
      throw new Error(`Picture: column ${x} offset ${p} out of bounds (${bytes.length})`);
    }
    let lastTopDelta = -1;
    for (;;) {
      const topDelta = view.getUint8(p);
      if (topDelta === 0xff) break;
      const length = view.getUint8(p + 1);
      // Tall-patch continuation: deltas that do not increase are relative.
      const top = topDelta <= lastTopDelta ? lastTopDelta + topDelta : topDelta;
      lastTopDelta = top;
      const dataStart = p + 3; // skip topdelta, length, and the leading pad byte
      if (dataStart + length > bytes.length) {
        throw new Error(`Picture: post at column ${x} runs past the end of the lump`);
      }
      for (let i = 0; i < length; i++) {
        const y = top + i;
        if (y < 0 || y >= height) continue; // clip rather than trust the lump
        const o = y * width + x;
        pixels[o] = bytes[dataStart + i]!;
        mask[o] = 255;
      }
      p = dataStart + length + 1; // skip the trailing pad byte
    }
  }

  return { width, height, leftOffset, topOffset, pixels, mask };
}

/** A 64×64 flat (floor/ceiling texture): raw, uncompressed, fully opaque. */
export function decodeFlat(bytes: Uint8Array): Picture {
  const side = Math.round(Math.sqrt(bytes.length));
  if (side * side !== bytes.length || side === 0) {
    throw new Error(`Flat: size ${bytes.length} is not a square number of pixels`);
  }
  const mask = new Uint8Array(bytes.length);
  mask.fill(255);
  return {
    width: side,
    height: side,
    leftOffset: 0,
    topOffset: 0,
    pixels: bytes.slice(),
    mask,
  };
}

/** Blits `src` into `dst` at (`dx`, `dy`), honouring `src`'s coverage mask. */
export function blit(dst: Picture, src: Picture, dx: number, dy: number): void {
  for (let sy = 0; sy < src.height; sy++) {
    const y = dy + sy;
    if (y < 0 || y >= dst.height) continue;
    for (let sx = 0; sx < src.width; sx++) {
      const x = dx + sx;
      if (x < 0 || x >= dst.width) continue;
      const so = sy * src.width + sx;
      if (src.mask[so] === 0) continue;
      const dofs = y * dst.width + x;
      dst.pixels[dofs] = src.pixels[so]!;
      dst.mask[dofs] = 255;
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

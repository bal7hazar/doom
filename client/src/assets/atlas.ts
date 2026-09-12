import type { Picture } from "@hellproof/wad";

export interface AtlasRect {
  x: number;
  y: number;
  width: number;
  height: number;
  /** Doom picture offsets, carried through for sprites and HUD graphics. */
  leftOffset: number;
  topOffset: number;
}

export interface Atlas {
  width: number;
  height: number;
  /**
   * Interleaved RG8: byte `2*(y*width + x)` is the `PLAYPAL` index and
   * `2*(y*width + x) + 1` is the coverage mask (0 or 255).
   *
   * Two channels rather than one because palette index 0 is a real colour
   * (a dark blue used all over Freedoom's shadows), so "index 0 means
   * transparent" would punch holes in half the textures. RG8 is a core
   * WebGL2 texturable format, needs no extension, and costs 2 bytes/texel
   * against 4 for RGBA.
   */
  data: Uint8Array;
  rects: Map<string, AtlasRect>;
  /** Entries that did not fit, in insertion order. Empty in the normal case. */
  overflow: string[];
}

export interface AtlasEntry {
  key: string;
  picture: Picture;
}

/**
 * Shelf packer.
 *
 * Doom pictures are wildly heterogeneous (64×64 flats, 256×128 walls, 40×70
 * sprites) but there are only a few hundred of them, so a height-sorted shelf
 * packer reaches ~85 % occupancy in a single linear pass — good enough that the
 * more elaborate MaxRects would only buy us a smaller atlas, not a faster one.
 *
 * No padding is emitted between entries: the shaders address the atlas with
 * `texelFetch` and an explicit wrap inside the entry's own rectangle, so
 * neighbouring entries can never bleed in, whatever the filtering.
 */
export function packAtlas(entries: AtlasEntry[], maxSize = 4096, minSize = 256): Atlas {
  const sorted = [...entries].sort((a, b) => b.picture.height - a.picture.height);

  const needed = sorted.reduce((sum, e) => sum + e.picture.width * e.picture.height, 0);
  let size = minSize;
  // Start from the smallest power of two that could hold the pixels at 100 %
  // occupancy, then grow until everything actually fits.
  while (size * size < needed && size < maxSize) size *= 2;

  for (;;) {
    const attempt = tryPack(sorted, size);
    if (attempt.overflow.length === 0 || size >= maxSize) return attempt;
    size *= 2;
  }
}

function tryPack(sorted: AtlasEntry[], size: number): Atlas {
  const data = new Uint8Array(size * size * 2);
  const rects = new Map<string, AtlasRect>();
  const overflow: string[] = [];

  let shelfY = 0;
  let shelfHeight = 0;
  let cursorX = 0;

  for (const entry of sorted) {
    const { width, height } = entry.picture;
    if (width > size || height > size) {
      overflow.push(entry.key);
      continue;
    }
    if (cursorX + width > size) {
      shelfY += shelfHeight;
      shelfHeight = 0;
      cursorX = 0;
    }
    if (shelfY + height > size) {
      overflow.push(entry.key);
      continue;
    }
    blitInto(data, size, entry.picture, cursorX, shelfY);
    rects.set(entry.key, {
      x: cursorX,
      y: shelfY,
      width,
      height,
      leftOffset: entry.picture.leftOffset,
      topOffset: entry.picture.topOffset,
    });
    cursorX += width;
    if (height > shelfHeight) shelfHeight = height;
  }

  return { width: size, height: size, data, rects, overflow };
}

function blitInto(data: Uint8Array, size: number, picture: Picture, dx: number, dy: number): void {
  for (let y = 0; y < picture.height; y++) {
    let src = y * picture.width;
    let dst = ((dy + y) * size + dx) * 2;
    for (let x = 0; x < picture.width; x++, src++, dst += 2) {
      data[dst] = picture.pixels[src]!;
      data[dst + 1] = picture.mask[src]!;
    }
  }
}

/** Fraction of the atlas actually covered by entries; reported on the diagnostics panel. */
export function atlasOccupancy(atlas: Atlas): number {
  let used = 0;
  for (const r of atlas.rects.values()) used += r.width * r.height;
  return used / (atlas.width * atlas.height);
}

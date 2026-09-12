/**
 * COLORMAP lump: 34 maps of 256 palette-index remaps each (1 byte/entry,
 * 256 bytes/map). Maps 0-31 are light-level shading (0 = full bright, 31 =
 * near black), 32 is the invulnerability/inverse effect, 33 is unused/full
 * black in vanilla. Used at render time as `colormap[lightLevel][paletteIndex]`.
 */
export interface Colormap {
  mapCount: number;
  /** [mapIndex][paletteIndex] -> remapped palette index */
  maps: number[][];
}

const ENTRIES_PER_MAP = 256;

export function parseColormap(buffer: Buffer): Colormap {
  if (buffer.length % ENTRIES_PER_MAP !== 0) {
    throw new Error(`COLORMAP size ${buffer.length} is not a multiple of ${ENTRIES_PER_MAP}`);
  }
  const mapCount = buffer.length / ENTRIES_PER_MAP;
  const maps: number[][] = [];
  for (let m = 0; m < mapCount; m++) {
    const base = m * ENTRIES_PER_MAP;
    maps.push(Array.from(buffer.subarray(base, base + ENTRIES_PER_MAP)));
  }
  return { mapCount, maps };
}

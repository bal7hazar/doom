/**
 * PLAYPAL lump: 14 palettes (normal + damage/berserk/radsuit flashes) of 256
 * RGB triples each (3 bytes/color, 768 bytes/palette). No decoding to PNG is
 * done here (stretch goal); this only indexes the palettes for later use by
 * the (future) texture/flat/sprite-to-PNG decoder.
 */
export interface Rgb {
  r: number;
  g: number;
  b: number;
}

export interface Playpal {
  paletteCount: number;
  /** [paletteIndex][colorIndex] */
  palettes: Rgb[][];
}

const COLORS_PER_PALETTE = 256;
const BYTES_PER_PALETTE = COLORS_PER_PALETTE * 3;

export function parsePlaypal(buffer: Buffer): Playpal {
  if (buffer.length % BYTES_PER_PALETTE !== 0) {
    throw new Error(
      `PLAYPAL size ${buffer.length} is not a multiple of ${BYTES_PER_PALETTE} (256 RGB colors)`,
    );
  }
  const paletteCount = buffer.length / BYTES_PER_PALETTE;
  const palettes: Rgb[][] = [];
  for (let p = 0; p < paletteCount; p++) {
    const colors: Rgb[] = [];
    const base = p * BYTES_PER_PALETTE;
    for (let c = 0; c < COLORS_PER_PALETTE; c++) {
      const off = base + c * 3;
      colors.push({ r: buffer[off]!, g: buffer[off + 1]!, b: buffer[off + 2]! });
    }
    palettes.push(colors);
  }
  return { paletteCount, palettes };
}

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
  /** `rgba[p]` is a 256×4 RGBA8 buffer, ready for `texImage2D`. Alpha is always 255. */
  rgba: Uint8Array[];
}

const COLORS_PER_PALETTE = 256;
const BYTES_PER_PALETTE = COLORS_PER_PALETTE * 3;

/**
 * `PLAYPAL`: 14 palettes of 256 RGB triples. Palette 0 is the normal one;
 * 1-8 are the damage-red flashes, 9-12 the item-pickup gold flash, 13 the
 * radiation-suit green. Both a `{r,g,b}` view (`palettes`, handy for reports
 * and tests) and a flat RGBA8 view (`rgba`, ready to upload as a GPU texture)
 * are returned so a renderer never has to re-walk the raw bytes.
 */
export function parsePlaypal(buffer: Uint8Array): Playpal {
  if (buffer.length % BYTES_PER_PALETTE !== 0) {
    throw new Error(
      `PLAYPAL size ${buffer.length} is not a multiple of ${BYTES_PER_PALETTE} (256 RGB colors)`,
    );
  }
  const paletteCount = buffer.length / BYTES_PER_PALETTE;
  const palettes: Rgb[][] = [];
  const rgba: Uint8Array[] = [];
  for (let p = 0; p < paletteCount; p++) {
    const colors: Rgb[] = [];
    const out = new Uint8Array(COLORS_PER_PALETTE * 4);
    const base = p * BYTES_PER_PALETTE;
    for (let c = 0; c < COLORS_PER_PALETTE; c++) {
      const off = base + c * 3;
      const r = buffer[off]!;
      const g = buffer[off + 1]!;
      const b = buffer[off + 2]!;
      colors.push({ r, g, b });
      out[c * 4] = r;
      out[c * 4 + 1] = g;
      out[c * 4 + 2] = b;
      out[c * 4 + 3] = 255;
    }
    palettes.push(colors);
    rgba.push(out);
  }
  return { paletteCount, palettes, rgba };
}

/**
 * Doom's palette-flash selection (`ST_doPaletteStuff`): which of the 14
 * `PLAYPAL` palettes to display for the current damage/bonus/radsuit state.
 */
export function selectPalette(damageCount: number, bonusCount: number, radiationSuit: boolean): number {
  if (damageCount > 0) {
    // STARTREDPALS = 1, NUMREDPALS = 8
    const count = Math.min(7, (damageCount + 7) >> 3);
    return 1 + count;
  }
  if (bonusCount > 0) {
    // STARTBONUSPALS = 9, NUMBONUSPALS = 4
    const count = Math.min(3, (bonusCount + 7) >> 3);
    return 9 + count;
  }
  if (radiationSuit) return 13; // RADIATIONPAL
  return 0;
}

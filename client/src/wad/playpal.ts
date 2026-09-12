const COLORS_PER_PALETTE = 256;
const BYTES_PER_PALETTE = COLORS_PER_PALETTE * 3;

export interface Playpal {
  paletteCount: number;
  /** `rgba[p]` is a 256×4 RGBA8 buffer, ready for `texImage2D`. Alpha is always 255. */
  rgba: Uint8Array[];
}

/**
 * `PLAYPAL`: 14 palettes of 256 RGB triples. Palette 0 is the normal one;
 * 1–8 are the damage-red flashes, 9–12 the item-pickup gold flash, 13 the
 * radiation-suit green. The renderer keeps them all so the HUD's
 * `damageCount`/`bonusCount` can select one without re-reading the WAD.
 */
export function parsePlaypal(bytes: Uint8Array): Playpal {
  if (bytes.length % BYTES_PER_PALETTE !== 0) {
    throw new Error(`PLAYPAL size ${bytes.length} is not a multiple of ${BYTES_PER_PALETTE}`);
  }
  const paletteCount = bytes.length / BYTES_PER_PALETTE;
  const rgba: Uint8Array[] = [];
  for (let p = 0; p < paletteCount; p++) {
    const out = new Uint8Array(COLORS_PER_PALETTE * 4);
    const base = p * BYTES_PER_PALETTE;
    for (let c = 0; c < COLORS_PER_PALETTE; c++) {
      out[c * 4 + 0] = bytes[base + c * 3 + 0]!;
      out[c * 4 + 1] = bytes[base + c * 3 + 1]!;
      out[c * 4 + 2] = bytes[base + c * 3 + 2]!;
      out[c * 4 + 3] = 255;
    }
    rgba.push(out);
  }
  return { paletteCount, rgba };
}

/**
 * Doom's palette-flash selection (`ST_doPaletteStuff`), reproduced so the
 * client picks the same palette the proven simulation would imply from
 * `damageCount` / `bonusCount` / `radiationSuit`.
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

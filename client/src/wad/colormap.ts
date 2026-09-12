const ENTRIES_PER_MAP = 256;

/** Vanilla `NUMCOLORMAPS`: maps 0..31 are the light ramp, 32 is invulnerability. */
export const NUM_LIGHT_COLORMAPS = 32;
export const INVULNERABILITY_COLORMAP = 32;

export interface Colormap {
  mapCount: number;
  /** Flat `mapCount * 256` byte block, row `m` at `[m*256, m*256+256)`. Uploadable as an R8 texture. */
  data: Uint8Array;
}

/**
 * `COLORMAP`: 34 × 256 palette-index remaps. Row 0 is full bright, row 31 is
 * nearly black; row 32 is the inverted invulnerability map and row 33 is the
 * all-black filler vanilla never draws with.
 *
 * The client uploads this verbatim as a 256×34 R8 texture and does the lookup
 * in the fragment shader, so on-screen colours are *exactly* the ones the
 * software renderer would pick — no approximation of the light ramp, including
 * its characteristic banding.
 */
export function parseColormap(bytes: Uint8Array): Colormap {
  if (bytes.length % ENTRIES_PER_MAP !== 0) {
    throw new Error(`COLORMAP size ${bytes.length} is not a multiple of ${ENTRIES_PER_MAP}`);
  }
  return { mapCount: bytes.length / ENTRIES_PER_MAP, data: bytes.slice() };
}

/**
 * The vanilla light-level → colormap-row function, in closed form.
 *
 * `R_InitLightTables` builds `zlight[LIGHTLEVELS][MAXLIGHTZ]` as
 *
 *     startmap = ((LIGHTLEVELS-1 - i) * 2) * NUMCOLORMAPS / LIGHTLEVELS
 *     scale    = FixedDiv(SCREENWIDTH/2 << FRACBITS, (j+1) << LIGHTZSHIFT) >> LIGHTSCALESHIFT
 *     level    = clamp(startmap - scale / DISTMAP, 0, NUMCOLORMAPS-1)
 *
 * with LIGHTLEVELS=16, LIGHTSEGSHIFT=4, NUMCOLORMAPS=32, SCREENWIDTH=320,
 * LIGHTZSHIFT=20, LIGHTSCALESHIFT=12, DISTMAP=2 and `j = z >> LIGHTZSHIFT`,
 * i.e. `j+1 ≈ distance / 16` for a distance in map units.
 *
 * Substituting: `scale >> LIGHTSCALESHIFT` reduces to `160 / (j+1)`, so
 *
 *     lightnum = clamp(lightLevel >> 4, 0, 15)
 *     startmap = (15 - lightnum) * 4
 *     level    = clamp(startmap - 1280 / distance, 0, 31)
 *
 * which is what the shader evaluates per fragment (see `shaders.ts`). This
 * function is the CPU twin, used by the automap and by the unit tests.
 */
export function lightColormapRow(lightLevel: number, distanceMapUnits: number): number {
  const lightnum = clampInt(lightLevel >> 4, 0, 15);
  const startmap = (15 - lightnum) * 4;
  const d = Math.max(1, distanceMapUnits);
  return clampInt(Math.floor(startmap - 1280 / d), 0, NUM_LIGHT_COLORMAPS - 1);
}

/**
 * Vanilla "fake contrast" (`R_StoreWallRange`): perfectly horizontal walls are
 * drawn one light level darker and perfectly vertical ones one lighter, which
 * is what gives Doom's untextured corners their readable edges. Returns the
 * adjusted *light level* (0–255), not the colormap row.
 */
export function fakeContrast(lightLevel: number, dx: number, dy: number): number {
  let lightnum = lightLevel >> 4;
  if (dy === 0) lightnum -= 1;
  else if (dx === 0) lightnum += 1;
  return clampInt(lightnum, 0, 15) << 4;
}

function clampInt(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

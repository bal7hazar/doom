/**
 * doomednum → sprite, derived from vanilla `mobjinfo[]` / `states[]`.
 *
 * The renderer needs three things the level JSON does not carry: which 4-letter
 * sprite a thing uses, which frames its *spawn state* cycles through (so idle
 * items animate), and how tall/wide it is. Freedoom reuses vanilla's
 * doomednums and sprite names verbatim, so this table applies unchanged to
 * `freedoom1.wad`.
 *
 * `frames` lists frame indices (0 = 'A'); a single-entry list is a static
 * sprite. `ticsPerFrame` is the spawn state's duration in tics (35 Hz);
 * `fullbright` marks the frames vanilla draws at full brightness regardless of
 * sector light.
 *
 * Once the Cairo core owns the state machine (P1.x), the *frame* will come from
 * the snapshot and this table degrades to "sprite name + dimensions"; the
 * `frames`/`ticsPerFrame` columns exist so the stub sim can animate today.
 */
export interface MobjInfo {
  sprite: string;
  frames: number[];
  ticsPerFrame: number;
  fullbright: boolean;
  /** Collision radius in map units (drawn on the automap, unused by the renderer). */
  radius: number;
  /** Height in map units. */
  height: number;
  /** Vanilla MF_SPAWNCEILING: the thing hangs from the ceiling instead of standing on the floor. */
  hangs: boolean;
}

const F = (c: string): number => c.charCodeAt(0) - 65;

function m(
  sprite: string,
  frames: string,
  opts: Partial<Omit<MobjInfo, "sprite" | "frames">> = {},
): MobjInfo {
  return {
    sprite,
    frames: [...frames].map(F),
    ticsPerFrame: opts.ticsPerFrame ?? 6,
    fullbright: opts.fullbright ?? false,
    radius: opts.radius ?? 20,
    height: opts.height ?? 16,
    hangs: opts.hangs ?? false,
  };
}

export const MOBJ_INFO: Readonly<Record<number, MobjInfo>> = {
  // Monsters (spawn states are the two-frame "look" cycle, 10 tics each).
  3004: m("POSS", "AB", { ticsPerFrame: 10, radius: 20, height: 56 }),
  9: m("SPOS", "AB", { ticsPerFrame: 10, radius: 20, height: 56 }),
  3001: m("TROO", "AB", { ticsPerFrame: 10, radius: 20, height: 56 }),
  3002: m("SARG", "AB", { ticsPerFrame: 10, radius: 30, height: 56 }),
  58: m("SARG", "AB", { ticsPerFrame: 10, radius: 30, height: 56 }),
  3003: m("BOSS", "AB", { ticsPerFrame: 10, radius: 24, height: 64 }),
  69: m("BOS2", "AB", { ticsPerFrame: 10, radius: 24, height: 64 }),
  3005: m("HEAD", "A", { ticsPerFrame: 10, radius: 31, height: 56 }),
  3006: m("SKUL", "AB", { ticsPerFrame: 10, fullbright: true, radius: 16, height: 56 }),
  64: m("VILE", "AB", { ticsPerFrame: 10, radius: 20, height: 56 }),
  65: m("CPOS", "AB", { ticsPerFrame: 10, radius: 20, height: 56 }),
  66: m("SKEL", "AB", { ticsPerFrame: 10, radius: 20, height: 56 }),
  67: m("FATT", "AB", { ticsPerFrame: 15, radius: 48, height: 64 }),
  68: m("BSPI", "AB", { ticsPerFrame: 10, radius: 64, height: 64 }),
  71: m("PAIN", "A", { ticsPerFrame: 10, radius: 31, height: 56 }),
  7: m("SPID", "AB", { ticsPerFrame: 10, radius: 128, height: 100 }),
  16: m("CYBD", "AB", { ticsPerFrame: 10, radius: 40, height: 110 }),
  72: m("SSWV", "AB", { ticsPerFrame: 10, radius: 20, height: 56 }),
  84: m("SSWV", "AB", { ticsPerFrame: 10, radius: 20, height: 56 }),

  // Weapons.
  2001: m("SHOT", "A", { radius: 20, height: 16 }),
  82: m("SGN2", "A"),
  2002: m("MGUN", "A"),
  2003: m("LAUN", "A"),
  2004: m("PLAS", "A"),
  2006: m("BFUG", "A"),
  2005: m("CSAW", "A"),

  // Ammo.
  2007: m("CLIP", "A"),
  2048: m("AMMO", "A"),
  2010: m("ROCK", "A"),
  2046: m("BROK", "A"),
  2047: m("CELL", "A"),
  17: m("CELP", "A"),
  2008: m("SHEL", "A"),
  2049: m("SBOX", "A"),
  8: m("BPAK", "A"),

  // Health / armour / powerups (the bonuses animate with a 6-frame brightness cycle).
  2011: m("STIM", "A"),
  2012: m("MEDI", "A"),
  2014: m("BON1", "ABCDCB", { ticsPerFrame: 6, fullbright: false }),
  2015: m("BON2", "ABCDCB", { ticsPerFrame: 6 }),
  2018: m("ARM1", "AB", { ticsPerFrame: 6 }),
  2019: m("ARM2", "AB", { ticsPerFrame: 6 }),
  2013: m("SOUL", "ABCDCB", { ticsPerFrame: 6, fullbright: true }),
  2022: m("PINV", "ABCD", { ticsPerFrame: 6, fullbright: true }),
  2023: m("PSTR", "A", { fullbright: true }),
  2024: m("PINS", "ABCD", { ticsPerFrame: 6, fullbright: true }),
  2025: m("SUIT", "A", { height: 56 }),
  2026: m("PMAP", "ABCDCB", { ticsPerFrame: 6, fullbright: true }),
  2045: m("PVIS", "AB", { ticsPerFrame: 6, fullbright: true }),
  83: m("MEGA", "ABCD", { ticsPerFrame: 6, fullbright: true }),

  // Keys.
  5: m("BKEY", "AB", { ticsPerFrame: 10 }),
  40: m("BSKU", "AB", { ticsPerFrame: 10 }),
  13: m("RKEY", "AB", { ticsPerFrame: 10 }),
  38: m("RSKU", "AB", { ticsPerFrame: 10 }),
  6: m("YKEY", "AB", { ticsPerFrame: 10 }),
  39: m("YSKU", "AB", { ticsPerFrame: 10 }),

  // Obstacles and decorations.
  2035: m("BAR1", "AB", { ticsPerFrame: 6, radius: 10, height: 42 }),
  48: m("ELEC", "A", { radius: 16, height: 128 }),
  30: m("COL1", "A", { radius: 16, height: 52 }),
  31: m("COL2", "A", { radius: 16, height: 40 }),
  32: m("COL3", "A", { radius: 16, height: 52 }),
  33: m("COL4", "A", { radius: 16, height: 40 }),
  37: m("COL6", "A", { radius: 16, height: 40 }),
  36: m("COL5", "AB", { ticsPerFrame: 14, radius: 16, height: 40 }),
  41: m("CEYE", "ABCB", { ticsPerFrame: 6, fullbright: true, radius: 16, height: 57 }),
  42: m("FSKU", "ABC", { ticsPerFrame: 6, fullbright: true, radius: 16, height: 72 }),
  43: m("TRE1", "A", { radius: 16, height: 32 }),
  54: m("TRE2", "A", { radius: 32, height: 106 }),
  47: m("SMIT", "A", { radius: 16, height: 56 }),
  2028: m("COLU", "A", { fullbright: true, radius: 16, height: 48 }),
  35: m("CBRA", "A", { fullbright: true, radius: 16, height: 16 }),
  34: m("CAND", "A", { fullbright: true, radius: 20, height: 16 }),
  44: m("TBLU", "ABCD", { ticsPerFrame: 4, fullbright: true, radius: 16, height: 68 }),
  45: m("TGRN", "ABCD", { ticsPerFrame: 4, fullbright: true, radius: 16, height: 68 }),
  46: m("TRED", "ABCD", { ticsPerFrame: 4, fullbright: true, radius: 16, height: 68 }),
  55: m("SMBT", "ABCD", { ticsPerFrame: 4, fullbright: true, radius: 16, height: 68 }),
  56: m("SMGT", "ABCD", { ticsPerFrame: 4, fullbright: true, radius: 16, height: 68 }),
  57: m("SMRT", "ABCD", { ticsPerFrame: 4, fullbright: true, radius: 16, height: 68 }),
  70: m("FCAN", "ABC", { ticsPerFrame: 4, fullbright: true, radius: 10, height: 68 }),
  85: m("TLMP", "ABCD", { ticsPerFrame: 4, fullbright: true, radius: 16, height: 80 }),
  86: m("TLP2", "ABCD", { ticsPerFrame: 4, fullbright: true, radius: 16, height: 60 }),

  // Corpses (single frames from the end of each death sequence).
  10: m("PLAY", "W", { radius: 16, height: 16 }),
  12: m("PLAY", "W", { radius: 16, height: 16 }),
  15: m("PLAY", "N", { radius: 16, height: 16 }),
  18: m("POSS", "L", { radius: 16, height: 16 }),
  19: m("SPOS", "L", { radius: 16, height: 16 }),
  20: m("TROO", "M", { radius: 16, height: 16 }),
  21: m("SARG", "N", { radius: 16, height: 16 }),
  22: m("HEAD", "L", { radius: 16, height: 16 }),
  23: m("SKUL", "K", { radius: 16, height: 16 }),
  24: m("POL5", "A", { radius: 16, height: 16 }),
  25: m("POL1", "A", { radius: 16, height: 64 }),
  26: m("POL6", "AB", { ticsPerFrame: 6, radius: 16, height: 64 }),
  27: m("POL4", "A", { radius: 16, height: 64 }),
  28: m("POL2", "A", { radius: 16, height: 64 }),
  29: m("POL3", "AB", { ticsPerFrame: 6, fullbright: true, radius: 16, height: 64 }),

  // Hanging bodies (MF_SPAWNCEILING).
  49: m("GOR1", "ABCB", { ticsPerFrame: 6, radius: 16, height: 68, hangs: true }),
  50: m("GOR2", "A", { radius: 16, height: 84, hangs: true }),
  51: m("GOR3", "A", { radius: 16, height: 84, hangs: true }),
  52: m("GOR4", "A", { radius: 16, height: 68, hangs: true }),
  53: m("GOR5", "A", { radius: 16, height: 52, hangs: true }),
  59: m("GOR2", "A", { radius: 16, height: 84, hangs: true }),
  60: m("GOR4", "A", { radius: 16, height: 68, hangs: true }),
  61: m("GOR3", "A", { radius: 16, height: 52, hangs: true }),
  62: m("GOR5", "A", { radius: 16, height: 52, hangs: true }),
  63: m("GOR1", "ABCB", { ticsPerFrame: 6, radius: 16, height: 68, hangs: true }),
  73: m("HDB1", "A", { radius: 16, height: 88, hangs: true }),
  74: m("HDB2", "A", { radius: 16, height: 88, hangs: true }),
  75: m("HDB3", "A", { radius: 16, height: 64, hangs: true }),
  76: m("HDB4", "A", { radius: 16, height: 64, hangs: true }),
  77: m("HDB5", "A", { radius: 16, height: 64, hangs: true }),
  78: m("HDB6", "A", { radius: 16, height: 64, hangs: true }),
  79: m("POB1", "A", { radius: 16, height: 4 }),
  80: m("POB2", "A", { radius: 16, height: 4 }),
  81: m("BRS1", "A", { radius: 16, height: 4 }),
};

/** doomednums that are markers, not drawable things (starts, teleport landings). */
export const NON_DRAWABLE_DOOMEDNUMS = new Set([1, 2, 3, 4, 11, 14, 87, 88, 89]);

export function mobjInfoFor(doomednum: number): MobjInfo | undefined {
  return MOBJ_INFO[doomednum];
}

/** Every sprite prefix a map's things can need, for restricting the sprite atlas. */
export function spritePrefixesFor(doomednums: Iterable<number>): Set<string> {
  const out = new Set<string>();
  for (const n of doomednums) {
    const info = MOBJ_INFO[n];
    if (info) out.add(info.sprite);
  }
  return out;
}

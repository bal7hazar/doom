import { LumpEntry, Wad } from "../wad.js";

/**
 * Sprite frame tables, as `R_InitSpriteDefs` builds them.
 *
 * Sprite lumps are named `NNNN` + frame letter + rotation digit, optionally
 * followed by a *second* frame/rotation pair: `TROOA2A8` supplies frame A
 * rotation 2 directly and frame A rotation 8 mirrored. Rotation `0` means the
 * frame has a single view used from every angle.
 *
 * See `pictures.ts` for the note on why `client/src/wad/` duplicates this.
 */
export interface SpriteFrame {
  /** True when the frame has eight distinct rotations. */
  rotate: boolean;
  /** Lump directory index per rotation 0..7; -1 when absent. */
  lump: number[];
  /** Whether that rotation must be drawn mirrored horizontally. */
  flip: boolean[];
}

export interface SpriteDef {
  name: string;
  /** Indexed by `frameLetter - 'A'`. Sparse in malformed WADs. */
  frames: (SpriteFrame | undefined)[];
}

const A_CODE = "A".charCodeAt(0);
const ZERO_CODE = "0".charCodeAt(0);

/**
 * Builds sprite definitions from the `S_START`/`S_END` block.
 *
 * `prefixes`, when given, restricts the scan: `freedoom1.wad` ships ~1 400
 * sprite lumps and any one map needs a small fraction of them.
 */
export function buildSpriteDefs(wad: Wad, prefixes?: ReadonlySet<string>): Map<string, SpriteDef> {
  const defs = new Map<string, SpriteDef>();
  for (const lump of wad.lumpsBetweenMarkers("S_START", "S_END")) {
    if (lump.name.length !== 6 && lump.name.length !== 8) continue;
    const prefix = lump.name.slice(0, 4);
    if (prefixes && !prefixes.has(prefix)) continue;
    let def = defs.get(prefix);
    if (!def) {
      def = { name: prefix, frames: [] };
      defs.set(prefix, def);
    }
    install(def, lump, lump.name.charCodeAt(4) - A_CODE, lump.name.charCodeAt(5) - ZERO_CODE, false);
    if (lump.name.length === 8) {
      install(def, lump, lump.name.charCodeAt(6) - A_CODE, lump.name.charCodeAt(7) - ZERO_CODE, true);
    }
  }
  return defs;
}

function install(
  def: SpriteDef,
  lump: LumpEntry,
  frame: number,
  rotation: number,
  flipped: boolean,
): void {
  if (frame < 0 || frame > 28 || rotation < 0 || rotation > 8) return;
  let f = def.frames[frame];
  if (!f) {
    f = { rotate: rotation !== 0, lump: new Array(8).fill(-1), flip: new Array(8).fill(false) };
    def.frames[frame] = f;
  }
  if (rotation === 0) {
    f.rotate = false;
    for (let r = 0; r < 8; r++) {
      f.lump[r] = lump.index;
      f.flip[r] = flipped;
    }
    return;
  }
  f.rotate = true;
  f.lump[rotation - 1] = lump.index;
  f.flip[rotation - 1] = flipped;
}

/**
 * `R_ProjectSprite`'s rotation pick:
 *
 *     rot = (angleFromViewerToThing - thingAngle + (ANG45/2)*9) >> 29
 *
 * in 32-bit BAM arithmetic modulo 2^32, which is what makes the 4.5×45° bias
 * centre the eight buckets. Returns 0..7, 0 being "facing the viewer".
 */
export function spriteRotation(viewToThingBam: number, thingAngleBam: number): number {
  const bias = 0x10000000 * 9;
  return (((viewToThingBam - thingAngleBam + bias) >>> 0) >>> 29) & 7;
}

/** Which frames a sprite actually ships, as a diagnostic for the extraction report. */
export function frameLetters(def: SpriteDef): string {
  return def.frames
    .map((f, i) => (f ? String.fromCharCode(A_CODE + i) : ""))
    .join("");
}

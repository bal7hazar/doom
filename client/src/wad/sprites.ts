import type { LumpEntry, Wad } from "./wad.js";

/**
 * One frame of a sprite, in the shape `R_InitSpriteDefs` builds.
 *
 * `rotate === false` means the frame has a single lump (`…A0`) used from every
 * viewing angle — items, decorations, explosions. `rotate === true` means the
 * eight `…A1`..`…A8` views are present, some of them as mirrored duplicates:
 * a lump named `TROOA2A8` supplies rotation 2 directly and rotation 8 flipped.
 */
export interface SpriteFrame {
  rotate: boolean;
  /** Lump index per rotation 0..7 (index 0 is the only valid one when `rotate` is false). */
  lump: Int32Array;
  /** Whether that rotation must be drawn mirrored horizontally. */
  flip: Uint8Array;
}

export interface SpriteDef {
  name: string;
  /** Frames indexed by `frameChar - 'A'`; holes are possible in malformed WADs. */
  frames: SpriteFrame[];
}

const A_CODE = "A".charCodeAt(0);
const ZERO_CODE = "0".charCodeAt(0);

/**
 * Builds sprite definitions for the requested 4-character prefixes by scanning
 * the `S_START`/`S_END` block, mirroring `R_InitSpriteDefs`.
 *
 * Restricting to a set of prefixes matters: `freedoom1.wad` ships ~1 400 sprite
 * lumps, and E1M1 needs roughly a fifth of them. Pass `undefined` to take
 * everything.
 */
export function buildSpriteDefs(wad: Wad, prefixes?: ReadonlySet<string>): Map<string, SpriteDef> {
  const defs = new Map<string, SpriteDef>();
  for (const lump of wad.between("S_START", "S_END")) {
    const name = lump.name;
    if (name.length !== 6 && name.length !== 8) continue;
    const prefix = name.slice(0, 4);
    if (prefixes && !prefixes.has(prefix)) continue;
    let def = defs.get(prefix);
    if (!def) {
      def = { name: prefix, frames: [] };
      defs.set(prefix, def);
    }
    installLump(def, lump, name.charCodeAt(4) - A_CODE, name.charCodeAt(5) - ZERO_CODE, false);
    if (name.length === 8) {
      installLump(def, lump, name.charCodeAt(6) - A_CODE, name.charCodeAt(7) - ZERO_CODE, true);
    }
  }
  return defs;
}

function installLump(
  def: SpriteDef,
  lump: LumpEntry,
  frame: number,
  rotation: number,
  flipped: boolean,
): void {
  if (frame < 0 || frame > 28 || rotation < 0 || rotation > 8) return;
  let f = def.frames[frame];
  if (!f) {
    f = { rotate: rotation !== 0, lump: new Int32Array(8).fill(-1), flip: new Uint8Array(8) };
    def.frames[frame] = f;
  }
  if (rotation === 0) {
    f.rotate = false;
    for (let r = 0; r < 8; r++) {
      f.lump[r] = lump.index;
      f.flip[r] = flipped ? 1 : 0;
    }
    return;
  }
  f.rotate = true;
  f.lump[rotation - 1] = lump.index;
  f.flip[rotation - 1] = flipped ? 1 : 0;
}

/**
 * Doom's sprite-rotation selection (`R_ProjectSprite`):
 *
 *     ang = R_PointToAngle(thing->x, thing->y);        // viewer -> thing
 *     rot = (ang - thing->angle + (unsigned)(ANG45/2)*9) >> 29;
 *
 * All three quantities are 32-bit BAM angles and the arithmetic is modulo
 * 2^32, which is what makes the `+ (ANG45/2)*9` bias — 4.5 × 45° — land the
 * eight 45°-wide buckets on their centres. `>> 29` is the unsigned shift that
 * turns the biased angle into 0..7.
 *
 * @param viewToThingBam BAM angle from the *camera* to the thing.
 * @param thingAngleBam  BAM angle the thing is facing.
 * @returns rotation index 0..7, where 0 is "facing the camera".
 */
export function spriteRotation(viewToThingBam: number, thingAngleBam: number): number {
  const ANG45 = 0x20000000;
  const bias = (ANG45 / 2) * 9; // 2415919104, fits in a float exactly
  const biased = (viewToThingBam - thingAngleBam + bias) >>> 0;
  return (biased >>> 29) & 7;
}

/** Picks the lump (and mirroring) for a frame at a given view/facing pair. */
export function selectSpriteLump(
  frame: SpriteFrame,
  viewToThingBam: number,
  thingAngleBam: number,
): { lump: number; flip: boolean } | null {
  const rot = frame.rotate ? spriteRotation(viewToThingBam, thingAngleBam) : 0;
  const lump = frame.lump[rot] ?? -1;
  if (lump < 0) return null;
  return { lump, flip: frame.flip[rot] === 1 };
}

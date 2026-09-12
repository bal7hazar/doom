import { LumpEntry, Wad } from "../wad.js";

/** A flat (floor/ceiling texture, always 64x64 raw palette-index pixels) lump entry. */
export interface FlatEntry {
  name: string;
  size: number;
  lumpIndex: number;
}

/** A sprite (patch-format picture, e.g. "TROOA1") lump entry. */
export interface SpriteEntry {
  name: string;
  size: number;
  lumpIndex: number;
}

export function listFlats(wad: Wad): FlatEntry[] {
  return wad.lumpsBetweenMarkers("F_START", "F_END").map(toEntry);
}

export function listSprites(wad: Wad): SpriteEntry[] {
  return wad.lumpsBetweenMarkers("S_START", "S_END").map(toEntry);
}

function toEntry(l: LumpEntry): FlatEntry {
  return { name: l.name, size: l.size, lumpIndex: l.index };
}

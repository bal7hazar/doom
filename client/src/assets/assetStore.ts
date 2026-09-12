import {
  buildSpriteDefs,
  composeTexture,
  decodeFlat,
  decodePatch,
  parseColormap,
  parsePlaypal,
  readPnames,
  readTextureDefs,
  Wad,
  type Colormap,
  type Picture,
  type Playpal,
  type SpriteDef,
} from "@hellproof/wad";
import type { LevelJson } from "../map/level.js";
import { SKY_FLAT } from "../map/level.js";
import { mobjInfoFor } from "../map/mobjInfo.js";
import { packAtlas, type Atlas, type AtlasEntry } from "./atlas.js";

/** Atlas key namespaces: a wall texture and a flat may legitimately share a name. */
export const texKey = (name: string): string => `T:${name.toUpperCase()}`;
export const flatKey = (name: string): string => `F:${name.toUpperCase()}`;
export const spriteKey = (lumpIndex: number): string => `S:${lumpIndex}`;

/** The first-person weapon sprites, indexed by `weapontype_t`. */
export const WEAPON_SPRITES = [
  "PUNG", // 0 fist
  "PISG", // 1 pistol
  "SHTG", // 2 shotgun
  "CHGG", // 3 chaingun
  "MISG", // 4 rocket launcher
  "PLSG", // 5 plasma rifle
  "BFGG", // 6 BFG
  "SAWG", // 7 chainsaw
  "SHT2", // 8 super shotgun (Doom II; absent from freedoom1)
] as const;

export interface AssetStore {
  wad: Wad;
  playpal: Playpal;
  colormap: Colormap;
  /** Wall textures *and* flats, keyed with `texKey`/`flatKey`. */
  surfaceAtlas: Atlas;
  /** Every sprite frame needed by the level plus the weapon sprites. */
  spriteAtlas: Atlas;
  spriteDefs: Map<string, SpriteDef>;
  /** Sky texture name for this map (`SKY1` for E1M*) and its atlas key. */
  skyTexture: string;
  stats: {
    wallTextures: number;
    flats: number;
    spriteLumps: number;
    missing: string[];
    surfaceAtlasSize: number;
    spriteAtlasSize: number;
    decodeMs: number;
  };
}

export interface LoadProgress {
  (stage: string, fraction: number): void;
}

/**
 * Builds every GPU-ready asset the renderer needs from the IWAD and the level
 * JSON (roadmap P2.1).
 *
 * Only what the level references is decoded: E1M1 names 113 wall textures and
 * 44 flats out of the IWAD's full set, and ~30 of its ~1 400 sprite prefixes.
 * Decoding everything would multiply load time and atlas size for nothing.
 */
export function buildAssetStore(
  wadBytes: Uint8Array,
  level: LevelJson,
  progress: LoadProgress = () => {},
): AssetStore {
  const t0 = performance.now();
  const wad = Wad.fromBytes(wadBytes);
  const missing: string[] = [];

  progress("palette", 0.05);
  const playpal = parsePlaypal(wad.lumpDataByName("PLAYPAL"));
  const colormap = parseColormap(wad.lumpDataByName("COLORMAP"));

  progress("wall textures", 0.1);
  const pnames = readPnames(wad);
  const defs = readTextureDefs(wad);
  const patchCache = new Map<string, Picture>();

  const skyTexture = skyTextureFor(level.map, defs);
  const wanted = new Set(level.assets.referencedTextures.map((n) => n.toUpperCase()));
  wanted.add(skyTexture);

  const surfaceEntries: AtlasEntry[] = [];
  for (const name of wanted) {
    const def = defs.get(name);
    if (!def) {
      missing.push(`texture ${name}`);
      continue;
    }
    surfaceEntries.push({ key: texKey(name), picture: composeTexture(wad, def, pnames, patchCache) });
  }
  const wallTextures = surfaceEntries.length;

  progress("flats", 0.35);
  let flats = 0;
  for (const raw of level.assets.referencedFlats) {
    const name = raw.toUpperCase();
    if (name === SKY_FLAT) continue; // never drawn: the sky pass covers it
    const entry = wad.findLump(name);
    if (!entry) {
      missing.push(`flat ${name}`);
      continue;
    }
    try {
      surfaceEntries.push({ key: flatKey(name), picture: decodeFlat(wad.lumpData(entry)) });
      flats++;
    } catch (err) {
      missing.push(`flat ${name} (${(err as Error).message})`);
    }
  }

  progress("packing surfaces", 0.5);
  const surfaceAtlas = packAtlas(surfaceEntries);
  for (const key of surfaceAtlas.overflow) missing.push(`overflow ${key}`);

  progress("sprites", 0.6);
  const prefixes = new Set<string>();
  for (const thing of level.things) {
    const info = mobjInfoFor(thing.type);
    if (info) prefixes.add(info.sprite);
  }
  for (const w of WEAPON_SPRITES) prefixes.add(w);
  // The player's own corpse/gib sprites are needed the moment the sim kills us.
  prefixes.add("PLAY");

  const spriteDefs = buildSpriteDefs(wad, prefixes);
  const spriteEntries: AtlasEntry[] = [];
  const seenLumps = new Set<number>();
  for (const def of spriteDefs.values()) {
    for (const frame of def.frames) {
      if (!frame) continue;
      for (const lumpIndex of frame.lump) {
        if (lumpIndex < 0 || seenLumps.has(lumpIndex)) continue;
        seenLumps.add(lumpIndex);
        try {
          spriteEntries.push({
            key: spriteKey(lumpIndex),
            picture: decodePatch(wad.lumpData(wad.lumps[lumpIndex]!)),
          });
        } catch (err) {
          missing.push(`sprite lump ${lumpIndex} (${(err as Error).message})`);
        }
      }
    }
  }

  progress("packing sprites", 0.85);
  const spriteAtlas = packAtlas(spriteEntries);
  for (const key of spriteAtlas.overflow) missing.push(`overflow ${key}`);

  progress("ready", 1);
  return {
    wad,
    playpal,
    colormap,
    surfaceAtlas,
    spriteAtlas,
    spriteDefs,
    skyTexture,
    stats: {
      wallTextures,
      flats,
      spriteLumps: spriteEntries.length,
      missing,
      surfaceAtlasSize: surfaceAtlas.width,
      spriteAtlasSize: spriteAtlas.width,
      decodeMs: performance.now() - t0,
    },
  };
}

/**
 * Vanilla `R_Init`'s sky choice: `SKY1` for episode 1, `SKY2` for 2, `SKY3` for
 * 3 and 4. Falls back to whatever sky texture the IWAD does define, so a PWAD
 * with a single sky still renders.
 */
export function skyTextureFor(mapName: string, defs: Map<string, unknown>): string {
  const match = /^E(\d)M\d$/.exec(mapName.toUpperCase());
  const episode = match ? Number(match[1]) : 1;
  const preferred = episode >= 4 ? "SKY4" : `SKY${episode}`;
  if (defs.has(preferred)) return preferred;
  for (const candidate of ["SKY1", "SKY2", "SKY3", "SKY4"]) {
    if (defs.has(candidate)) return candidate;
  }
  return "SKY1";
}

/** Size lookup for the wall-quad builder; `undefined` means "not in the atlas". */
export function textureSizeLookup(store: AssetStore) {
  return (name: string): { width: number; height: number } | undefined => {
    const rect = store.surfaceAtlas.rects.get(texKey(name));
    return rect ? { width: rect.width, height: rect.height } : undefined;
  };
}

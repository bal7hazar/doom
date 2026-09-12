import { BinaryReader } from "./binary.js";
import { blit, decodePicture, emptyPicture, type Picture } from "./picture.js";
import type { Wad } from "./wad.js";

export interface TexturePatch {
  originX: number;
  originY: number;
  patch: number; // index into PNAMES
}

export interface TextureDef {
  name: string;
  width: number;
  height: number;
  patches: TexturePatch[];
}

/** `PNAMES`: the patch-name table `TEXTUREn` entries index into. */
export function parsePnames(bytes: Uint8Array): string[] {
  const r = new BinaryReader(bytes);
  const count = r.int32();
  if (count < 0) throw new Error(`PNAMES: negative count ${count}`);
  const names = new Array<string>(count);
  for (let i = 0; i < count; i++) names[i] = r.name(8).toUpperCase();
  return names;
}

/**
 * `TEXTURE1`/`TEXTURE2`: an int32 count, that many int32 offsets, then a
 * `maptexture_t` per offset (22-byte header + 10 bytes per patch placement).
 */
export function parseTextureLump(bytes: Uint8Array): TextureDef[] {
  const head = new BinaryReader(bytes);
  const count = head.int32();
  if (count < 0) throw new Error(`TEXTUREx: negative count ${count}`);
  const offsets = new Array<number>(count);
  for (let i = 0; i < count; i++) offsets[i] = head.int32();

  const out: TextureDef[] = [];
  for (const offset of offsets) {
    if (offset < 0 || offset + 22 > bytes.length) {
      throw new Error(`TEXTUREx: definition offset ${offset} out of bounds`);
    }
    const r = new BinaryReader(bytes, offset);
    const name = r.name(8);
    r.skip(4); // masked flag: unused by every known engine
    const width = r.int16();
    const height = r.int16();
    r.skip(4); // columndirectory: obsolete
    const patchCount = r.int16();
    const patches: TexturePatch[] = [];
    for (let p = 0; p < patchCount; p++) {
      const originX = r.int16();
      const originY = r.int16();
      const patch = r.int16();
      r.skip(4); // stepdir, colormap: unused
      patches.push({ originX, originY, patch });
    }
    out.push({ name, width, height, patches });
  }
  return out;
}

/**
 * Composes one wall texture from its patches, exactly as `R_GenerateComposite`
 * does: patches are blitted in definition order at their (originX, originY),
 * later patches overwrite earlier ones where they have coverage, and anything
 * still uncovered stays transparent (two-sided middle textures rely on it).
 *
 * `patchCache` memoises decoded patches: E1M1's 113 textures reference the same
 * few hundred patches many times over, and decoding is the expensive half.
 */
export function composeTexture(
  def: TextureDef,
  pnames: string[],
  wad: Wad,
  patchCache: Map<string, Picture>,
): Picture {
  const out = emptyPicture(def.width, def.height);
  for (const p of def.patches) {
    const patchName = pnames[p.patch];
    if (patchName === undefined) {
      throw new Error(`Texture ${def.name}: patch index ${p.patch} outside PNAMES (${pnames.length})`);
    }
    let picture = patchCache.get(patchName);
    if (!picture) {
      const entry = wad.find(patchName);
      if (!entry) {
        // Some IWADs list patches they do not ship; vanilla errors out, but a
        // missing patch must not take down the whole level load.
        console.warn(`Texture ${def.name}: patch lump ${patchName} missing, skipped`);
        continue;
      }
      picture = decodePicture(wad.lumpData(entry));
      patchCache.set(patchName, picture);
    }
    blit(out, picture, p.originX, p.originY);
  }
  return out;
}

/** Reads `TEXTURE1` (+ `TEXTURE2` when present) into one name → definition map. */
export function readTextureDefs(wad: Wad): Map<string, TextureDef> {
  const defs = new Map<string, TextureDef>();
  for (const lump of ["TEXTURE1", "TEXTURE2"]) {
    const entry = wad.find(lump);
    if (!entry) continue;
    for (const def of parseTextureLump(wad.lumpData(entry))) {
      // Later lumps override earlier ones, matching the engine's lump order.
      defs.set(def.name.toUpperCase(), def);
    }
  }
  return defs;
}

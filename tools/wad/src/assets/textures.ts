import { BinaryReader } from "../binary.js";

/** PNAMES lump: the list of patch lump names texture definitions refer to by index. */
export interface Pnames {
  names: string[]; // 8-char patch lump names, index = patch number referenced by TEXTUREn
}

export function parsePnames(buffer: Buffer): Pnames {
  const r = new BinaryReader(buffer);
  const numPatches = r.int32();
  if (numPatches < 0) throw new Error(`PNAMES: negative count ${numPatches}`);
  const names: string[] = [];
  for (let i = 0; i < numPatches; i++) {
    names.push(r.name(8));
  }
  return { names };
}

/** One patch placement within a composite texture (`mappatch_t`, 10 bytes). */
export interface TexturePatch {
  originX: number; // int16, x offset of the patch's top-left within the texture
  originY: number; // int16, y offset of the patch's top-left within the texture
  patch: number; // int16 index into PNAMES
}

/** One composite texture definition (`maptexture_t`, header 22 bytes + 10 bytes/patch). */
export interface TextureDef {
  name: string; // 8-char texture name, referenced by SIDEDEFS/flats-adjacent walls
  width: number; // int16, texture width in pixels
  height: number; // int16, texture height in pixels
  patches: TexturePatch[];
}

export interface TextureLump {
  textures: TextureDef[];
}

/** Parses TEXTURE1 or TEXTURE2: an int32 count, then that many int32 offsets, then the definitions. */
export function parseTextureLump(buffer: Buffer): TextureLump {
  const header = new BinaryReader(buffer);
  const numTextures = header.int32();
  if (numTextures < 0) throw new Error(`TEXTUREx: negative count ${numTextures}`);
  const offsets: number[] = [];
  for (let i = 0; i < numTextures; i++) {
    offsets.push(header.int32());
  }

  const textures: TextureDef[] = [];
  for (const offset of offsets) {
    if (offset < 0 || offset + 22 > buffer.length) {
      throw new Error(`TEXTUREx: texture definition offset ${offset} out of bounds`);
    }
    const r = new BinaryReader(buffer, offset);
    const name = r.name(8);
    r.skip(4); // "masked" flag - unused by the renderer, kept only for format fidelity
    const width = r.int16();
    const height = r.int16();
    r.skip(4); // "columndirectory" - obsolete, ignored by every known engine
    const patchCount = r.int16();
    const patches: TexturePatch[] = [];
    for (let p = 0; p < patchCount; p++) {
      const originX = r.int16();
      const originY = r.int16();
      const patch = r.int16();
      r.skip(4); // stepdir, colormap - unused
      patches.push({ originX, originY, patch });
    }
    textures.push({ name, width, height, patches });
  }
  return { textures };
}

/** Patch picture header (`patch_t`, first 8 bytes): width/height/offsets; column data follows. */
export interface PatchHeader {
  width: number; // uint16, pixels
  height: number; // uint16, pixels
  leftOffset: number; // int16, pixels to shift left when drawing (relative to origin)
  topOffset: number; // int16, pixels to shift up when drawing
}

export function parsePatchHeader(buffer: Buffer): PatchHeader {
  const r = new BinaryReader(buffer);
  const width = r.uint16();
  const height = r.uint16();
  const leftOffset = r.int16();
  const topOffset = r.int16();
  return { width, height, leftOffset, topOffset };
}

/**
 * Generates the asset-decoding fixtures from `freedoom1.wad`.
 *
 *   npm run fixtures                       # uses tools/wad's default WAD path
 *   WAD=/path/to/freedoom1.wad npm run fixtures
 *
 * The expected pixels are produced by `@hellproof/wad` (tools/wad), the same
 * package the client itself imports for asset decoding: `test/wadDecode.test.ts`
 * then checks that package's output against this fixture as a regression/
 * snapshot check. The raw lump bytes are embedded too, so the test can also
 * verify structural invariants straight from the on-disk format without
 * trusting the decoder.
 *
 * Output is gitignored: it is derived from a WAD, and WADs never enter git.
 * Tests skip themselves when it is absent.
 *
 * This file is excluded from `tsconfig.json` on purpose - it runs under
 * `tsx`, never through Vite/vitest's build.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  buildSpriteDefs,
  composeTexture,
  decodeFlat,
  decodePatch,
  parseColormap,
  parsePlaypal,
  readPnames,
  readTextureDefs,
  spriteRotation,
  Wad,
  type Picture,
} from "@hellproof/wad";

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_WAD =
  "/private/tmp/claude-501/-Users-bal7hazar-git-doom/052c133d-8e48-4871-8024-3d2fd1081b4c/scratchpad/freedoom/freedoom1.wad";

const wadPath = resolve(process.env.WAD ?? DEFAULT_WAD);
// Reading the file is the caller's job (this script), not the library's -
// `Wad.fromBytes` is the only entry point @hellproof/wad exposes.
const wad = Wad.fromBytes(readFileSync(wadPath));

const b64 = (bytes: Uint8Array): string => Buffer.from(bytes).toString("base64");

const picture = (p: Picture) => ({
  width: p.width,
  height: p.height,
  leftOffset: p.leftOffset,
  topOffset: p.topOffset,
  pixels: b64(p.pixels),
  mask: b64(p.mask),
});

// --- a patch: the first sprite lump of the imp, small and definitely masked ---
const patchLumpName = "TROOA1";
const patchEntry = wad.findLump(patchLumpName);
if (!patchEntry) throw new Error(`${patchLumpName} not found in ${wadPath}`);
const patchBytes = wad.lumpData(patchEntry);

// --- a flat ---
const flatLumpName = "FLOOR0_3";
const flatEntry = wad.findLump(flatLumpName);
if (!flatEntry) throw new Error(`${flatLumpName} not found in ${wadPath}`);

// --- a composed wall texture: the smallest multi-patch TEXTURE1 entry ---
const defs = readTextureDefs(wad);
const pnames = readPnames(wad);
const multiPatch = [...defs.values()]
  .filter((d) => d.patches.length >= 2 && d.width <= 128 && d.height <= 128)
  .sort((a, b) => a.width * a.height - b.width * b.height)[0];
if (!multiPatch) throw new Error("No suitable multi-patch texture found");

// --- sprite frame table for the imp, plus rotation expectations ---
const spriteDefs = buildSpriteDefs(wad, new Set(["TROO", "BON1"]));
const troo = spriteDefs.get("TROO");
if (!troo) throw new Error("TROO sprite frames not found");
const bon1 = spriteDefs.get("BON1");
if (!bon1) throw new Error("BON1 sprite frames not found");

const ANG45 = 0x20000000;
const rotationCases = [0, 1, 2, 3, 4, 5, 6, 7].map((i) => {
  const viewToThing = (i * ANG45) >>> 0;
  return { viewToThing, thingAngle: 0, expected: spriteRotation(viewToThing, 0) };
});

const playpal = parsePlaypal(wad.lumpDataByName("PLAYPAL"));
const colormap = parseColormap(wad.lumpDataByName("COLORMAP"));

const fixture = {
  wad: { path: wadPath, lumps: wad.lumps.length, identification: wad.header.identification },
  patch: {
    name: patchLumpName,
    lumpIndex: patchEntry.index,
    raw: b64(patchBytes),
    decoded: picture(decodePatch(patchBytes)),
  },
  flat: {
    name: flatLumpName,
    raw: b64(wad.lumpData(flatEntry)),
    decoded: picture(decodeFlat(wad.lumpData(flatEntry))),
  },
  texture: {
    name: multiPatch.name,
    width: multiPatch.width,
    height: multiPatch.height,
    patches: multiPatch.patches.map((p) => ({
      originX: p.originX,
      originY: p.originY,
      name: pnames[p.patch],
    })),
    decoded: picture(composeTexture(wad, multiPatch, pnames)),
  },
  sprites: {
    TROO: {
      frameCount: troo.frames.length,
      // Frame A: eight rotations, several of them mirrored duplicates.
      frameA: troo.frames[0]
        ? { rotate: troo.frames[0].rotate, lump: troo.frames[0].lump, flip: troo.frames[0].flip }
        : null,
      lumpNames: troo.frames[0]?.lump.map((i) => (i >= 0 ? wad.lumps[i]!.name : null)) ?? [],
    },
    BON1: {
      // An item: one view for every angle.
      frameA: bon1.frames[0]
        ? { rotate: bon1.frames[0].rotate, lump: bon1.frames[0].lump, flip: bon1.frames[0].flip }
        : null,
    },
    rotationCases,
  },
  palette: {
    count: playpal.paletteCount,
    // First eight colours of palette 0 and of the damage palette 1.
    palette0: playpal.palettes[0]!.slice(0, 8),
    palette1: playpal.palettes[1]!.slice(0, 8),
  },
  colormap: {
    mapCount: colormap.mapCount,
    // Row 0 is the identity map in every vanilla-derived COLORMAP.
    row0: colormap.maps[0]!.slice(0, 16),
    row16: colormap.maps[16]!.slice(0, 16),
    row31: colormap.maps[31]!.slice(0, 16),
  },
};

const outDir = join(HERE, "generated");
mkdirSync(outDir, { recursive: true });
const outPath = join(outDir, "pictures.json");
writeFileSync(outPath, JSON.stringify(fixture) + "\n");
console.error(`Wrote ${outPath} (${(JSON.stringify(fixture).length / 1024).toFixed(0)} kB)`);
console.error(
  `  patch ${patchLumpName} ${fixture.patch.decoded.width}x${fixture.patch.decoded.height}, ` +
    `texture ${multiPatch.name} ${multiPatch.width}x${multiPatch.height} (${multiPatch.patches.length} patches)`,
);

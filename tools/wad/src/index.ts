/**
 * Public entry point for `@hellproof/wad`.
 *
 * Everything re-exported from here is browser-safe: no module reachable
 * through this file imports anything from `node:*`. `src/cli.ts` (the
 * `extract` command, which reads the WAD file from disk and writes the
 * JSON/Cairo/report outputs) is Node-only and lives outside this barrel on
 * purpose - it is the tool's CLI, not the library.
 *
 * `recordPacking.ts` and `v2Packing.ts` (the Cairo bit-packing schemes) are
 * re-exported as namespaces rather than flattened: both modules export an
 * `unpackBBox` that means something different in each (a single-felt legacy
 * layout vs. the v2 two-felt biased layout), so flattening both with
 * `export *` would be an ambiguous re-export.
 */
export * from "./binary.js";
export * from "./wad.js";
export * from "./types.js";
export * from "./mapLumps.js";
export * from "./mapExtract.js";
export * from "./derive.js";
export * from "./predicates.js";
export * from "./accelerator.js";
export * from "./packing.js";
export * from "./emitConfig.js";
export * from "./cairoOutput.js";
export * from "./bytecodeBudget.js";
export * from "./jsonOutput.js";
export * from "./report.js";
export * from "./reportV2.js";
export * from "./lookup/linedefSpecials.js";
export * from "./lookup/sectorSpecials.js";
export * from "./lookup/thingTypes.js";

export * from "./assets/colormap.js";
export * from "./assets/markers.js";
export * from "./assets/playpal.js";
export * from "./assets/pictures.js";
export * from "./assets/spriteFrames.js";
export * from "./assets/textures.js";

export * as recordPacking from "./recordPacking.js";
export * as v2Packing from "./v2Packing.js";

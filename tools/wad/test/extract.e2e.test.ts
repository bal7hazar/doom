import { describe, expect, it } from "vitest";
import { buildMapCairo } from "../src/cairoOutput.js";
import { buildMapJson } from "../src/jsonOutput.js";
import { extractAssetIndex, extractMap } from "../src/mapExtract.js";
import { buildReport } from "../src/report.js";
import { rejectChunksPerRow } from "../src/recordPacking.js";
import { Wad } from "../src/wad.js";
import { hasRealWad, readRealWad } from "./realWad.js";

// This test exercises the full pipeline against the real freedoom1.wad
// (fetched by scripts/fetch-freedoom.sh). It is skipped when the WAD isn't
// present so `npm test` stays hermetic by default; run
// `./scripts/fetch-freedoom.sh` first to enable it.
describe.skipIf(!hasRealWad)("end-to-end extraction of E1M1 from the real freedoom1.wad", () => {
  const wad = Wad.fromBytes(readRealWad());
  const map = extractMap(wad, "E1M1");
  const assets = extractAssetIndex(wad, map);

  it("matches the known-good lump counts (snapshot)", () => {
    expect({
      vertexes: map.vertexes.length,
      things: map.things.length,
      linedefs: map.linedefs.length,
      sidedefs: map.sidedefs.length,
      segs: map.segs.length,
      subsectors: map.subsectors.length,
      nodes: map.nodes.length,
      sectors: map.sectors.length,
      rejectBytes: map.reject.data.length,
      rejectChunksPerRow: rejectChunksPerRow(map.reject.numSectors),
      blockmapColumns: map.blockmap.columns,
      blockmapRows: map.blockmap.rows,
    }).toMatchSnapshot();
  });

  it("every linedef's vertex indices are within range", () => {
    for (const l of map.linedefs) {
      expect(l.startVertex).toBeLessThan(map.vertexes.length);
      expect(l.endVertex).toBeLessThan(map.vertexes.length);
    }
  });

  it("every sidedef's sector index is within range", () => {
    for (const s of map.sidedefs) {
      expect(s.sector).toBeLessThan(map.sectors.length);
    }
  });

  it("every seg's linedef index is within range", () => {
    for (const s of map.segs) {
      expect(s.linedef).toBeLessThan(map.linedefs.length);
    }
  });

  it("every blockmap cell offset addresses a position inside the BLOCKMAP lump", () => {
    for (const off of map.blockmap.cellOffsets) {
      expect(off * 2).toBeLessThan(map.blockmapLumpBuffer.length);
    }
  });

  it("produces exactly one player 1 start (doomednum 1)", () => {
    expect(map.things.filter((t) => t.type === 1)).toHaveLength(1);
  });

  it("builds JSON output without throwing and with consistent counts, keeping SEGS and texture names", () => {
    const json = buildMapJson(map, assets);
    expect(json.counts.linedefs).toBe(map.linedefs.length);
    expect(json.vertexes).toHaveLength(map.vertexes.length);
    // The client still needs SEGS and texture/flat names for rendering even
    // though cairoOutput.ts v2 drops both (task item 1).
    expect(json.segs).toHaveLength(map.segs.length);
    expect(json.sidedefs.some((s) => s.middleTexture !== "-" && s.middleTexture !== "")).toBe(true);
    expect(json.derived.subsectorSectors).toHaveLength(map.subsectors.length);
  });

  it("builds Cairo output that stays within the documented packing widths, using the default (recommended) layout", () => {
    const { source: cairo, arrays } = buildMapCairo(map);
    // Hot/planar groups (default emit-config.json): struct-of-arrays, one const per field.
    expect(cairo).toContain("pub const VERTEX_X: [u32;");
    expect(cairo).toContain("pub const LINEDEF_AB: [felt252;");
    expect(cairo).toContain("pub const LINEDEF_BB: [felt252;");
    expect(cairo).toContain("pub const LINEDEF_CB: [felt252;");
    expect(cairo).toContain("pub const NODE_AB: [felt252;");
    expect(cairo).toContain("pub const BLOCKMAP_WORDS: [u32;");
    expect(cairo).toContain("pub const ACCEL_START: [u32;");
    // Cold/packed groups (includes bbox/sides/accelerator - see emitConfig.ts for why).
    expect(cairo).toContain("pub const REJECT_ROWS: [felt252;");
    expect(cairo).toContain("pub const THINGS: [felt252;");
    expect(cairo).toContain("pub const SS_SECTOR_PACKED: [felt252;");
    expect(cairo).toContain("pub const ACCEL_SUBSECTORS_PACKED: [felt252;");
    expect(cairo).toContain("pub const LINEDEF_BBOX_LR: [felt252;");
    expect(cairo).toContain("pub const LINEDEF_SIDES: [u32;");
    // v2 drops SEGS and texture names from the Cairo output (task item 1);
    // they stay in the JSON output only (checked below).
    expect(cairo).not.toContain("pub const SEGS");
    expect(cairo).not.toContain("TEXTURE");
    // Spot-check: no felt252 hex literal in the file should reach 2^128.
    const hexLiterals = cairo.match(/0x[0-9a-f]+/g) ?? [];
    expect(hexLiterals.length).toBeGreaterThan(1000);
    for (const lit of hexLiterals) {
      expect(BigInt(lit) < (1n << 128n)).toBe(true);
    }
    // Every array actually written to `source` was accounted for in the budget metadata.
    expect(arrays.length).toBeGreaterThan(20);
  });

  it("builds a non-empty report mentioning the map name and at least one monster", () => {
    const report = buildReport(map, assets);
    expect(report).toContain("E1M1");
    expect(report).toMatch(/monster/);
  });
});

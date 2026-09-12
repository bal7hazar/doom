/**
 * WAD tool v2 Cairo emitter (task "WAD tool v2", RISKS.md R2-A9/R2-A12,
 * docs/spikes/S1.md, docs/G0.md D4).
 *
 * v1 packed every lump into one felt252/u32 per record. S1 (§5.1, §5.3)
 * measured that this is a net loss for data read often (planar
 * struct-of-arrays is cheaper to read *and* the "one felt per const" rule
 * makes packing's only real advantage - fewer bytecode words - matter only
 * for data read rarely (§5.9). v2 replaces the fixed v1 layout with a
 * per-group choice (`emitConfig.ts`) and:
 *
 *   - drops SEGS and texture/flat names entirely from the Cairo output
 *     (kept in the JSON output for the client) - the simulation does not
 *     need either: geometry is precomputed into half-plane predicates
 *     (R2-A4) and subsector -> sector is resolved once here, at extraction
 *     time (`derive.ts#computeSubsectorSectors`), not from SEGS at runtime;
 *   - emits the half-plane predicate coefficients for linedefs and BSP
 *     node partitions (`predicates.ts`) so the Cairo core never
 *     recomputes `cross = A*y + B*x + C` from raw vertices;
 *   - emits the R2-A9 cell -> subsector accelerator (`accelerator.ts`) so
 *     the Cairo core does not need a full BSP descent (or SEGS) to find
 *     "which subsector is this point in" in the common case;
 *   - tracks the element count of every array it writes and hands it back
 *     to the caller for the bytecode budget report (`bytecodeBudget.ts`).
 */
import { computeCellSubsectors } from "./accelerator.js";
import { ArrayEntry } from "./bytecodeBudget.js";
import { DEFAULT_EMIT_CONFIG, EmitConfig } from "./emitConfig.js";
import { MapData } from "./mapExtract.js";
import { bias16, nameToU64, raw16 } from "./packing.js";
import { FixedBBox, HalfPlane, linedefFixedBBox, linedefPredicate, nodePredicate, PRED_BIGC, PRED_FRACUNIT, PRED_HK, PRED_OFF } from "./predicates.js";
import { packBlockmapHeader, packBlockmapWords, packNodeChildren, packRejectRows, packThing, packVertex, rejectChunksPerRow } from "./recordPacking.js";
import {
  packBBoxBT,
  packBBoxLR,
  packIndices,
  packLinedefFlags,
  packLinedefSides,
  packLinedefSpecial,
  packPredicate,
  packSectorHeights,
  packSectorMeta,
} from "./v2Packing.js";

/** How many packed indices/sector-refs share one felt252 in "packed" layout (see `v2Packing.ts#packIndices`). */
const INDICES_PER_FELT = 8;

function hex(v: bigint): string {
  return `0x${v.toString(16)}`;
}

export interface CairoEmission {
  source: string;
  /** Every `const` this emission wrote, for the bytecode budget report (task item 3). */
  arrays: ArrayEntry[];
}

class Emitter {
  private readonly out: string[] = [];
  readonly arrays: ArrayEntry[] = [];

  push(s: string): void {
    this.out.push(s);
  }

  scalar(name: string, cairoType: string, value: bigint): void {
    this.out.push(`pub const ${name}: ${cairoType} = ${hex(value)};\n`);
    this.arrays.push({ name, group: "scalar", layout: "scalar", count: 1 });
  }

  array(name: string, cairoType: string, values: bigint[], group: string, layout: string): void {
    const items = values.map(hex).join(", ");
    this.out.push(`pub const ${name}: [${cairoType}; ${values.length}] = [${items}];\n`);
    this.arrays.push({ name, group, layout, count: values.length });
  }

  source(): string {
    return this.out.join("");
  }
}

const HEADER_TEMPLATE = (map: MapData, config: EmitConfig) => `\
// GENERATED FILE - DO NOT EDIT BY HAND.
// Produced by tools/wad v2 (WAD tool v2 task; RISKS.md R2-A9/R2-A12) from
// ${map.name} of freedoom1.wad.
// Regenerate with: npm run extract -- --wad <freedoom1.wad> --map ${map.name} --out out/
//
// ============================================================================
// Map statistics
// ============================================================================
// vertexes:   ${map.vertexes.length}
// things:     ${map.things.length}
// linedefs:   ${map.linedefs.length}
// sidedefs:   ${map.sidedefs.length}
// sectors:    ${map.sectors.length}
// subsectors: ${map.subsectors.length}
// nodes:      ${map.nodes.length}
// segs:       ${map.segs.length} (parsed but NOT emitted below - see "What's not here")
//
// ============================================================================
// What's not here, and why (task "WAD tool v2")
// ============================================================================
// - SEGS: not needed at runtime. Subsector -> sector is resolved once at
//   extraction time (derive.ts#computeSubsectorSectors) into SS_SECTOR /
//   SS_SECTOR_PACKED below; the R2-A9 accelerator (ACCEL_*) resolves
//   "which subsector is this point in" without a SEGS-based BSP walk in
//   the common case. Kept in the JSON output (Output A) for the client.
// - Texture/flat names (SIDEDEFS upper/lower/middle, SECTORS floor/ceiling):
//   rendering-only, not read by the simulation. Kept in the JSON output.
// - Linedef/vertex raw start/end indices, NODES bounding boxes: superseded
//   by the precomputed half-plane predicates + bbox below (S1 §5.9's "lean
//   program" estimate drops node bboxes for the same reason).
//
// ============================================================================
// Layout (this emission; see tools/wad/emit-config.json)
// ============================================================================
${Object.entries(config)
  .map(([group, layout]) => `// ${group.padEnd(18)} ${layout}`)
  .join("\n")}
//
// ============================================================================
// Half-plane predicates (R2-A4, docs/spikes/S1.md §5, §7 "geom2d")
// ============================================================================
// cross(x_f, y_f) = A*y_f + B*x_f + C, x_f/y_f = query point in 16.16 fixed
// point. side = 1 iff cross >= 0 (vanilla P_PointOnLineSide convention).
// Coefficients are biased non-negative (see predicates.ts for the exact
// derivation): Ab = A + PRED_HK, Bb = B + PRED_HK, Cb = C2 + PRED_BIGC,
// where C2 = C - (A+B)*PRED_OFF folds the query point's own bias
// (X = x_f + PRED_OFF, Y = y_f + PRED_OFF) into the line's constant term.
// The Cairo core hoists the point-only term out of its per-line loop:
//   hoist(X, Y) = PRED_HK * (X + Y) + PRED_BIGC
//   side = 1  <=>  Ab*Y + Bb*X + Cb  >=  hoist(X, Y)
// (planar layout: {GROUP}_AB/BB/CB three arrays; packed layout: one
// {GROUP}_PREDICATE felt252 per record, see v2Packing.ts#packPredicate).
//
// ============================================================================
// Cell -> subsector accelerator (R2-A9, docs/spikes/S1.md §7 "bsp")
// ============================================================================
// ACCEL_START[cell] / ACCEL_COUNT[cell]: span into ACCEL_SUBSECTORS of the
// subsector indices whose bounding box can overlap blockmap cell "cell"
// (row*BLOCKMAP_COLUMNS + col). Conservative by construction: a
// subsector's bbox always contains the whole subsector polygon (any
// interior point's coordinates lie between the min/max of the polygon's
// own vertices), so if a point lies in both a subsector and a cell, that
// subsector's bbox intersects the cell and is listed for it. See
// accelerator.ts for the full argument and test/accelerator.test.ts for
// the property test. Method: subsector bboxes are the union of their
// SEGS' vertex coordinates (computed here, at extraction time - SEGS
// themselves are not emitted, see above).
//
// ============================================================================
// Packed layouts (fields packed into one felt/u32 per record or per
// INDICES_PER_FELT indices; see v2Packing.ts for exact bit widths)
// ============================================================================

`;

function linedefFlagsOf(l: MapData["linedefs"][number]): { blocking: 0 | 1; blockMonsters: 0 | 1; twoSided: 0 | 1 } {
  return {
    blocking: (l.flags & 0x0001) !== 0 ? 1 : 0,
    blockMonsters: (l.flags & 0x0002) !== 0 ? 1 : 0,
    twoSided: (l.flags & 0x0004) !== 0 ? 1 : 0,
  };
}

export function buildMapCairo(map: MapData, config: EmitConfig = DEFAULT_EMIT_CONFIG): CairoEmission {
  const e = new Emitter();
  e.push(HEADER_TEMPLATE(map, config));

  // --- scalars ---------------------------------------------------------
  e.scalar("NUM_VERTEXES", "u32", BigInt(map.vertexes.length));
  e.scalar("NUM_THINGS", "u32", BigInt(map.things.length));
  e.scalar("NUM_LINEDEFS", "u32", BigInt(map.linedefs.length));
  e.scalar("NUM_SIDEDEFS", "u32", BigInt(map.sidedefs.length));
  e.scalar("NUM_SUBSECTORS", "u32", BigInt(map.subsectors.length));
  e.scalar("NUM_NODES", "u32", BigInt(map.nodes.length));
  e.scalar("NUM_SECTORS", "u32", BigInt(map.sectors.length));
  e.scalar("ROOT_NODE", "u32", BigInt(Math.max(0, map.nodes.length - 1)));
  e.push("\n");
  e.scalar("MAP_MIN_X", "u32", bias16(map.boundingBox.minX));
  e.scalar("MAP_MIN_Y", "u32", bias16(map.boundingBox.minY));
  e.scalar("MAP_MAX_X", "u32", bias16(map.boundingBox.maxX));
  e.scalar("MAP_MAX_Y", "u32", bias16(map.boundingBox.maxY));
  e.push("\n");
  // Bias constants the Cairo core's `hoist`/half-plane functions need -
  // see predicates.ts and the header comment above.
  e.scalar("PRED_FRACUNIT", "felt252", PRED_FRACUNIT);
  e.scalar("PRED_OFF", "felt252", PRED_OFF);
  e.scalar("PRED_HK", "felt252", PRED_HK);
  e.scalar("PRED_BIGC", "felt252", PRED_BIGC);
  e.push("\n");

  // --- vertices ----------------------------------------------------------------------------
  if (config.vertices === "planar") {
    e.array("VERTEX_X", "u32", map.vertexes.map((v) => bias16(v.x)), "vertices", "planar");
    e.array("VERTEX_Y", "u32", map.vertexes.map((v) => bias16(v.y)), "vertices", "planar");
  } else {
    e.array("VERTEXES", "u32", map.vertexes.map(packVertex), "vertices", "packed");
  }

  // --- BSP node half-plane predicates + children --------------------------------------------
  const nodePreds: HalfPlane[] = map.nodes.map((n) => nodePredicate(n));
  if (config.nodePredicates === "planar") {
    e.array("NODE_AB", "felt252", nodePreds.map((p) => p.ab), "nodePredicates", "planar");
    e.array("NODE_BB", "felt252", nodePreds.map((p) => p.bb), "nodePredicates", "planar");
    e.array("NODE_CB", "felt252", nodePreds.map((p) => p.cb), "nodePredicates", "planar");
  } else {
    e.array("NODE_PREDICATE", "felt252", nodePreds.map((p) => packPredicate(p)), "nodePredicates", "packed");
  }
  if (config.nodeChildren === "planar") {
    e.array("NODE_CHILD0", "u32", map.nodes.map((n) => raw16(n.rightChild)), "nodeChildren", "planar");
    e.array("NODE_CHILD1", "u32", map.nodes.map((n) => raw16(n.leftChild)), "nodeChildren", "planar");
  } else {
    e.array(
      "NODE_CHILDREN",
      "u32",
      map.nodes.map((n) => packNodeChildren(n)),
      "nodeChildren",
      "packed",
    );
  }

  // --- linedef half-plane predicates + bbox + flags + sides + special/tag -------------------
  const linePreds = map.linedefs.map((l) => linedefPredicate(map.vertexes[l.startVertex]!, map.vertexes[l.endVertex]!));
  if (config.linedefPredicates === "planar") {
    e.array("LINEDEF_AB", "felt252", linePreds.map((p) => p.ab), "linedefPredicates", "planar");
    e.array("LINEDEF_BB", "felt252", linePreds.map((p) => p.bb), "linedefPredicates", "planar");
    e.array("LINEDEF_CB", "felt252", linePreds.map((p) => p.cb), "linedefPredicates", "planar");
    e.array("LINEDEF_DIAG", "u32", linePreds.map((p) => BigInt(p.diag)), "linedefPredicates", "planar");
  } else {
    e.array("LINEDEF_PREDICATE", "felt252", linePreds.map((p) => packPredicate(p)), "linedefPredicates", "packed");
  }

  const lineBBoxes: FixedBBox[] = map.linedefs.map((l) => linedefFixedBBox(map.vertexes[l.startVertex]!, map.vertexes[l.endVertex]!));
  if (config.linedefBBox === "planar") {
    e.array("LINEDEF_BBOX_L", "felt252", lineBBoxes.map((b) => b.left), "linedefBBox", "planar");
    e.array("LINEDEF_BBOX_R", "felt252", lineBBoxes.map((b) => b.right), "linedefBBox", "planar");
    e.array("LINEDEF_BBOX_B", "felt252", lineBBoxes.map((b) => b.bottom), "linedefBBox", "planar");
    e.array("LINEDEF_BBOX_T", "felt252", lineBBoxes.map((b) => b.top), "linedefBBox", "planar");
  } else {
    e.array("LINEDEF_BBOX_LR", "felt252", lineBBoxes.map(packBBoxLR), "linedefBBox", "packed");
    e.array("LINEDEF_BBOX_BT", "felt252", lineBBoxes.map(packBBoxBT), "linedefBBox", "packed");
  }

  const lineFlags = map.linedefs.map(linedefFlagsOf);
  if (config.linedefFlags === "planar") {
    e.array("LINEDEF_BLOCKING", "u32", lineFlags.map((f) => BigInt(f.blocking)), "linedefFlags", "planar");
    e.array("LINEDEF_BLOCK_MONSTERS", "u32", lineFlags.map((f) => BigInt(f.blockMonsters)), "linedefFlags", "planar");
    e.array("LINEDEF_TWO_SIDED", "u32", lineFlags.map((f) => BigInt(f.twoSided)), "linedefFlags", "planar");
  } else {
    e.array(
      "LINEDEF_FLAGS",
      "u32",
      lineFlags.map((f) => packLinedefFlags(f.blocking, f.blockMonsters, f.twoSided)),
      "linedefFlags",
      "packed",
    );
  }

  if (config.linedefSides === "planar") {
    e.array("LINEDEF_FRONT_SIDEDEF", "u32", map.linedefs.map((l) => raw16(l.frontSidedef)), "linedefSides", "planar");
    e.array("LINEDEF_BACK_SIDEDEF", "u32", map.linedefs.map((l) => raw16(l.backSidedef)), "linedefSides", "planar");
  } else {
    e.array(
      "LINEDEF_SIDES",
      "u32",
      map.linedefs.map((l) => packLinedefSides(l.frontSidedef, l.backSidedef)),
      "linedefSides",
      "packed",
    );
  }

  if (config.linedefSpecial === "planar") {
    e.array("LINEDEF_SPECIAL_TYPE", "u32", map.linedefs.map((l) => raw16(l.specialType)), "linedefSpecial", "planar");
    e.array("LINEDEF_TAG", "u32", map.linedefs.map((l) => raw16(l.sectorTag)), "linedefSpecial", "planar");
  } else {
    e.array(
      "LINEDEF_SPECIAL",
      "u32",
      map.linedefs.map((l) => packLinedefSpecial(l.specialType, l.sectorTag)),
      "linedefSpecial",
      "packed",
    );
  }

  // --- sidedef -> sector ---------------------------------------------------------------------
  const sidedefSectors = map.sidedefs.map((s) => s.sector);
  if (config.sidedefSector === "planar") {
    e.array("SIDEDEF_SECTOR", "u32", sidedefSectors.map((s) => raw16(s)), "sidedefSector", "planar");
  } else {
    e.array("SIDEDEF_SECTOR_PACKED", "felt252", packIndices(sidedefSectors, INDICES_PER_FELT), "sidedefSector", "packed");
    e.scalar("SIDEDEF_SECTOR_PACK_STRIDE", "u32", BigInt(INDICES_PER_FELT));
  }

  // --- subsector -> sector (task item 1) -------------------------------------------------------
  if (config.subsectorSector === "planar") {
    e.array("SS_SECTOR", "u32", map.subsectorSectors.map((s) => raw16(s)), "subsectorSector", "planar");
  } else {
    e.array("SS_SECTOR_PACKED", "felt252", packIndices(map.subsectorSectors, INDICES_PER_FELT), "subsectorSector", "packed");
    e.scalar("SS_SECTOR_PACK_STRIDE", "u32", BigInt(INDICES_PER_FELT));
  }

  // --- sector heights + metadata ---------------------------------------------------------------
  if (config.sectorHeights === "planar") {
    e.array("SECTOR_FLOOR", "u32", map.sectors.map((s) => bias16(s.floorHeight)), "sectorHeights", "planar");
    e.array("SECTOR_CEILING", "u32", map.sectors.map((s) => bias16(s.ceilingHeight)), "sectorHeights", "planar");
  } else {
    e.array(
      "SECTOR_HEIGHTS",
      "u32",
      map.sectors.map((s) => packSectorHeights(s.floorHeight, s.ceilingHeight)),
      "sectorHeights",
      "packed",
    );
  }
  if (config.sectorMeta === "planar") {
    e.array("SECTOR_LIGHT", "u32", map.sectors.map((s) => bias16(s.lightLevel)), "sectorMeta", "planar");
    e.array("SECTOR_SPECIAL_TYPE", "u32", map.sectors.map((s) => raw16(s.specialType)), "sectorMeta", "planar");
    e.array("SECTOR_TAG", "u32", map.sectors.map((s) => raw16(s.tag)), "sectorMeta", "planar");
  } else {
    e.array(
      "SECTOR_META",
      "felt252",
      map.sectors.map((s) => packSectorMeta(s.lightLevel, s.specialType, s.tag)),
      "sectorMeta",
      "packed",
    );
  }

  // --- REJECT ------------------------------------------------------------------------------
  if (config.reject === "planar") {
    const flat: bigint[] = [];
    for (let i = 0; i < map.reject.numSectors; i++) {
      for (let j = 0; j < map.reject.numSectors; j++) {
        const bit = i * map.reject.numSectors + j;
        const byte = map.reject.data[bit >> 3] ?? 0;
        flat.push(BigInt((byte >> (bit & 7)) & 1));
      }
    }
    e.array("REJECT_FLAT", "u32", flat, "reject", "planar");
  } else {
    const chunksPerRow = rejectChunksPerRow(map.reject.numSectors);
    e.scalar("REJECT_CHUNKS_PER_ROW", "u32", BigInt(chunksPerRow));
    e.array("REJECT_ROWS", "felt252", packRejectRows(map.reject.data, map.reject.numSectors), "reject", "packed");
  }

  // --- things --------------------------------------------------------------------------------
  if (config.things === "planar") {
    e.array("THING_X", "u32", map.things.map((t) => bias16(t.x)), "things", "planar");
    e.array("THING_Y", "u32", map.things.map((t) => bias16(t.y)), "things", "planar");
    e.array("THING_ANGLE", "u32", map.things.map((t) => raw16(t.angle)), "things", "planar");
    e.array("THING_TYPE", "u32", map.things.map((t) => raw16(t.type)), "things", "planar");
    e.array("THING_FLAGS", "u32", map.things.map((t) => raw16(t.flags)), "things", "planar");
  } else {
    e.array("THINGS", "felt252", map.things.map(packThing), "things", "packed");
  }

  // --- blockmap ------------------------------------------------------------------------------
  if (config.blockmap === "planar") {
    e.scalar("BLOCKMAP_ORIGIN_X", "u32", bias16(map.blockmap.originX));
    e.scalar("BLOCKMAP_ORIGIN_Y", "u32", bias16(map.blockmap.originY));
    e.scalar("BLOCKMAP_COLUMNS", "u32", BigInt(map.blockmap.columns));
    e.scalar("BLOCKMAP_ROWS", "u32", BigInt(map.blockmap.rows));
  } else {
    e.scalar(
      "BLOCKMAP_HEADER",
      "felt252",
      packBlockmapHeader({
        originX: map.blockmap.originX,
        originY: map.blockmap.originY,
        columns: map.blockmap.columns,
        rows: map.blockmap.rows,
      }),
    );
  }
  e.array("BLOCKMAP_OFFSETS", "u32", map.blockmap.cellOffsets.map(BigInt), "blockmap", config.blockmap);
  e.array("BLOCKMAP_WORDS", "u32", packBlockmapWords(map.blockmapLumpBuffer), "blockmap", config.blockmap);

  // --- R2-A9 cell -> subsector accelerator ----------------------------------------------------
  const { spans } = computeCellSubsectors(map);
  e.array("ACCEL_START", "u32", spans.start.map(BigInt), "accelerator", config.accelerator);
  e.array("ACCEL_COUNT", "u32", spans.count.map(BigInt), "accelerator", config.accelerator);
  if (config.accelerator === "planar") {
    e.array("ACCEL_SUBSECTORS", "u32", spans.subsectors.map(BigInt), "accelerator", "planar");
  } else {
    e.array("ACCEL_SUBSECTORS_PACKED", "felt252", packIndices(spans.subsectors, INDICES_PER_FELT), "accelerator", "packed");
    e.scalar("ACCEL_SUBSECTORS_PACK_STRIDE", "u32", BigInt(INDICES_PER_FELT));
  }

  return { source: e.source(), arrays: e.arrays };
}

// Re-exported for tests/tools that want the raw name64 helper without importing packing.ts directly.
export { nameToU64 };

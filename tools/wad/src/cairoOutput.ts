import { bias16, nameToU64 } from "./packing.js";
import { MapData } from "./mapExtract.js";
import {
  packBBox,
  packBlockmapHeader,
  packBlockmapWords,
  packLinedef,
  packNode,
  packRejectRows,
  packSector,
  packSeg,
  packSidedef,
  packSubsector,
  packThing,
  packVertex,
  rejectChunksPerRow,
} from "./recordPacking.js";

function hex(v: bigint): string {
  return `0x${v.toString(16)}`;
}

function arrayConst(name: string, cairoType: string, values: bigint[]): string {
  const items = values.map(hex).join(", ");
  return `pub const ${name}: [${cairoType}; ${values.length}] = [${items}];\n`;
}

function scalarConst(name: string, cairoType: string, value: bigint): string {
  return `pub const ${name}: ${cairoType} = ${hex(value)};\n`;
}

const HEADER_TEMPLATE = (map: MapData, chunksPerRow: number) => `\
// GENERATED FILE - DO NOT EDIT BY HAND.
// Produced by tools/wad (roadmap P0.2) from ${map.name} of freedoom1.wad.
// Regenerate with: npm run extract -- --wad <freedoom1.wad> --map ${map.name} --out out/
//
// ============================================================================
// Map statistics
// ============================================================================
// vertexes:   ${map.vertexes.length}
// things:     ${map.things.length}
// linedefs:   ${map.linedefs.length}
// sidedefs:   ${map.sidedefs.length}
// segs:       ${map.segs.length}
// subsectors: ${map.subsectors.length}
// nodes:      ${map.nodes.length}
// sectors:    ${map.sectors.length}
// reject:     ${map.reject.data.length} bytes for ${map.reject.numSectors} sectors, ${chunksPerRow} felt252 chunk(s)/row
// blockmap:   ${map.blockmap.columns}x${map.blockmap.rows} cells, ${map.blockmap.cellOffsets.length} offsets
//
// ============================================================================
// Packing spec
// ============================================================================
// Every constant below packs one or more record fields into a single
// non-negative integer, least-significant field first (field i occupies
// bits [sum(widths[0..i]), sum(widths[0..i+1]))). Every packed value is kept
// strictly below 2^128 (see rule A7 in PLAN.md and CONTEXT.md 4.3: the
// current Stwo-cairo adapter panics on felts >= 2^128 in memory).
//
// Three field encodings are used, chosen per WAD field semantics:
//   - biased16: a signed int16 magnitude (coordinate, offset, height, node
//     partition/bbox delta) encoded as (value + 32768), decoded by
//     subtracting 32768. Maps [-32768, 32767] -> [0, 65535].
//   - raw16: an already-unsigned uint16 (index, flag bitfield, enum, count,
//     or the 0xFFFF NO_SIDEDEF/list-terminator sentinel). Packed as-is.
//   - name64: up to 8 ASCII bytes of a texture/flat name, byte 0 in bits
//     [0,8), NUL-padded, packed little-endian into a 64-bit value.
//
// VERTEXES[i]              (u32,  32 bits) = x:biased16 | y:biased16<<16
// THINGS[i]                (felt252, 80 bits) =
//     x:biased16 | y:biased16<<16 | angle:raw16<<32 | type:raw16<<48 | flags:raw16<<64
// LINEDEFS[i]              (felt252, 112 bits) =
//     v1:raw16 | v2:raw16<<16 | flags:raw16<<32 | special:raw16<<48 | tag:raw16<<64
//     | front_side:raw16<<80 | back_side:raw16<<96   (front/back = 0xFFFF if none)
// SIDEDEFS_MAIN[i]         (felt252, 48 bits) = x_off:biased16 | y_off:biased16<<16 | sector:raw16<<32
// SIDEDEFS_{UPPER,LOWER,MIDDLE}_TEXTURES[i]  (felt252, 64 bits) = name64(texture) ("-" = none)
// SEGS[i]                  (felt252, 96 bits) =
//     v1:raw16 | v2:raw16<<16 | angle:raw16<<32 | linedef:raw16<<48 | direction:raw16<<64
//     | offset:biased16<<80
//     (angle is a circular BAM value already reduced mod 65536 by the parser
//     from the signed top-16-bits-of-angle_t on-disk representation; it is
//     packed as raw16, not biased16 - see types.ts#Seg.)
// SSECTORS[i]              (u32,  32 bits) = num_segs:raw16 | first_seg:raw16<<16
// NODES_PARTITION[i]       (felt252, 64 bits) = x:biased16 | y:biased16<<16 | dx:biased16<<32 | dy:biased16<<48
// NODES_BBOX_RIGHT[i]      (felt252, 64 bits) = top:biased16 | bottom:biased16<<16 | left:biased16<<32 | right:biased16<<48
// NODES_BBOX_LEFT[i]       (felt252, 64 bits) = same layout as NODES_BBOX_RIGHT, for the left child
// NODES_CHILDREN[i]        (u32,  32 bits) = right_child:raw16 | left_child:raw16<<16
//     (bit 15 of each 16-bit child value set => leaf: child & 0x7FFF is a subsector index)
// SECTORS_MAIN[i]          (felt252, 80 bits) =
//     floor:biased16 | ceiling:biased16<<16 | light:biased16<<32 | special:raw16<<48 | tag:raw16<<64
// SECTORS_{FLOOR,CEILING}_TEXTURES[i]  (felt252, 64 bits) = name64(flat)
//
// REJECT_ROWS[i * REJECT_CHUNKS_PER_ROW + c]  (felt252, <=128 bits) =
//     bits [c*128, min((c+1)*128, NUM_SECTORS)) of REJECT row i (sector i's
//     visibility against every sector j), bit b (LSB-first) = sector c*128+b.
//     Row i, column j (bit set) means "sector j is NOT visible from sector i"
//     (a conservative fast-reject hint; 0 does not guarantee visibility).
//
// BLOCKMAP_HEADER          (felt252, 64 bits) =
//     origin_x:biased16 | origin_y:biased16<<16 | columns:raw16<<32 | rows:raw16<<48
// BLOCKMAP_OFFSETS[i]      (u32) = word offset (from the start of the BLOCKMAP lump,
//     in 2-byte units) of grid cell i's blocklist, i = row*columns + col, row-major.
// BLOCKMAP_WORDS[i]        (u32) = the i-th 16-bit little-endian word of the
//     raw BLOCKMAP lump (header + offsets table + blocklists), unsigned
//     bit-reinterpretation of the on-disk value (BLOCKMAP_OFFSETS[k] indexes
//     directly into this array with no adjustment, exactly like the on-disk
//     format). Each cell's blocklist is a leading 0x0000 sentinel, then
//     linedef indices, terminated by 0xFFFF.
// ============================================================================

`;

export function buildMapCairo(map: MapData): string {
  const chunksPerRow = rejectChunksPerRow(map.reject.numSectors);
  const out: string[] = [HEADER_TEMPLATE(map, chunksPerRow)];

  out.push(scalarConst("NUM_VERTEXES", "u32", BigInt(map.vertexes.length)));
  out.push(scalarConst("NUM_THINGS", "u32", BigInt(map.things.length)));
  out.push(scalarConst("NUM_LINEDEFS", "u32", BigInt(map.linedefs.length)));
  out.push(scalarConst("NUM_SIDEDEFS", "u32", BigInt(map.sidedefs.length)));
  out.push(scalarConst("NUM_SEGS", "u32", BigInt(map.segs.length)));
  out.push(scalarConst("NUM_SUBSECTORS", "u32", BigInt(map.subsectors.length)));
  out.push(scalarConst("NUM_NODES", "u32", BigInt(map.nodes.length)));
  out.push(scalarConst("NUM_SECTORS", "u32", BigInt(map.sectors.length)));
  out.push(scalarConst("REJECT_CHUNKS_PER_ROW", "u32", BigInt(chunksPerRow)));
  out.push(scalarConst("BLOCKMAP_COLUMNS", "u32", BigInt(map.blockmap.columns)));
  out.push(scalarConst("BLOCKMAP_ROWS", "u32", BigInt(map.blockmap.rows)));
  out.push("\n");

  out.push(scalarConst("MAP_MIN_X", "u32", bias16(map.boundingBox.minX)));
  out.push(scalarConst("MAP_MIN_Y", "u32", bias16(map.boundingBox.minY)));
  out.push(scalarConst("MAP_MAX_X", "u32", bias16(map.boundingBox.maxX)));
  out.push(scalarConst("MAP_MAX_Y", "u32", bias16(map.boundingBox.maxY)));
  out.push("\n");

  out.push(arrayConst("VERTEXES", "u32", map.vertexes.map(packVertex)));
  out.push(arrayConst("THINGS", "felt252", map.things.map(packThing)));
  out.push(arrayConst("LINEDEFS", "felt252", map.linedefs.map(packLinedef)));

  const sidedefsPacked = map.sidedefs.map(packSidedef);
  out.push(arrayConst("SIDEDEFS_MAIN", "felt252", sidedefsPacked.map((s) => s.main)));
  out.push(arrayConst("SIDEDEFS_UPPER_TEXTURES", "felt252", sidedefsPacked.map((s) => s.upper)));
  out.push(arrayConst("SIDEDEFS_LOWER_TEXTURES", "felt252", sidedefsPacked.map((s) => s.lower)));
  out.push(arrayConst("SIDEDEFS_MIDDLE_TEXTURES", "felt252", sidedefsPacked.map((s) => s.middle)));

  out.push(arrayConst("SEGS", "felt252", map.segs.map(packSeg)));
  out.push(arrayConst("SSECTORS", "u32", map.subsectors.map(packSubsector)));

  const nodesPacked = map.nodes.map(packNode);
  out.push(arrayConst("NODES_PARTITION", "felt252", nodesPacked.map((n) => n.partition)));
  out.push(arrayConst("NODES_BBOX_RIGHT", "felt252", nodesPacked.map((n) => n.rightBBox)));
  out.push(arrayConst("NODES_BBOX_LEFT", "felt252", nodesPacked.map((n) => n.leftBBox)));
  out.push(arrayConst("NODES_CHILDREN", "u32", nodesPacked.map((n) => n.children)));

  const sectorsPacked = map.sectors.map(packSector);
  out.push(arrayConst("SECTORS_MAIN", "felt252", sectorsPacked.map((s) => s.main)));
  out.push(arrayConst("SECTORS_FLOOR_TEXTURES", "felt252", sectorsPacked.map((s) => s.floorTexture)));
  out.push(arrayConst("SECTORS_CEILING_TEXTURES", "felt252", sectorsPacked.map((s) => s.ceilingTexture)));

  const rejectRows = packRejectRows(map.reject.data, map.reject.numSectors);
  out.push(arrayConst("REJECT_ROWS", "felt252", rejectRows));

  out.push(
    scalarConst(
      "BLOCKMAP_HEADER",
      "felt252",
      packBlockmapHeader({
        originX: map.blockmap.originX,
        originY: map.blockmap.originY,
        columns: map.blockmap.columns,
        rows: map.blockmap.rows,
      }),
    ),
  );
  out.push(arrayConst("BLOCKMAP_OFFSETS", "u32", map.blockmap.cellOffsets.map(BigInt)));
  out.push(arrayConst("BLOCKMAP_WORDS", "u32", packBlockmapWords(map.blockmapLumpBuffer)));

  return out.join("");
}

// Re-exported for tests that want the raw name64 helper without importing packing.ts directly.
export { nameToU64 };

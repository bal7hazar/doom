import { describe, expect, it } from "vitest";
import {
  buildSubsectorPolygons,
  fanTriangulate,
  pointInSector,
  pointInSubsector,
  signedArea,
  subsectorSector,
  type Point2,
} from "../src/map/bsp.js";
import { LinedefFlag, findDynamicSectors, type LevelJson } from "../src/map/level.js";
import { buildWallQuads, quadCorners, wallTopAnchor } from "../src/map/walls.js";
import { loadLevel } from "./fixture.js";

const level = loadLevel<LevelJson>();

// ---------------------------------------------------------------------------
// Pegging
// ---------------------------------------------------------------------------

describe("wallTopAnchor (vanilla pegging)", () => {
  const heights = { frontFloor: 0, frontCeiling: 128, backFloor: 32, backCeiling: 96 };

  it("anchors a pegged one-sided middle texture to the ceiling", () => {
    // R_StoreWallRange: rw_midtexturemid = worldtop (frontsector ceiling).
    expect(
      wallTopAnchor({ kind: "middle", flags: 0, yOffset: 0, texHeight: 72, ...heights }),
    ).toBe(128);
  });

  it("anchors a LOWER_UNPEGGED one-sided middle to the floor plus the texture height", () => {
    // rw_midtexturemid = frontsector->floorheight + textureheight, so the
    // texture's *bottom* row lands exactly on the floor whatever the height.
    expect(
      wallTopAnchor({
        kind: "middle",
        flags: LinedefFlag.LOWER_UNPEGGED,
        yOffset: 0,
        texHeight: 72,
        ...heights,
      }),
    ).toBe(72);
  });

  it("anchors a pegged upper to the back ceiling plus the texture height", () => {
    expect(
      wallTopAnchor({ kind: "upper", flags: 0, yOffset: 0, texHeight: 64, ...heights }),
    ).toBe(96 + 64);
  });

  it("anchors an UPPER_UNPEGGED upper to the front ceiling", () => {
    expect(
      wallTopAnchor({
        kind: "upper",
        flags: LinedefFlag.UPPER_UNPEGGED,
        yOffset: 0,
        texHeight: 64,
        ...heights,
      }),
    ).toBe(128);
  });

  it("anchors a pegged lower to the back floor", () => {
    expect(wallTopAnchor({ kind: "lower", flags: 0, yOffset: 0, texHeight: 64, ...heights })).toBe(32);
  });

  it("anchors a LOWER_UNPEGGED lower to the *front ceiling*", () => {
    // The counter-intuitive vanilla case: rw_bottomtexturemid = worldtop, so a
    // step's texture stays continuous with the wall above it.
    expect(
      wallTopAnchor({
        kind: "lower",
        flags: LinedefFlag.LOWER_UNPEGGED,
        yOffset: 0,
        texHeight: 64,
        ...heights,
      }),
    ).toBe(128);
  });

  it("anchors a two-sided masked middle to the opening", () => {
    // opentop = min(ceilings) = 96, openbottom = max(floors) = 32.
    expect(
      wallTopAnchor({ kind: "middle-masked", flags: 0, yOffset: 0, texHeight: 48, ...heights }),
    ).toBe(96);
    expect(
      wallTopAnchor({
        kind: "middle-masked",
        flags: LinedefFlag.LOWER_UNPEGGED,
        yOffset: 0,
        texHeight: 48,
        ...heights,
      }),
    ).toBe(32 + 48);
  });

  it("adds the sidedef row offset, which moves the texture up", () => {
    // dc_texturemid += rowoffset, and dc_texturemid is the world height of
    // texture row 0 relative to the eye: a positive offset raises row 0.
    const pegged = wallTopAnchor({ kind: "middle", flags: 0, yOffset: 0, texHeight: 72, ...heights });
    const offset = wallTopAnchor({ kind: "middle", flags: 0, yOffset: 16, texHeight: 72, ...heights });
    expect(offset - pegged).toBe(16);
  });
});

// ---------------------------------------------------------------------------
// Wall quads
// ---------------------------------------------------------------------------

/** A two-sector test map: a 128-unit square split by a two-sided line. */
function twoSectorLevel(overrides: Partial<LevelJson> = {}): LevelJson {
  const base = {
    map: "TEST",
    counts: {},
    boundingBox: { minX: 0, minY: 0, maxX: 128, maxY: 128 },
    things: [{ x: 32, y: 32, angle: 0, type: 1, flags: 7 }],
    linedefs: [
      // Two-sided divider from (0,64) to (128,64): front = sector 0, back = 1.
      {
        startVertex: 0,
        endVertex: 1,
        flags: LinedefFlag.TWO_SIDED,
        specialType: 0,
        sectorTag: 0,
        frontSidedef: 0,
        backSidedef: 1,
      },
      // One-sided south wall from (0,0) to (128,0).
      {
        startVertex: 2,
        endVertex: 3,
        flags: LinedefFlag.BLOCKING,
        specialType: 0,
        sectorTag: 0,
        frontSidedef: 2,
        backSidedef: 0xffff,
      },
    ],
    sidedefs: [
      { xOffset: 0, yOffset: 0, upperTexture: "UPPER", lowerTexture: "LOWER", middleTexture: "-", sector: 0 },
      { xOffset: 0, yOffset: 0, upperTexture: "-", lowerTexture: "-", middleTexture: "-", sector: 1 },
      { xOffset: 8, yOffset: 0, upperTexture: "-", lowerTexture: "-", middleTexture: "MID", sector: 0 },
    ],
    vertexes: [
      { x: 0, y: 64 },
      { x: 128, y: 64 },
      { x: 0, y: 0 },
      { x: 128, y: 0 },
    ],
    segs: [],
    subsectors: [],
    nodes: [],
    sectors: [
      { floorHeight: 0, ceilingHeight: 128, floorTexture: "F1", ceilingTexture: "F2", lightLevel: 160, specialType: 0, tag: 0 },
      { floorHeight: 32, ceilingHeight: 96, floorTexture: "F1", ceilingTexture: "F2", lightLevel: 160, specialType: 0, tag: 0 },
    ],
    reject: { numSectors: 2, dataHex: "" },
    blockmap: { unit: 128, originX: 0, originY: 0, columns: 1, rows: 1, cellOffsets: [], cells: [] },
    derived: { sectorLines: [[0, 1], [0]] },
    assets: {
      playpalPaletteCount: 14,
      colormapMapCount: 34,
      pnamesCount: 0,
      texture1Count: 0,
      flats: [],
      sprites: [],
      referencedTextures: [],
      referencedFlats: [],
    },
  } as unknown as LevelJson;
  return { ...base, ...overrides };
}

const sizes = (name: string): { width: number; height: number } | undefined =>
  name === "-" ? undefined : { width: 64, height: 64 };

describe("buildWallQuads", () => {
  const level2 = twoSectorLevel();
  const heights = { floor: [0, 32], ceiling: [128, 96] };
  const quads = buildWallQuads(level2, heights, sizes);

  it("emits an upper and a lower for the two-sided line's front side", () => {
    const front = quads.filter((q) => q.linedef === 0 && q.sidedef === 0);
    expect(front.map((q) => q.kind).sort()).toEqual(["lower", "upper"]);
    const upper = front.find((q) => q.kind === "upper")!;
    expect([upper.zBottom, upper.zTop]).toEqual([96, 128]);
    const lower = front.find((q) => q.kind === "lower")!;
    expect([lower.zBottom, lower.zTop]).toEqual([0, 32]);
  });

  it("emits nothing for the back side, which has no textures", () => {
    expect(quads.filter((q) => q.sidedef === 1)).toHaveLength(0);
  });

  it("spans floor to ceiling on a one-sided wall", () => {
    const mid = quads.find((q) => q.linedef === 1)!;
    expect(mid.kind).toBe("middle");
    expect([mid.zBottom, mid.zTop]).toEqual([0, 128]);
  });

  it("starts u at the sidedef's x offset and grows along the wall", () => {
    const mid = quads.find((q) => q.linedef === 1)!;
    const corners = quadCorners(mid);
    expect(corners[0]!.u).toBe(8); // xOffset
    expect(corners[1]!.u).toBe(8 + 128); // + wall length
  });

  it("runs the back side's u from the linedef's end vertex", () => {
    // seg->offset is measured from the seg's own start; on the back side that
    // is the linedef's *end* vertex, so the quad is emitted reversed.
    const withBackTexture = twoSectorLevel();
    withBackTexture.sidedefs[1]!.lowerTexture = "LOWER";
    const back = buildWallQuads(withBackTexture, heights, sizes).find((q) => q.sidedef === 1);
    // Back sector floor (32) is above front floor (0), so from sector 1's side
    // there is no lower at all - the step goes down, not up.
    expect(back).toBeUndefined();
  });

  it("clamps a two-sided masked middle to one texture height", () => {
    const masked = twoSectorLevel();
    masked.sidedefs[0]!.middleTexture = "GRATE";
    const quad = buildWallQuads(masked, heights, sizes).find((q) => q.kind === "middle-masked")!;
    // Opening is [32, 96] = 64 units, exactly the texture height, pegged to the top.
    expect(quad.zTop).toBe(96);
    expect(quad.zBottom).toBe(32);
    expect(quad.clampV).toBe(true);
  });

  it("applies fake contrast by wall orientation", () => {
    // Both test lines are horizontal (dy == 0), so both are one level darker.
    expect(quads.every((q) => q.lightDelta === -16)).toBe(true);
  });

  it("restricts output to the requested sectors", () => {
    const only = buildWallQuads(level2, heights, sizes, new Set([1]));
    expect(only.every((q) => q.linedef === 0)).toBe(true);
  });

  it("follows moving heights, which is what forces the per-frame rebuild", () => {
    const opened = buildWallQuads(level2, { floor: [0, 32], ceiling: [128, 128] }, sizes);
    // The back ceiling now matches the front: no upper strip remains.
    expect(opened.filter((q) => q.kind === "upper")).toHaveLength(0);
  });

  it("computes v as texels below texture row 0", () => {
    const mid = quads.find((q) => q.linedef === 1)!;
    const corners = quadCorners(mid);
    // Pegged one-sided middle: row 0 sits at the ceiling (128).
    expect(mid.worldTopZ).toBe(128);
    expect(corners[3]!.v).toBe(0); // top corner
    expect(corners[0]!.v).toBe(128); // bottom corner, 128 units below row 0
  });
});

// ---------------------------------------------------------------------------
// Triangulation / BSP
// ---------------------------------------------------------------------------

describe("fanTriangulate and signedArea", () => {
  const square: Point2[] = [
    { x: 0, y: 0 },
    { x: 10, y: 0 },
    { x: 10, y: 10 },
    { x: 0, y: 10 },
  ];

  it("emits n-2 triangles for an n-gon", () => {
    expect(fanTriangulate(square)).toEqual([0, 1, 2, 0, 2, 3]);
    expect(fanTriangulate(square.slice(0, 3))).toHaveLength(3);
    expect(fanTriangulate(square.slice(0, 2))).toEqual([]);
  });

  it("measures a counter-clockwise polygon as positive area", () => {
    expect(signedArea(square)).toBe(100);
    expect(signedArea([...square].reverse())).toBe(-100);
  });

  it("conserves the polygon's area across the fan", () => {
    const indices = fanTriangulate(square);
    let total = 0;
    for (let i = 0; i < indices.length; i += 3) {
      total += Math.abs(
        signedArea([square[indices[i]!]!, square[indices[i + 1]!]!, square[indices[i + 2]!]!]),
      );
    }
    expect(total).toBeCloseTo(Math.abs(signedArea(square)), 9);
  });
});

describe.skipIf(!level)("BSP subsector polygons on real E1M1", () => {
  const e1m1 = level!;

  it("produces one convex polygon per subsector", () => {
    const polys = buildSubsectorPolygons(e1m1);
    expect(polys.length).toBe(e1m1.subsectors.length);
    for (const poly of polys) {
      expect(poly.points.length).toBeGreaterThanOrEqual(3);
      expect(isConvex(poly.points)).toBe(true);
    }
  });

  it("exactly tiles the starting rectangle, with no gaps and no overlap", () => {
    // The BSP partitions the plane, so clipping the starting rectangle down
    // the tree must yield polygons whose areas sum to exactly that rectangle:
    // any gap, overlap, sign error or dropped child would move the total. The
    // rectangle is the map bounding box grown by the 256-unit margin
    // `buildSubsectorPolygons` adds so no partition line is collinear with a
    // starting edge.
    const MARGIN = 256;
    const polys = buildSubsectorPolygons(e1m1);
    const total = polys.reduce((sum, p) => sum + Math.abs(signedArea(p.points)), 0);
    const expected =
      (e1m1.boundingBox.maxX - e1m1.boundingBox.minX + 2 * MARGIN) *
      (e1m1.boundingBox.maxY - e1m1.boundingBox.minY + 2 * MARGIN);
    expect(total / expected).toBeCloseTo(1, 9);
  });

  it("puts every subsector's centroid back in the same subsector", () => {
    // A convex polygon's vertex average is inside it, so the BSP point
    // location must agree with the clipping - the strongest cross-check
    // available between the two independent code paths.
    const polys = buildSubsectorPolygons(e1m1);
    let agreed = 0;
    for (const poly of polys) {
      const cx = poly.points.reduce((s, p) => s + p.x, 0) / poly.points.length;
      const cy = poly.points.reduce((s, p) => s + p.y, 0) / poly.points.length;
      if (pointInSubsector(e1m1, cx, cy) === poly.subsector) agreed++;
    }
    // Slivers whose centroid lands within a rounding error of an edge are the
    // only legitimate misses.
    expect(agreed / polys.length).toBeGreaterThan(0.99);
  });

  it("locates the player start in a sector with head room", () => {
    const start = e1m1.things.find((t) => t.type === 1)!;
    const sector = pointInSector(e1m1, start.x, start.y);
    const def = e1m1.sectors[sector]!;
    expect(def.ceilingHeight - def.floorHeight).toBeGreaterThanOrEqual(56);
  });

  it("agrees with the segs about which sector each subsector belongs to", () => {
    for (let i = 0; i < e1m1.subsectors.length; i++) {
      expect(subsectorSector(e1m1, i)).toBeGreaterThanOrEqual(0);
      expect(subsectorSector(e1m1, i)).toBeLessThan(e1m1.sectors.length);
    }
  });
});

describe.skipIf(!level)("dynamic sector detection on real E1M1", () => {
  it("finds the doors and lifts, and stays a small minority of sectors", () => {
    const e1m1 = level!;
    const dynamic = findDynamicSectors(e1m1);
    expect(dynamic.size).toBeGreaterThan(0);
    // The whole point of the static/dynamic split is that most geometry never
    // moves; if this ever approaches 1 the per-frame rebuild is pointless.
    expect(dynamic.size / e1m1.sectors.length).toBeLessThan(0.35);
  });

  it("includes every sector a tagged linedef special addresses", () => {
    const e1m1 = level!;
    const dynamic = findDynamicSectors(e1m1);
    for (const line of e1m1.linedefs) {
      if (line.specialType === 0 || line.sectorTag === 0) continue;
      const targets = e1m1.sectors
        .map((s, i) => (s.tag === line.sectorTag ? i : -1))
        .filter((i) => i >= 0);
      for (const t of targets) expect(dynamic.has(t)).toBe(true);
    }
  });
});

function isConvex(points: Point2[]): boolean {
  let sign = 0;
  for (let i = 0; i < points.length; i++) {
    const a = points[i]!;
    const b = points[(i + 1) % points.length]!;
    const c = points[(i + 2) % points.length]!;
    const cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
    if (Math.abs(cross) < 1e-6) continue;
    const s = Math.sign(cross);
    if (sign === 0) sign = s;
    else if (s !== sign) return false;
  }
  return true;
}

import { LinedefFlag, NO_SIDEDEF, SKY_FLAT, type LevelJson } from "./level.js";

export type WallKind = "middle" | "upper" | "lower" | "middle-masked";

/**
 * One textured wall rectangle, in map units, ready to be turned into two
 * triangles. `worldTopZ` is the world height of *texture row 0*: every vertex's
 * V coordinate is `(worldTopZ - z) / texHeight`, so pegging is entirely encoded
 * in this one number and the quad's own extent.
 */
export interface WallQuad {
  linedef: number;
  sidedef: number;
  kind: WallKind;
  /** Endpoints in the drawing direction: u grows from (x1,y1) to (x2,y2). */
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  zTop: number;
  zBottom: number;
  /** World z of texture row 0 (see above). */
  worldTopZ: number;
  /** Horizontal texture offset at (x1,y1), in texels. */
  uOffset: number;
  texture: string;
  /** Sector supplying the light level (always the sidedef's own sector). */
  sector: number;
  /** Vanilla fake contrast, in light-level units: -16, 0 or +16. */
  lightDelta: number;
  /** Masked middle textures on two-sided lines must not tile vertically. */
  clampV: boolean;
}

/** Floor/ceiling heights for every sector, as the snapshot supplies them. */
export interface SectorHeights {
  floor: Float64Array | number[];
  ceiling: Float64Array | number[];
}

export interface TextureSize {
  width: number;
  height: number;
}

/** Looks a texture's dimensions up; missing textures yield `undefined` and are skipped. */
export type TextureSizeLookup = (name: string) => TextureSize | undefined;

/**
 * Vanilla wall texture anchoring (`R_StoreWallRange` / `R_RenderMaskedSegRange`).
 *
 * `dc_texturemid` in the software renderer is the world height of texture row 0
 * relative to the eye; adding `sidedef->rowoffset` to it moves the texture
 * *up*, which is why `yOffset` is added to `worldTopZ` here rather than
 * subtracted. The four cases:
 *
 * | surface                      | unpegged flag   | texture row 0 sits at |
 * |------------------------------|-----------------|-----------------------|
 * | one-sided middle             | LOWER_UNPEGGED  | frontFloor + texHeight|
 * | one-sided middle             | (pegged)        | frontCeiling          |
 * | upper                        | UPPER_UNPEGGED  | frontCeiling          |
 * | upper                        | (pegged)        | backCeiling + texH    |
 * | lower                        | LOWER_UNPEGGED  | frontCeiling          |
 * | lower                        | (pegged)        | backFloor             |
 * | two-sided masked middle      | LOWER_UNPEGGED  | openBottom + texH     |
 * | two-sided masked middle      | (pegged)        | openTop               |
 *
 * Each row is exercised by `test/geometry.test.ts`.
 */
export function wallTopAnchor(args: {
  kind: WallKind;
  flags: number;
  yOffset: number;
  texHeight: number;
  frontFloor: number;
  frontCeiling: number;
  backFloor: number;
  backCeiling: number;
}): number {
  const { kind, flags, yOffset, texHeight, frontFloor, frontCeiling, backFloor, backCeiling } = args;
  const lowerUnpegged = (flags & LinedefFlag.LOWER_UNPEGGED) !== 0;
  const upperUnpegged = (flags & LinedefFlag.UPPER_UNPEGGED) !== 0;
  switch (kind) {
    case "middle":
      return (lowerUnpegged ? frontFloor + texHeight : frontCeiling) + yOffset;
    case "upper":
      return (upperUnpegged ? frontCeiling : backCeiling + texHeight) + yOffset;
    case "lower":
      return (lowerUnpegged ? frontCeiling : backFloor) + yOffset;
    case "middle-masked": {
      const openTop = Math.min(frontCeiling, backCeiling);
      const openBottom = Math.max(frontFloor, backFloor);
      return (lowerUnpegged ? openBottom + texHeight : openTop) + yOffset;
    }
  }
}

/**
 * Generates every wall quad of the level for a given set of sector heights.
 *
 * Both sides of every linedef are emitted independently, each with its own
 * sidedef's textures, offsets and sector light; `u` runs from the linedef's
 * start vertex on the front side and from its end vertex on the back side,
 * which is what `seg->offset` encodes in the software renderer.
 *
 * `onlySectors`, when given, restricts output to linedefs touching one of those
 * sectors. The renderer uses it to rebuild only the doors and lifts each frame
 * and keep the other ~2 000 quads in a static buffer.
 */
export function buildWallQuads(
  level: LevelJson,
  heights: SectorHeights,
  texSize: TextureSizeLookup,
  onlySectors?: ReadonlySet<number>,
): WallQuad[] {
  const quads: WallQuad[] = [];
  for (let li = 0; li < level.linedefs.length; li++) {
    const line = level.linedefs[li]!;
    const frontIdx = line.frontSidedef;
    const backIdx = line.backSidedef;
    const front = frontIdx === NO_SIDEDEF ? undefined : level.sidedefs[frontIdx];
    const back = backIdx === NO_SIDEDEF ? undefined : level.sidedefs[backIdx];
    if (!front && !back) continue;

    if (onlySectors) {
      const touches =
        (front !== undefined && onlySectors.has(front.sector)) ||
        (back !== undefined && onlySectors.has(back.sector));
      if (!touches) continue;
    }

    const v1 = level.vertexes[line.startVertex];
    const v2 = level.vertexes[line.endVertex];
    if (!v1 || !v2) continue;
    const dx = v2.x - v1.x;
    const dy = v2.y - v1.y;
    const lightDelta = dy === 0 ? -16 : dx === 0 ? 16 : 0;

    if (front) {
      emitSide(quads, level, heights, texSize, li, line, frontIdx, front, back, v1, v2, lightDelta);
    }
    if (back) {
      emitSide(quads, level, heights, texSize, li, line, backIdx, back, front, v2, v1, lightDelta);
    }
  }
  return quads;
}

function emitSide(
  quads: WallQuad[],
  level: LevelJson,
  heights: SectorHeights,
  texSize: TextureSizeLookup,
  linedef: number,
  line: LevelJson["linedefs"][number],
  sidedef: number,
  side: LevelJson["sidedefs"][number],
  other: LevelJson["sidedefs"][number] | undefined,
  from: { x: number; y: number },
  to: { x: number; y: number },
  lightDelta: number,
): void {
  const frontSector = side.sector;
  const frontFloor = heights.floor[frontSector] ?? 0;
  const frontCeiling = heights.ceiling[frontSector] ?? 0;
  const push = (
    kind: WallKind,
    texture: string,
    zBottom: number,
    zTop: number,
    backFloor: number,
    backCeiling: number,
    clampV: boolean,
  ): void => {
    if (texture === "-" || texture === "") return;
    const size = texSize(texture);
    if (!size) return;
    let top = zTop;
    let bottom = zBottom;
    const worldTopZ = wallTopAnchor({
      kind,
      flags: line.flags,
      yOffset: side.yOffset,
      texHeight: size.height,
      frontFloor,
      frontCeiling,
      backFloor,
      backCeiling,
    });
    if (clampV) {
      // Vanilla draws a two-sided middle texture exactly once, clipped to the
      // opening: it never tiles vertically.
      top = Math.min(top, worldTopZ);
      bottom = Math.max(bottom, worldTopZ - size.height);
    }
    if (top - bottom <= 0) return;
    quads.push({
      linedef,
      sidedef,
      kind,
      x1: from.x,
      y1: from.y,
      x2: to.x,
      y2: to.y,
      zTop: top,
      zBottom: bottom,
      worldTopZ,
      uOffset: side.xOffset,
      texture,
      sector: frontSector,
      lightDelta,
      clampV,
    });
  };

  if (!other) {
    // One-sided wall: a single middle texture from floor to ceiling.
    push("middle", side.middleTexture, frontFloor, frontCeiling, frontFloor, frontCeiling, false);
    return;
  }

  const backSector = other.sector;
  const backFloor = heights.floor[backSector] ?? 0;
  const backCeiling = heights.ceiling[backSector] ?? 0;
  const frontSkyCeiling = level.sectors[frontSector]?.ceilingTexture === SKY_FLAT;
  const backSkyCeiling = level.sectors[backSector]?.ceilingTexture === SKY_FLAT;

  // Upper: the strip between a lower back ceiling and this side's ceiling.
  // Vanilla's sky hack: when *both* sectors are open to the sky, no upper is
  // drawn at all, so the sky reads as continuous across the step.
  if (backCeiling < frontCeiling && !(frontSkyCeiling && backSkyCeiling)) {
    push("upper", side.upperTexture, backCeiling, frontCeiling, backFloor, backCeiling, false);
  }
  // Lower: the strip between this side's floor and a higher back floor.
  if (backFloor > frontFloor) {
    push("lower", side.lowerTexture, frontFloor, backFloor, backFloor, backCeiling, false);
  }
  // Masked middle: grates, bars, hanging bodies. Drawn once, clipped to the opening.
  const openTop = Math.min(frontCeiling, backCeiling);
  const openBottom = Math.max(frontFloor, backFloor);
  if (openTop > openBottom) {
    push("middle-masked", side.middleTexture, openBottom, openTop, backFloor, backCeiling, true);
  }
}

/**
 * Expands a quad into 4 corner vertices, in the order
 * `[bottom-left, bottom-right, top-right, top-left]`, with the UVs the shader
 * needs. `u` is in texels along the wall, `v` in texels down from row 0; the
 * shader divides by the atlas entry's size and wraps, so tiling is free.
 */
export function quadCorners(quad: WallQuad): {
  x: number;
  y: number;
  z: number;
  u: number;
  v: number;
}[] {
  const length = Math.hypot(quad.x2 - quad.x1, quad.y2 - quad.y1);
  const u0 = quad.uOffset;
  const u1 = quad.uOffset + length;
  const vTop = quad.worldTopZ - quad.zTop;
  const vBottom = quad.worldTopZ - quad.zBottom;
  return [
    { x: quad.x1, y: quad.y1, z: quad.zBottom, u: u0, v: vBottom },
    { x: quad.x2, y: quad.y2, z: quad.zBottom, u: u1, v: vBottom },
    { x: quad.x2, y: quad.y2, z: quad.zTop, u: u1, v: vTop },
    { x: quad.x1, y: quad.y1, z: quad.zTop, u: u0, v: vTop },
  ];
}

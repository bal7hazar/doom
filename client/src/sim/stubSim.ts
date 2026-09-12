import { buildSubsectorPolygons, pointInSector, signedArea } from "../map/bsp.js";
import { NO_SIDEDEF, playerStart, type LevelJson } from "../map/level.js";
import { mobjInfoFor, NON_DRAWABLE_DOOMEDNUMS } from "../map/mobjInfo.js";
import {
  degreesToBam,
  MobjRenderFlag,
  pointToAngle,
  toFixed,
  VIEW_HEIGHT,
  type MobjSnapshot,
  type RenderSnapshot,
  type SectorSnapshot,
} from "./snapshot.js";

/**
 * A stand-in for the Cairo sim Worker (roadmap P2.3), so the renderer can be
 * demoed and profiled today.
 *
 * It fills exactly the `RenderSnapshot` the real Worker will fill, and nothing
 * else: no collision, no AI, no ticcmd consumption. What it *does* exercise is
 * every field the renderer reads —
 *
 *  - a player walking a scripted tour of the map with head bob, so
 *    interpolation between 35 Hz tics is visible at 60+ fps;
 *  - one animated door (a real linedef special 1 on the map) so moving
 *    floors/ceilings and the wall-pegging rebuild are exercised;
 *  - vanilla's strobe and flicker light specials on the sectors that carry
 *    them, so the per-sector light path is exercised;
 *  - every THING as a mobj, with its spawn-state frame animation, so sprite
 *    rotation selection and billboarding are exercised.
 *
 * The tour is derived from the map rather than hard-coded: a greedy
 * nearest-neighbour walk of the sector adjacency graph from the player start,
 * routed through the midpoints of the two-sided linedefs that connect them.
 * That keeps the stub working on any map tools/wad can extract, not just E1M1.
 */
export interface StubSim {
  stepTic(tic: number): RenderSnapshot;
  /** Waypoints of the scripted tour, for the automap overlay. */
  readonly path: { x: number; y: number }[];
}

interface StubMobj {
  id: number;
  type: number;
  x: number;
  y: number;
  z: number;
  angleBam: number;
  sector: number;
  frames: number[];
  ticsPerFrame: number;
  flags: number;
}

/** Walking speed in map units per tic; vanilla's run tops out near 17. */
const WALK_SPEED = 11;
/** Half-width, in map units, of the look-ahead window that smooths the yaw. */
const LOOK_AHEAD = 40;

export function createStubSim(level: LevelJson, skill = 3): StubSim {
  const centroids = sectorCentroids(level);
  const path = buildTour(level, centroids);
  const mobjs = spawnMobjs(level, skill);
  const door = findDoor(level);
  const lightSectors = level.sectors
    .map((s, index) => ({ index, special: s.specialType, light: s.lightLevel }))
    .filter((s) => [1, 2, 3, 4, 8, 12, 13, 17].includes(s.special));

  // Pre-compute the arc length of the tour so the walk can be a pure function
  // of the tic number (no hidden state: the renderer may ask for any tic).
  const legs: { from: { x: number; y: number }; to: { x: number; y: number }; length: number }[] = [];
  for (let i = 0; i + 1 < path.length; i++) {
    const from = path[i]!;
    const to = path[i + 1]!;
    legs.push({ from, to, length: Math.max(1, Math.hypot(to.x - from.x, to.y - from.y)) });
  }
  const totalLength = legs.reduce((s, l) => s + l.length, 0);

  const totals = countTotals(level, skill);

  return {
    path,
    stepTic(tic: number): RenderSnapshot {
      // The tour loops, reversing at the end so the player never teleports.
      const cycle = (totalLength / WALK_SPEED) * 2;
      const phase = ((tic % cycle) + cycle) % cycle;
      const forward = phase < cycle / 2;
      const travelled = (forward ? phase : cycle - phase) * WALK_SPEED;

      const at = positionAt(legs, travelled);
      // Look ahead and behind along the tour and take the chord's direction:
      // averaging over a ~80-unit window turns corners into smooth arcs instead
      // of the yaw snapping at every waypoint.
      const dir = forward ? 1 : -1;
      const behind = positionAt(legs, travelled - LOOK_AHEAD * dir);
      const ahead = positionAt(legs, travelled + LOOK_AHEAD * dir);
      const smoothed = pointToAngle(ahead.x - behind.x, ahead.y - behind.y);

      const sector = pointInSector(level, at.x, at.y);
      const sectorDef = level.sectors[sector];
      const floor = sectorDef?.floorHeight ?? 0;
      const ceiling = sectorDef?.ceilingHeight ?? floor + 128;
      // `P_CalcHeight`'s bob: a small sine at half the movement period.
      const bob = Math.sin((tic / 20) * Math.PI) * 2.2;
      // The tour routes through linedef midpoints, which are often door tracks
      // and other sectors with less than VIEWHEIGHT of head room. With no
      // collision to stop it, the stub would put the eye inside the ceiling
      // and the renderer would look out of the map; clamping is what
      // `P_CalcHeight` does after `P_TryMove` has already kept the body below
      // the ceiling.
      const viewZ = Math.max(floor, Math.min(floor + VIEW_HEIGHT + bob, ceiling - 4));

      const dynamicSectors: SectorSnapshot[] = [];
      if (door) {
        dynamicSectors.push({
          index: door.sector,
          floorHeight: toFixed(door.floorHeight),
          ceilingHeight: toFixed(doorCeiling(door, tic)),
          lightLevel: level.sectors[door.sector]?.lightLevel ?? 160,
        });
      }
      for (const s of lightSectors) {
        if (door && s.index === door.sector) continue;
        dynamicSectors.push({
          index: s.index,
          floorHeight: toFixed(level.sectors[s.index]!.floorHeight),
          ceilingHeight: toFixed(level.sectors[s.index]!.ceilingHeight),
          lightLevel: blinkLight(s.special, s.light, s.index, tic),
        });
      }

      return {
        tic,
        player: {
          x: toFixed(at.x),
          y: toFixed(at.y),
          z: toFixed(floor),
          viewZ: toFixed(viewZ),
          angle: smoothed,
          pitch: 0,
          sector,
          health: 100,
          armor: 0,
          armorType: 0,
          ammo: [50, 0, 0, 0],
          maxAmmo: [200, 50, 300, 50],
          weapon: 1,
          pendingWeapon: 1,
          keys: 0,
          damageCount: 0,
          bonusCount: 0,
          attackTic: 0,
        },
        mobjs: mobjs.map((mo) => toSnapshot(mo, tic)),
        sectors: dynamicSectors,
        stats: {
          kills: 0,
          items: 0,
          secrets: 0,
          totalKills: totals.kills,
          totalItems: totals.items,
          totalSecrets: totals.secrets,
          levelTime: tic,
        },
      };
    },
  };
}

function toSnapshot(mo: StubMobj, tic: number): MobjSnapshot {
  const step = Math.floor(tic / mo.ticsPerFrame) % mo.frames.length;
  return {
    id: mo.id,
    type: mo.type,
    frame: mo.frames[step]!,
    flags: mo.flags,
    x: toFixed(mo.x),
    y: toFixed(mo.y),
    z: toFixed(mo.z),
    angle: mo.angleBam,
    sector: mo.sector,
  };
}

function spawnMobjs(level: LevelJson, skill: number): StubMobj[] {
  const skillBit = skill <= 2 ? 1 : skill === 3 ? 2 : 4;
  const out: StubMobj[] = [];
  let id = 1;
  for (const thing of level.things) {
    if (NON_DRAWABLE_DOOMEDNUMS.has(thing.type)) continue;
    if ((thing.flags & 0x0010) !== 0) continue; // multiplayer only
    if ((thing.flags & skillBit) === 0) continue;
    const info = mobjInfoFor(thing.type);
    if (!info) continue;
    const sector = pointInSector(level, thing.x, thing.y);
    const def = level.sectors[sector];
    const z = info.hangs
      ? (def?.ceilingHeight ?? 0) - info.height
      : (def?.floorHeight ?? 0);
    out.push({
      id: id++,
      type: thing.type,
      x: thing.x,
      y: thing.y,
      z,
      angleBam: degreesToBam(thing.angle),
      sector,
      frames: info.frames,
      ticsPerFrame: info.ticsPerFrame,
      flags:
        (info.fullbright ? MobjRenderFlag.FULLBRIGHT : 0) |
        (thing.type === 58 ? MobjRenderFlag.SHADOW : 0) |
        (info.hangs ? MobjRenderFlag.CEILING : 0),
    });
  }
  return out;
}

function countTotals(level: LevelJson, skill: number): { kills: number; items: number; secrets: number } {
  const skillBit = skill <= 2 ? 1 : skill === 3 ? 2 : 4;
  let kills = 0;
  let items = 0;
  for (const thing of level.things) {
    if ((thing.flags & skillBit) === 0) continue;
    if ((thing.flags & 0x0010) !== 0) continue;
    const info = mobjInfoFor(thing.type);
    if (!info) continue;
    if (thing.type >= 3001 || [9, 58, 64, 65, 66, 67, 68, 69, 71, 72, 84, 7, 16].includes(thing.type)) {
      kills++;
    }
    if ([2018, 2019, 2013, 2022, 2023, 2024, 2026, 2045, 83].includes(thing.type)) items++;
  }
  const secrets = level.sectors.filter((s) => s.specialType === 9).length;
  return { kills, items, secrets };
}

/** A tagless manual door (special 1/26/27/28/31/…): its back sector is what moves. */
function findDoor(
  level: LevelJson,
): { sector: number; floorHeight: number; closedHeight: number; openHeight: number } | null {
  for (const line of level.linedefs) {
    if (line.specialType !== 1 && line.specialType !== 117) continue;
    if (line.backSidedef === NO_SIDEDEF) continue;
    const sectorIndex = level.sidedefs[line.backSidedef]?.sector;
    if (sectorIndex === undefined) continue;
    const sector = level.sectors[sectorIndex];
    if (!sector) continue;
    // Vanilla opens a door to the lowest neighbouring ceiling minus 4.
    let lowestNeighbour = Infinity;
    for (const li of level.derived.sectorLines[sectorIndex] ?? []) {
      const l = level.linedefs[li]!;
      for (const side of [l.frontSidedef, l.backSidedef]) {
        const s = side === NO_SIDEDEF ? undefined : level.sidedefs[side]?.sector;
        if (s === undefined || s === sectorIndex) continue;
        lowestNeighbour = Math.min(lowestNeighbour, level.sectors[s]!.ceilingHeight);
      }
    }
    if (!Number.isFinite(lowestNeighbour)) continue;
    return {
      sector: sectorIndex,
      floorHeight: sector.floorHeight,
      closedHeight: sector.ceilingHeight,
      openHeight: lowestNeighbour - 4,
    };
  }
  return null;
}

/** Vanilla door timing: 2 units/tic, 150 tics open, 2 units/tic closing. */
function doorCeiling(
  door: { closedHeight: number; openHeight: number },
  tic: number,
): number {
  const travel = Math.max(0, door.openHeight - door.closedHeight);
  const moveTics = Math.ceil(travel / 2);
  const cycle = moveTics * 2 + 150 + 70;
  const t = ((tic % cycle) + cycle) % cycle;
  if (t < 70) return door.closedHeight;
  if (t < 70 + moveTics) return door.closedHeight + (t - 70) * 2;
  if (t < 70 + moveTics + 150) return door.openHeight;
  const closing = t - (70 + moveTics + 150);
  return Math.max(door.closedHeight, door.openHeight - closing * 2);
}

/**
 * Vanilla light specials, reduced to the three the maps actually use:
 * 1 flicker (random), 2/3/12/13 strobe (fast/slow, synchronised or not),
 * 8 glow. The "random" one is a hash of the tic so it stays deterministic.
 */
function blinkLight(special: number, base: number, sectorIndex: number, tic: number): number {
  switch (special) {
    case 1: {
      const h = Math.imul(tic >> 2, 2654435761) ^ Math.imul(sectorIndex, 40503);
      return (h & 3) === 0 ? Math.max(0, base - 96) : base;
    }
    case 2:
    case 4:
    case 13:
      return tic % 20 < 5 ? Math.max(0, base - 96) : base;
    case 3:
    case 12:
      return tic % 70 < 5 ? Math.max(0, base - 96) : base;
    case 8: {
      const t = (tic % 128) / 128;
      return Math.round(base - 60 * (1 - Math.abs(2 * t - 1)));
    }
    case 17:
      return tic % 16 < 4 ? Math.min(255, base + 40) : base;
    default:
      return base;
  }
}

/**
 * Area-weighted centroid of every sector, from its subsector polygons.
 *
 * Polygons are clamped to the map bounding box first: `buildSubsectorPolygons`
 * starts from a rectangle grown by a margin, so the leaves along the map's
 * outer boundary extend past it. Without the clamp a border sector's centroid
 * can land outside the map and the tour walks into the void.
 */
export function sectorCentroids(level: LevelJson): Map<number, { x: number; y: number }> {
  const bb = level.boundingBox;
  const clampX = (v: number): number => Math.min(bb.maxX, Math.max(bb.minX, v));
  const clampY = (v: number): number => Math.min(bb.maxY, Math.max(bb.minY, v));
  const acc = new Map<number, { x: number; y: number; area: number }>();
  for (const poly of buildSubsectorPolygons(level)) {
    const points = poly.points.map((p) => ({ x: clampX(p.x), y: clampY(p.y) }));
    const area = Math.abs(signedArea(points));
    if (area <= 0) continue;
    let cx = 0;
    let cy = 0;
    for (const p of points) {
      cx += p.x;
      cy += p.y;
    }
    cx /= points.length;
    cy /= points.length;
    const entry = acc.get(poly.sector) ?? { x: 0, y: 0, area: 0 };
    entry.x += cx * area;
    entry.y += cy * area;
    entry.area += area;
    acc.set(poly.sector, entry);
  }
  const out = new Map<number, { x: number; y: number }>();
  for (const [sector, e] of acc) out.set(sector, { x: e.x / e.area, y: e.y / e.area });
  return out;
}

/**
 * Breadth-first tour of the sector graph from the player start, routed through
 * the midpoints of the connecting two-sided linedefs.
 */
function buildTour(
  level: LevelJson,
  centroids: Map<number, { x: number; y: number }>,
  maxSectors = 24,
): { x: number; y: number }[] {
  const start = playerStart(level);
  const startSector = pointInSector(level, start.x, start.y);

  // sector -> [{ neighbour, portal }]
  const adjacency = new Map<number, { neighbour: number; portal: { x: number; y: number } }[]>();
  for (const line of level.linedefs) {
    if (line.frontSidedef === NO_SIDEDEF || line.backSidedef === NO_SIDEDEF) continue;
    const a = level.sidedefs[line.frontSidedef]?.sector;
    const b = level.sidedefs[line.backSidedef]?.sector;
    if (a === undefined || b === undefined || a === b) continue;
    const v1 = level.vertexes[line.startVertex]!;
    const v2 = level.vertexes[line.endVertex]!;
    const portal = { x: (v1.x + v2.x) / 2, y: (v1.y + v2.y) / 2 };
    (adjacency.get(a) ?? setDefault(adjacency, a)).push({ neighbour: b, portal });
    (adjacency.get(b) ?? setDefault(adjacency, b)).push({ neighbour: a, portal });
  }

  const path: { x: number; y: number }[] = [{ x: start.x, y: start.y }];
  const visited = new Set<number>([startSector]);
  let current = startSector;

  // Greedy depth-first walk: always step into the nearest unvisited neighbour,
  // which produces a tour that reads as exploration instead of teleporting
  // across the map the way a plain BFS order would.
  while (visited.size < maxSectors) {
    const options = (adjacency.get(current) ?? []).filter((o) => !visited.has(o.neighbour));
    if (options.length === 0) break;
    const here = path[path.length - 1]!;
    options.sort(
      (p, q) => Math.hypot(p.portal.x - here.x, p.portal.y - here.y) - Math.hypot(q.portal.x - here.x, q.portal.y - here.y),
    );
    const next = options[0]!;
    path.push(next.portal);
    const centroid = centroids.get(next.neighbour);
    if (centroid) path.push(centroid);
    visited.add(next.neighbour);
    current = next.neighbour;
  }

  if (path.length < 2) path.push({ x: start.x + 64, y: start.y });
  return path;
}

function setDefault(
  map: Map<number, { neighbour: number; portal: { x: number; y: number } }[]>,
  key: number,
): { neighbour: number; portal: { x: number; y: number } }[] {
  const value: { neighbour: number; portal: { x: number; y: number } }[] = [];
  map.set(key, value);
  return value;
}

function positionAt(
  legs: { from: { x: number; y: number }; to: { x: number; y: number }; length: number }[],
  distance: number,
): { x: number; y: number } {
  if (legs.length === 0) return { x: 0, y: 0 };
  let d = Math.max(0, distance);
  for (const leg of legs) {
    if (d <= leg.length) {
      const t = d / leg.length;
      return { x: leg.from.x + (leg.to.x - leg.from.x) * t, y: leg.from.y + (leg.to.y - leg.from.y) * t };
    }
    d -= leg.length;
  }
  return { ...legs[legs.length - 1]!.to };
}


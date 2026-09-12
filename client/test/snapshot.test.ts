import { describe, expect, it } from "vitest";
import type { LevelJson } from "../src/map/level.js";
import {
  decodeSnapshot,
  degreesToBam,
  encodeSnapshot,
  Header,
  interpolate,
  lerpBam,
  MAX_MOBJS,
  MobjRenderFlag,
  pointToAngle,
  RING_BYTES,
  SNAPSHOT_WORDS,
  SnapshotRing,
  toFixed,
  VIEW_HEIGHT,
  type RenderSnapshot,
} from "../src/sim/snapshot.js";
import { createStubSim } from "../src/sim/stubSim.js";
import { loadLevel } from "./fixture.js";

const level = loadLevel<LevelJson>();

function sampleSnapshot(tic: number): RenderSnapshot {
  return {
    tic,
    player: {
      x: toFixed(100 + tic * 10),
      y: toFixed(-200),
      z: toFixed(8),
      viewZ: toFixed(49),
      angle: degreesToBam(90),
      pitch: 0,
      sector: 7,
      health: 87,
      armor: 42,
      armorType: 2,
      ammo: [50, 12, 300, 4],
      maxAmmo: [200, 50, 300, 50],
      weapon: 2,
      pendingWeapon: 3,
      keys: 0b010101,
      damageCount: 9,
      bonusCount: 3,
      attackTic: 1,
    },
    mobjs: [
      { id: 1, type: 3001, frame: 2, flags: MobjRenderFlag.FULLBRIGHT, x: toFixed(64), y: toFixed(64), z: toFixed(0), angle: degreesToBam(180), sector: 3 },
      { id: 2, type: 2014, frame: 0, flags: 0, x: toFixed(-32), y: toFixed(16), z: toFixed(24), angle: 0, sector: 4 },
    ],
    sectors: [
      { index: 12, floorHeight: toFixed(0), ceilingHeight: toFixed(64 + tic), lightLevel: 176 },
    ],
    stats: {
      kills: 3,
      items: 1,
      secrets: 0,
      totalKills: 44,
      totalItems: 12,
      totalSecrets: 4,
      levelTime: tic,
    },
  };
}

describe("snapshot binary codec", () => {
  it("round-trips every field", () => {
    const snap = sampleSnapshot(17);
    const buffer = new Int32Array(SNAPSHOT_WORDS);
    encodeSnapshot(buffer, snap);
    expect(decodeSnapshot(buffer)).toEqual(snap);
  });

  it("stays inside the budget S3 §7.2 assumes for a render snapshot", () => {
    // "quelques kilo-octets, pas les 48 ko d'état" - the whole simulation state
    // must never leak into the published snapshot.
    expect(SNAPSHOT_WORDS * 4).toBeLessThan(24 * 1024);
    expect(RING_BYTES).toBeLessThan(96 * 1024);
  });

  it("truncates rather than overflowing when a map exceeds the mobj cap", () => {
    const snap = sampleSnapshot(0);
    snap.mobjs = Array.from({ length: MAX_MOBJS + 40 }, (_, i) => ({ ...snap.mobjs[0]!, id: i }));
    const buffer = new Int32Array(SNAPSHOT_WORDS);
    encodeSnapshot(buffer, snap);
    expect(decodeSnapshot(buffer).mobjs).toHaveLength(MAX_MOBJS);
  });

  it("keeps BAM angles unsigned across the round trip", () => {
    const snap = sampleSnapshot(0);
    snap.player.angle = 0xf0000000; // would become negative as a signed i32
    const buffer = new Int32Array(SNAPSHOT_WORDS);
    encodeSnapshot(buffer, snap);
    expect(decodeSnapshot(buffer).player.angle).toBe(0xf0000000);
  });
});

describe("SnapshotRing (S3 §7.3 seqlock on a triple buffer)", () => {
  it("publishes into a rotating slot and advertises the tic in the header", () => {
    const ring = new SnapshotRing();
    const header = new Int32Array(ring.buffer, 0, Header.WORDS);
    expect(header[Header.PUBLISHED]).toBe(-1);
    ring.publish(sampleSnapshot(0));
    expect(header[Header.PUBLISHED]).toBe(0);
    expect(header[Header.TIC]).toBe(0);
    expect(header[Header.SEQ]).toBe(1);
    ring.publish(sampleSnapshot(1));
    ring.publish(sampleSnapshot(2));
    ring.publish(sampleSnapshot(3));
    expect(header[Header.PUBLISHED]).toBe(0); // wrapped through three slots
    expect(header[Header.TIC]).toBe(3);
  });

  it("returns nothing until two tics have been published", () => {
    const ring = new SnapshotRing();
    expect(ring.readPair()).toBeNull();
    ring.publish(sampleSnapshot(0));
    expect(ring.readPair()).toBeNull();
    ring.publish(sampleSnapshot(1));
    expect(ring.readPair()).not.toBeNull();
  });

  it("hands back consecutive tics, newest last", () => {
    const ring = new SnapshotRing();
    for (let t = 0; t <= 5; t++) ring.publish(sampleSnapshot(t));
    const pair = ring.readPair()!;
    expect(pair.previous.tic).toBe(4);
    expect(pair.current.tic).toBe(5);
  });

  it("carries ticcmds through the input ring", () => {
    const ring = new SnapshotRing();
    expect(ring.readTiccmd(0)).toBeNull();
    ring.pushTiccmd(0, 0x1234, 0x5678);
    expect(ring.readTiccmd(0)).toEqual({ low: 0x1234, high: 0x5678 });
    // A tic the main thread has not written yet must read as absent, so the
    // Worker repeats the previous command rather than inventing one.
    expect(ring.readTiccmd(1)).toBeNull();
  });

  it("accepts an externally allocated buffer of the right size", () => {
    const ring = new SnapshotRing(new ArrayBuffer(RING_BYTES));
    expect(ring.shared).toBe(false);
    expect(() => new SnapshotRing(new ArrayBuffer(RING_BYTES - 4))).toThrow(/expected/);
  });
});

describe("interpolation", () => {
  it("blends positions and takes the newer discrete values", () => {
    const a = sampleSnapshot(10);
    const b = sampleSnapshot(11);
    b.player.health = 50;
    b.mobjs[0]!.frame = 5;
    const view = interpolate(a, b, 0.5);
    expect(view.x).toBeCloseTo(205, 6); // halfway between 100+10*10 and 100+11*10
    expect(view.latest.player.health).toBe(50);
    expect(view.mobjs[0]!.frame).toBe(5);
  });

  it("clamps the factor so a late frame never extrapolates", () => {
    const a = sampleSnapshot(0);
    const b = sampleSnapshot(1);
    expect(interpolate(a, b, 2).x).toBe(interpolate(a, b, 1).x);
    expect(interpolate(a, b, -1).x).toBe(interpolate(a, b, 0).x);
  });

  it("takes the shortest arc across the BAM wrap", () => {
    // 350° -> 10° is +20°, not -340°.
    const from = degreesToBam(350);
    const to = degreesToBam(10);
    // The midpoint is 0°/360°, up to the one-unit rounding of degreesToBam.
    const distanceFromZero = (bam: number): number => Math.abs((bam | 0) >> 0);
    expect(distanceFromZero(lerpBam(from, to, 0.5))).toBeLessThan(8);
    expect(distanceFromZero(lerpBam(to, from, 0.5))).toBeLessThan(8);
    // A quarter of the way is a +5° turn, not -85°.
    expect(lerpBam(from, to, 0.25)).toBeCloseTo(degreesToBam(355), -4);
  });

  it("does not blend a mobj that is new or flagged TELEPORTED", () => {
    const a = sampleSnapshot(0);
    const b = sampleSnapshot(1);
    b.mobjs[0]!.x = toFixed(1000);
    b.mobjs[0]!.flags |= MobjRenderFlag.TELEPORTED;
    b.mobjs.push({ ...b.mobjs[1]!, id: 99, x: toFixed(500) });
    const view = interpolate(a, b, 0.5);
    expect(view.mobjs.find((m) => m.id === 1)!.x).toBe(1000);
    expect(view.mobjs.find((m) => m.id === 99)!.x).toBe(500);
  });

  it("blends sector heights but not light levels", () => {
    const a = sampleSnapshot(0);
    const b = sampleSnapshot(1);
    b.sectors[0]!.lightLevel = 64;
    const view = interpolate(a, b, 0.5);
    const sector = view.sectors.get(12)!;
    expect(sector.ceiling).toBeCloseTo(64.5, 6);
    // Vanilla's strobes flip on tic boundaries; blending would blur them.
    expect(sector.light).toBe(64);
  });
});

describe("angle helpers", () => {
  it("maps degrees onto BAM quadrants", () => {
    expect(degreesToBam(0)).toBe(0);
    expect(degreesToBam(90)).toBe(0x40000000);
    expect(degreesToBam(180)).toBe(0x80000000);
    expect(degreesToBam(270)).toBe(0xc0000000);
    expect(degreesToBam(360)).toBe(0);
    expect(degreesToBam(-90)).toBe(0xc0000000);
  });

  it("computes R_PointToAngle on the axes", () => {
    expect(pointToAngle(1, 0)).toBe(0);
    expect(pointToAngle(0, 1)).toBe(0x40000000);
    expect(pointToAngle(-1, 0)).toBe(0x80000000);
    expect(pointToAngle(0, -1)).toBe(0xc0000000);
  });
});

describe.skipIf(!level)("stub sim on real E1M1", () => {
  const e1m1 = level!;

  it("produces a tour of several waypoints inside the map", () => {
    const sim = createStubSim(e1m1);
    expect(sim.path.length).toBeGreaterThan(8);
    for (const p of sim.path) {
      expect(p.x).toBeGreaterThanOrEqual(e1m1.boundingBox.minX);
      expect(p.x).toBeLessThanOrEqual(e1m1.boundingBox.maxX);
      expect(p.y).toBeGreaterThanOrEqual(e1m1.boundingBox.minY);
      expect(p.y).toBeLessThanOrEqual(e1m1.boundingBox.maxY);
    }
  });

  it("is a pure function of the tic, as the renderer assumes", () => {
    const sim = createStubSim(e1m1);
    expect(sim.stepTic(123)).toEqual(sim.stepTic(123));
    // Asking out of order must not change anything either.
    const a = sim.stepTic(500);
    sim.stepTic(0);
    expect(sim.stepTic(500)).toEqual(a);
  });

  it("keeps the eye inside the sector it is standing in", () => {
    // The stub has no collision (that is the Cairo core's job) and the tour
    // routes through door tracks, so it clamps the eye to the sector instead.
    // Whatever happens it must never end up above the ceiling, which would
    // make the renderer look out of the map.
    const sim = createStubSim(e1m1);
    let roomy = 0;
    let samples = 0;
    for (let tic = 0; tic < 2000; tic += 7) {
      const snap = sim.stepTic(tic);
      const sector = e1m1.sectors[snap.player.sector]!;
      const viewZ = snap.player.viewZ / 65536;
      expect(viewZ).toBeGreaterThanOrEqual(sector.floorHeight);
      expect(viewZ).toBeLessThanOrEqual(sector.ceilingHeight);
      samples++;
      // Where there is head room, the eye sits at VIEWHEIGHT plus the bob.
      if (sector.ceilingHeight - sector.floorHeight > VIEW_HEIGHT + 8) {
        roomy++;
        expect(viewZ - sector.floorHeight).toBeGreaterThan(VIEW_HEIGHT - 3);
        expect(viewZ - sector.floorHeight).toBeLessThan(VIEW_HEIGHT + 3);
      }
    }
    expect(roomy / samples).toBeGreaterThan(0.5);
  });

  it("animates a door across its full travel", () => {
    const sim = createStubSim(e1m1);
    const heights = new Set<number>();
    let doorSector = -1;
    for (let tic = 0; tic < 600; tic++) {
      const snap = sim.stepTic(tic);
      const door = snap.sectors[0];
      if (!door) continue;
      doorSector = door.index;
      heights.add(door.ceilingHeight);
    }
    expect(doorSector).toBeGreaterThanOrEqual(0);
    // More than two distinct heights means it actually moves rather than
    // snapping between open and closed.
    expect(heights.size).toBeGreaterThan(8);
  });

  it("spawns drawable mobjs and never exceeds the snapshot cap", () => {
    const sim = createStubSim(e1m1);
    const snap = sim.stepTic(0);
    expect(snap.mobjs.length).toBeGreaterThan(50);
    expect(snap.mobjs.length).toBeLessThanOrEqual(MAX_MOBJS);
    expect(new Set(snap.mobjs.map((m) => m.id)).size).toBe(snap.mobjs.length);
  });

  it("survives the binary codec unchanged", () => {
    const sim = createStubSim(e1m1);
    const ring = new SnapshotRing();
    const snap = sim.stepTic(42);
    ring.publish(snap);
    expect(ring.readLatest()).toEqual(snap);
  });
});

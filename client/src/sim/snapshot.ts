/**
 * `RenderSnapshot` — the contract between the Cairo sim Worker (roadmap P2.3)
 * and the renderer (P2.2).
 *
 * This file is the *only* place the two sides agree on anything. It follows
 * `docs/spikes/S3.md` §7.2/§7.3 to the letter:
 *
 *   - one `SharedArrayBuffer` carries a 16-word header, a ticcmd input ring and
 *     **three** snapshot slots;
 *   - header words are `[SEQ, PUBLISHED, TIC, INPUT_HEAD, INPUT_TAIL, …]`, the
 *     names S3 uses;
 *   - the sim writes slot `(published + 1) % 3`, then `Atomics.store`s TIC and
 *     PUBLISHED and `Atomics.add`s SEQ; the renderer reads SEQ, reads the slot,
 *     re-reads SEQ and retries on a mismatch (seqlock);
 *   - the third slot exists so the renderer can hold tics N-1 and N for
 *     interpolation while the sim writes N+1.
 *
 * The snapshot is explicitly **not** the simulation state: S3 §7.2 keeps the
 * ~48 kB of felts inside the Worker's wasm linear memory and publishes only
 * what is needed to draw a frame. `SNAPSHOT_BYTES` below is ~9 kB.
 *
 * Units and encodings are the Cairo core's, not the renderer's, so the Worker
 * can fill this in without conversions:
 *   - positions and heights are `fixed_t` (16.16 signed fixed point, i.e. map
 *     units × 65536), matching Doom and the `fixed` crate (PLAN P1.1);
 *   - angles are 32-bit BAM (`angle_t`: 2^32 = 360°), matching the `bam` crate;
 *   - light levels are 0–255 as stored in SECTORS.
 */

export const FRACBITS = 16;
export const FRACUNIT = 1 << FRACBITS;

/** Doom's `VIEWHEIGHT`: the eye sits 41 map units above the player's feet. */
export const VIEW_HEIGHT = 41;

export const TICRATE = 35;

export function toFixed(mapUnits: number): number {
  return Math.round(mapUnits * FRACUNIT);
}

export function fromFixed(fixed: number): number {
  return fixed / FRACUNIT;
}

export function bamToRadians(bam: number): number {
  return ((bam >>> 0) / 4294967296) * Math.PI * 2;
}

export function radiansToBam(rad: number): number {
  const turns = rad / (Math.PI * 2);
  return Math.floor((turns - Math.floor(turns)) * 4294967296) >>> 0;
}

export function degreesToBam(deg: number): number {
  const turns = deg / 360;
  return Math.floor((turns - Math.floor(turns)) * 4294967296) >>> 0;
}

/** `R_PointToAngle`: the BAM angle of the vector (dx, dy). */
export function pointToAngle(dx: number, dy: number): number {
  return radiansToBam(Math.atan2(dy, dx));
}

// ---------------------------------------------------------------------------
// Object form (what the renderer consumes)
// ---------------------------------------------------------------------------

export interface PlayerSnapshot {
  /** `fixed_t` map coordinates of the player's feet. */
  x: number;
  y: number;
  z: number;
  /** `fixed_t` eye height, absolute (z + VIEWHEIGHT + bob), as `player->viewz`. */
  viewZ: number;
  /** BAM yaw. */
  angle: number;
  /** BAM pitch; always 0 while the Cairo core is vanilla-faithful (no freelook). */
  pitch: number;
  /** Sector index the player stands in, so the renderer need not walk the BSP. */
  sector: number;
  health: number;
  armor: number;
  /** 0 = none, 1 = green (`ARMOR1`), 2 = blue (`ARMOR2`). */
  armorType: number;
  /** `[clip, shell, cell, misl]`, Doom's `ammo_t` order. */
  ammo: [number, number, number, number];
  maxAmmo: [number, number, number, number];
  /** `weapontype_t`: 0 fist … 8 chainsaw. */
  weapon: number;
  pendingWeapon: number;
  /** Bitfield: 1 blue card, 2 yellow card, 4 red card, 8/16/32 the skulls. */
  keys: number;
  /** Palette-flash counters, straight from `player_t`. */
  damageCount: number;
  bonusCount: number;
  /** `player->attackdown`-ish: non-zero while the weapon is firing (HUD only). */
  attackTic: number;
}

export interface MobjSnapshot {
  /** Stable identity across tics; required for interpolation. */
  id: number;
  /** doomednum, so the renderer can look the sprite up in `mobjInfo.ts`. */
  type: number;
  /** Sprite frame index (0 = 'A'). */
  frame: number;
  /** `MobjRenderFlag` bitfield. */
  flags: number;
  x: number;
  y: number;
  z: number;
  angle: number;
  sector: number;
}

export const MobjRenderFlag = {
  /** Draw at full brightness (`FF_FULLBRIGHT`). */
  FULLBRIGHT: 1 << 0,
  /** Spectre fuzz (`MF_SHADOW`). */
  SHADOW: 1 << 1,
  /** Hangs from the ceiling (`MF_SPAWNCEILING`): z is the *top* of the sprite. */
  CEILING: 1 << 2,
  /** Freshly spawned this tic: do not interpolate from the previous snapshot. */
  TELEPORTED: 1 << 3,
} as const;

export interface SectorSnapshot {
  index: number;
  /** `fixed_t`. */
  floorHeight: number;
  ceilingHeight: number;
  /** 0–255. */
  lightLevel: number;
}

export interface RenderSnapshot {
  /** Absolute game tic (35 Hz), monotonically increasing. */
  tic: number;
  player: PlayerSnapshot;
  /** Every live mobj; the renderer culls, the sim does not. */
  mobjs: MobjSnapshot[];
  /** Only sectors whose floor/ceiling/light differ from the level JSON. */
  sectors: SectorSnapshot[];
  /** Level tally for the HUD and the end-of-level screen (P2.6). */
  stats: {
    kills: number;
    items: number;
    secrets: number;
    totalKills: number;
    totalItems: number;
    totalSecrets: number;
    /** Level time in tics. */
    levelTime: number;
  };
}

// ---------------------------------------------------------------------------
// Binary layout (what actually crosses the SharedArrayBuffer)
// ---------------------------------------------------------------------------

/** Header word indices, named as in S3 §7.2. */
export const Header = {
  SEQ: 0,
  PUBLISHED: 1,
  TIC: 2,
  INPUT_HEAD: 3,
  INPUT_TAIL: 4,
  /** 0 running, 1 paused (deterministic pause, S3 §7.4), 2 finished. */
  STATE: 5,
  WORDS: 16,
} as const;

/** Ticcmd ring capacity, in tics. Two seconds is far more than the sim can lag. */
export const INPUT_RING_TICS = 128;
/** One ticcmd is packed into a single felt by the Cairo core, so one i32 pair here. */
export const INPUT_WORDS_PER_TIC = 2;

export const MAX_MOBJS = 512;
export const MAX_DYNAMIC_SECTORS = 128;

const PLAYER_WORDS = 20;
const STATS_WORDS = 8;
const MOBJ_WORDS = 9;
const SECTOR_WORDS = 4;

/** Word offsets inside one snapshot slot. */
const S = {
  TIC: 0,
  MOBJ_COUNT: 1,
  SECTOR_COUNT: 2,
  RESERVED: 3,
  PLAYER: 4,
  STATS: 4 + PLAYER_WORDS,
  MOBJS: 4 + PLAYER_WORDS + STATS_WORDS,
} as const;

export const SNAPSHOT_WORDS =
  S.MOBJS + MAX_MOBJS * MOBJ_WORDS + MAX_DYNAMIC_SECTORS * SECTOR_WORDS;
export const SNAPSHOT_BYTES = SNAPSHOT_WORDS * 4;

const SECTORS_OFFSET = S.MOBJS + MAX_MOBJS * MOBJ_WORDS;

export const SLOT_COUNT = 3;

export const RING_BYTES =
  Header.WORDS * 4 + INPUT_RING_TICS * INPUT_WORDS_PER_TIC * 4 + SLOT_COUNT * SNAPSHOT_BYTES;

const INPUT_OFFSET_WORDS = Header.WORDS;
const SLOTS_OFFSET_WORDS = INPUT_OFFSET_WORDS + INPUT_RING_TICS * INPUT_WORDS_PER_TIC;

/**
 * The triple-buffered ring from S3 §7.3, backed by a `SharedArrayBuffer` when
 * the document is cross-origin isolated and by a plain `ArrayBuffer` otherwise.
 *
 * The seqlock is correct in both cases: with a plain buffer the sim and the
 * renderer are on the same thread, so a read can never observe a torn write,
 * and the retry loop simply never fires.
 */
export class SnapshotRing {
  readonly buffer: ArrayBufferLike;
  readonly shared: boolean;
  private readonly header: Int32Array;
  private readonly input: Int32Array;
  private readonly slots: Int32Array[];

  constructor(buffer?: ArrayBufferLike) {
    if (buffer) {
      this.buffer = buffer;
      this.shared = typeof SharedArrayBuffer !== "undefined" && buffer instanceof SharedArrayBuffer;
    } else if (typeof SharedArrayBuffer !== "undefined" && globalThis.crossOriginIsolated) {
      this.buffer = new SharedArrayBuffer(RING_BYTES);
      this.shared = true;
    } else {
      this.buffer = new ArrayBuffer(RING_BYTES);
      this.shared = false;
    }
    if (this.buffer.byteLength !== RING_BYTES) {
      throw new Error(`SnapshotRing: buffer is ${this.buffer.byteLength} bytes, expected ${RING_BYTES}`);
    }
    this.header = new Int32Array(this.buffer, 0, Header.WORDS);
    this.input = new Int32Array(
      this.buffer,
      INPUT_OFFSET_WORDS * 4,
      INPUT_RING_TICS * INPUT_WORDS_PER_TIC,
    );
    this.slots = [];
    for (let i = 0; i < SLOT_COUNT; i++) {
      this.slots.push(
        new Int32Array(this.buffer, (SLOTS_OFFSET_WORDS + i * SNAPSHOT_WORDS) * 4, SNAPSHOT_WORDS),
      );
    }
    // A fresh ring starts with nothing published and no ticcmd recorded; -1
    // keeps `readLatest` and `readTiccmd` honest about tic 0, which is a
    // legitimate tic number and so cannot double as "empty".
    if (this.header[Header.SEQ] === 0 && this.header[Header.TIC] === 0) {
      this.header[Header.PUBLISHED] = -1;
      this.header[Header.INPUT_HEAD] = -1;
    }
  }

  get state(): number {
    return Atomics.load(this.header, Header.STATE);
  }

  set state(v: number) {
    Atomics.store(this.header, Header.STATE, v);
  }

  get tic(): number {
    return Atomics.load(this.header, Header.TIC);
  }

  /** Sim side: writes into the next slot and publishes it (S3 §7.3). */
  publish(snapshot: RenderSnapshot): void {
    const published = Atomics.load(this.header, Header.PUBLISHED);
    const next = (published + 1 + SLOT_COUNT) % SLOT_COUNT;
    encodeSnapshot(this.slots[next]!, snapshot);
    Atomics.store(this.header, Header.TIC, snapshot.tic);
    Atomics.store(this.header, Header.PUBLISHED, next);
    Atomics.add(this.header, Header.SEQ, 1);
  }

  /**
   * Renderer side: the most recent snapshot and the one before it, for
   * interpolation. Returns `null` until two tics have been published.
   *
   * The seqlock retry covers the whole pair, because the previous slot can be
   * overwritten while we decode the current one.
   */
  readPair(): { previous: RenderSnapshot; current: RenderSnapshot } | null {
    for (let attempt = 0; attempt < 8; attempt++) {
      const seq0 = Atomics.load(this.header, Header.SEQ);
      const index = Atomics.load(this.header, Header.PUBLISHED);
      if (index < 0 || seq0 < 2) return null;
      const current = decodeSnapshot(this.slots[index]!);
      const previous = decodeSnapshot(this.slots[(index + SLOT_COUNT - 1) % SLOT_COUNT]!);
      if (Atomics.load(this.header, Header.SEQ) === seq0) return { previous, current };
    }
    return null;
  }

  /** Renderer side: the latest snapshot alone (used by the HUD and the automap). */
  readLatest(): RenderSnapshot | null {
    for (let attempt = 0; attempt < 8; attempt++) {
      const seq0 = Atomics.load(this.header, Header.SEQ);
      const index = Atomics.load(this.header, Header.PUBLISHED);
      if (index < 0) return null;
      const snap = decodeSnapshot(this.slots[index]!);
      if (Atomics.load(this.header, Header.SEQ) === seq0) return snap;
    }
    return null;
  }

  /** Main thread → sim: records the ticcmd for a tic (P2.4 will fill this in). */
  pushTiccmd(tic: number, low: number, high: number): void {
    const slot = (tic % INPUT_RING_TICS) * INPUT_WORDS_PER_TIC;
    Atomics.store(this.input, slot, low | 0);
    Atomics.store(this.input, slot + 1, high | 0);
    Atomics.store(this.header, Header.INPUT_HEAD, tic);
  }

  /** Sim → main thread: the ticcmd recorded for a tic, or `null` if not yet written. */
  readTiccmd(tic: number): { low: number; high: number } | null {
    if (Atomics.load(this.header, Header.INPUT_HEAD) < tic) return null;
    const slot = (tic % INPUT_RING_TICS) * INPUT_WORDS_PER_TIC;
    return { low: Atomics.load(this.input, slot), high: Atomics.load(this.input, slot + 1) };
  }
}

export function encodeSnapshot(out: Int32Array, snap: RenderSnapshot): void {
  const p = snap.player;
  out[S.TIC] = snap.tic;
  out[S.MOBJ_COUNT] = Math.min(snap.mobjs.length, MAX_MOBJS);
  out[S.SECTOR_COUNT] = Math.min(snap.sectors.length, MAX_DYNAMIC_SECTORS);
  out[S.RESERVED] = 0;

  let o: number = S.PLAYER;
  out[o++] = p.x;
  out[o++] = p.y;
  out[o++] = p.z;
  out[o++] = p.viewZ;
  out[o++] = p.angle | 0;
  out[o++] = p.pitch | 0;
  out[o++] = p.sector;
  out[o++] = p.health;
  out[o++] = p.armor;
  out[o++] = p.armorType;
  out[o++] = p.ammo[0];
  out[o++] = p.ammo[1];
  out[o++] = p.ammo[2];
  out[o++] = p.ammo[3];
  out[o++] = p.maxAmmo[0];
  out[o++] = p.maxAmmo[1];
  out[o++] = p.maxAmmo[2];
  out[o++] = p.maxAmmo[3];
  out[o++] = (p.weapon & 0xff) | ((p.pendingWeapon & 0xff) << 8) | ((p.keys & 0xff) << 16);
  out[o++] = (p.damageCount & 0xff) | ((p.bonusCount & 0xff) << 8) | ((p.attackTic & 0xff) << 16);

  o = S.STATS;
  out[o++] = snap.stats.kills;
  out[o++] = snap.stats.items;
  out[o++] = snap.stats.secrets;
  out[o++] = snap.stats.totalKills;
  out[o++] = snap.stats.totalItems;
  out[o++] = snap.stats.totalSecrets;
  out[o++] = snap.stats.levelTime;
  out[o++] = 0;

  const mobjCount = out[S.MOBJ_COUNT]!;
  for (let i = 0; i < mobjCount; i++) {
    const mo = snap.mobjs[i]!;
    let b = S.MOBJS + i * MOBJ_WORDS;
    out[b++] = mo.id;
    out[b++] = mo.type;
    out[b++] = mo.frame;
    out[b++] = mo.flags;
    out[b++] = mo.x;
    out[b++] = mo.y;
    out[b++] = mo.z;
    out[b++] = mo.angle | 0;
    out[b] = mo.sector;
  }

  const sectorCount = out[S.SECTOR_COUNT]!;
  for (let i = 0; i < sectorCount; i++) {
    const sec = snap.sectors[i]!;
    let b = SECTORS_OFFSET + i * SECTOR_WORDS;
    out[b++] = sec.index;
    out[b++] = sec.floorHeight;
    out[b++] = sec.ceilingHeight;
    out[b] = sec.lightLevel;
  }
}

export function decodeSnapshot(src: Int32Array): RenderSnapshot {
  let o: number = S.PLAYER;
  const x = src[o++]!;
  const y = src[o++]!;
  const z = src[o++]!;
  const viewZ = src[o++]!;
  const angle = src[o++]! >>> 0;
  const pitch = src[o++]!;
  const sector = src[o++]!;
  const health = src[o++]!;
  const armor = src[o++]!;
  const armorType = src[o++]!;
  const ammo: [number, number, number, number] = [src[o++]!, src[o++]!, src[o++]!, src[o++]!];
  const maxAmmo: [number, number, number, number] = [src[o++]!, src[o++]!, src[o++]!, src[o++]!];
  const packedWeapon = src[o++]!;
  const packedFlash = src[o++]!;

  o = S.STATS;
  const stats = {
    kills: src[o++]!,
    items: src[o++]!,
    secrets: src[o++]!,
    totalKills: src[o++]!,
    totalItems: src[o++]!,
    totalSecrets: src[o++]!,
    levelTime: src[o++]!,
  };

  const mobjCount = src[S.MOBJ_COUNT]!;
  const mobjs: MobjSnapshot[] = new Array(mobjCount);
  for (let i = 0; i < mobjCount; i++) {
    let b = S.MOBJS + i * MOBJ_WORDS;
    mobjs[i] = {
      id: src[b++]!,
      type: src[b++]!,
      frame: src[b++]!,
      flags: src[b++]!,
      x: src[b++]!,
      y: src[b++]!,
      z: src[b++]!,
      angle: src[b++]! >>> 0,
      sector: src[b]!,
    };
  }

  const sectorCount = src[S.SECTOR_COUNT]!;
  const sectors: SectorSnapshot[] = new Array(sectorCount);
  for (let i = 0; i < sectorCount; i++) {
    let b = SECTORS_OFFSET + i * SECTOR_WORDS;
    sectors[i] = {
      index: src[b++]!,
      floorHeight: src[b++]!,
      ceilingHeight: src[b++]!,
      lightLevel: src[b]!,
    };
  }

  return {
    tic: src[S.TIC]!,
    player: {
      x,
      y,
      z,
      viewZ,
      angle,
      pitch,
      sector,
      health,
      armor,
      armorType,
      ammo,
      maxAmmo,
      weapon: packedWeapon & 0xff,
      pendingWeapon: (packedWeapon >> 8) & 0xff,
      keys: (packedWeapon >> 16) & 0xff,
      damageCount: packedFlash & 0xff,
      bonusCount: (packedFlash >> 8) & 0xff,
      attackTic: (packedFlash >> 16) & 0xff,
    },
    mobjs,
    sectors,
    stats,
  };
}

// ---------------------------------------------------------------------------
// Interpolation
// ---------------------------------------------------------------------------

/** Linear interpolation of a `fixed_t` pair; returns map units as a float. */
export function lerpFixed(a: number, b: number, t: number): number {
  return fromFixed(a + (b - a) * t);
}

/**
 * Shortest-arc interpolation of two BAM angles.
 *
 * `b - a` is reduced into `[-2^31, 2^31)` by the signed 32-bit wrap, which is
 * exactly the shortest arc: a 359° turn interpolates as -1°, not +359°.
 */
export function lerpBam(a: number, b: number, t: number): number {
  const delta = ((b - a) | 0) >> 0;
  return (a + delta * t) >>> 0;
}

export interface InterpolatedMobj extends Omit<MobjSnapshot, "x" | "y" | "z" | "angle"> {
  /** Map units (not fixed point) — the renderer works in floats. */
  x: number;
  y: number;
  z: number;
  /** BAM. */
  angle: number;
}

export interface InterpolatedView {
  tic: number;
  /** Map units. */
  x: number;
  y: number;
  viewZ: number;
  /** BAM. */
  angle: number;
  pitch: number;
  sector: number;
  mobjs: InterpolatedMobj[];
  /** Sector index → interpolated floor/ceiling in map units, and light level. */
  sectors: Map<number, { floor: number; ceiling: number; light: number }>;
  /** The un-interpolated latest snapshot, for the HUD and the stats. */
  latest: RenderSnapshot;
}

/**
 * Blends two consecutive snapshots at `t ∈ [0, 1]`.
 *
 * Continuous quantities (positions, heights, angles) are interpolated; discrete
 * ones (frame, health, ammo) always take the *newer* value, because blending a
 * sprite frame or an ammo count is meaningless. A mobj absent from `previous`,
 * or flagged `TELEPORTED`, is placed at its `current` position with no blend -
 * the alternative is a visible streak across the map on every teleport and
 * every respawn.
 */
export function interpolate(
  previous: RenderSnapshot,
  current: RenderSnapshot,
  t: number,
): InterpolatedView {
  const clamped = t < 0 ? 0 : t > 1 ? 1 : t;
  const prevMobjs = new Map<number, MobjSnapshot>();
  for (const mo of previous.mobjs) prevMobjs.set(mo.id, mo);

  const mobjs: InterpolatedMobj[] = current.mobjs.map((mo) => {
    const prev = prevMobjs.get(mo.id);
    const blend = prev !== undefined && (mo.flags & MobjRenderFlag.TELEPORTED) === 0;
    return {
      id: mo.id,
      type: mo.type,
      frame: mo.frame,
      flags: mo.flags,
      sector: mo.sector,
      x: blend ? lerpFixed(prev!.x, mo.x, clamped) : fromFixed(mo.x),
      y: blend ? lerpFixed(prev!.y, mo.y, clamped) : fromFixed(mo.y),
      z: blend ? lerpFixed(prev!.z, mo.z, clamped) : fromFixed(mo.z),
      angle: blend ? lerpBam(prev!.angle, mo.angle, clamped) : mo.angle,
    };
  });

  const prevSectors = new Map<number, SectorSnapshot>();
  for (const s of previous.sectors) prevSectors.set(s.index, s);
  const sectors = new Map<number, { floor: number; ceiling: number; light: number }>();
  for (const s of current.sectors) {
    const prev = prevSectors.get(s.index);
    sectors.set(s.index, {
      floor: prev ? lerpFixed(prev.floorHeight, s.floorHeight, clamped) : fromFixed(s.floorHeight),
      ceiling: prev
        ? lerpFixed(prev.ceilingHeight, s.ceilingHeight, clamped)
        : fromFixed(s.ceilingHeight),
      // Light blinks on tic boundaries in vanilla; interpolating it would blur
      // the strobe, so the newest value wins.
      light: s.lightLevel,
    });
  }

  return {
    tic: current.tic,
    x: lerpFixed(previous.player.x, current.player.x, clamped),
    y: lerpFixed(previous.player.y, current.player.y, clamped),
    viewZ: lerpFixed(previous.player.viewZ, current.player.viewZ, clamped),
    angle: lerpBam(previous.player.angle, current.player.angle, clamped),
    pitch: current.player.pitch,
    sector: current.player.sector,
    mobjs,
    sectors,
    latest: current,
  };
}

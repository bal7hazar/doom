import { decodeFelts, u32 } from "./felts.js";
import { MAX_MOBJS, MAX_DYNAMIC_SECTORS, type PspriteSnapshot, type RenderSnapshot } from "./snapshot.js";

/** Original fields are retained beside the explicitly incomplete renderer view. */
export interface CairoFrame {
  snapshot: RenderSnapshot;
  status: number;
  playerstate: number;
  actors: { id: number; state: number; sprite: number; flags: number }[];
}

export function decodeCairoSnapshot(bytes: Uint8Array): CairoFrame {
  const f = decodeFelts(bytes);
  const n = (i: number): number => u32(f[i]);
  const fixed = (i: number): number => {
    const value = f[i];
    if (value === undefined || value < (1n << 31n) || value >= 3n * (1n << 31n)) throw new RangeError("fixed enc outside signed fixed_t");
    return Number(value - (1n << 32n));
  };
  if ((f[0] !== 1n && f[0] !== 2n) || f.length < 36) throw new RangeError("unsupported Cairo snapshot");
  const count = n(3), sectors = n(4), status = n(2);
  if (status > 3 || count > MAX_MOBJS || sectors > MAX_DYNAMIC_SECTORS || f.length !== 36 + count * 11 + sectors * 4 + (f[0] === 2n ? 10 : 0)) {
    throw new RangeError("invalid or oversized Cairo snapshot");
  }
  const snapshot: RenderSnapshot = {
    tic: n(1),
    player: { x: fixed(5), y: fixed(6), z: fixed(7), viewZ: fixed(8), angle: n(9), pitch: 0,
      sector: n(10), health: n(11), armor: n(12), armorType: n(13),
      ammo: [n(14), n(15), n(16), n(17)], maxAmmo: [n(18), n(19), n(20), n(21)],
      weapon: n(22), pendingWeapon: n(23), keys: n(24), damageCount: n(25), bonusCount: n(26),
      // Legacy attackdown is retained; v2 slots below carry the real psprite FSM.
      attackTic: n(27) },
    stats: { kills: n(29), items: n(30), secrets: n(31), totalKills: n(32), totalItems: n(33), totalSecrets: n(34), levelTime: n(35) },
    mobjs: [], sectors: [],
  };
  const actors: CairoFrame["actors"] = [];
  const ids = new Set<number>();
  for (let i = 0, at = 36; i < count; i++, at += 11) {
    const id = n(at), flags = n(at + 5);
    if (ids.has(id) || flags > 31) throw new RangeError("invalid actor identity/flags");
    ids.add(id);
    actors.push({ id, state: n(at + 2), sprite: n(at + 3), flags });
    snapshot.mobjs.push({ id, type: n(at + 1), frame: n(at + 4), flags: flags & 7,
      x: fixed(at + 6), y: fixed(at + 7), z: fixed(at + 8), angle: n(at + 9), sector: n(at + 10) });
  }
  for (let i = 0, at = 36 + count * 11; i < sectors; i++, at += 4) {
    const lightLevel = n(at + 3);
    if (lightLevel > 255) throw new RangeError("invalid sector light");
    snapshot.sectors.push({ index: n(at), floorHeight: fixed(at + 1), ceilingHeight: fixed(at + 2), lightLevel });
  }
  if (f[0] === 2n) {
    const at = 36 + count * 11 + sectors * 4;
    snapshot.player.psprites = [at, at + 5].map(i => ({ state: n(i), sprite: n(i + 1), frame: n(i + 2), x: fixed(i + 3), y: fixed(i + 4) })) as [PspriteSnapshot, PspriteSnapshot];
  }
  return { snapshot, status, playerstate: n(28), actors };
}

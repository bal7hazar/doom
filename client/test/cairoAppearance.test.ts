import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { buildSpriteDefs, decodePatch, Wad, selectSpriteLump } from "@hellproof/wad";
import { buildAssetStore, spriteKey } from "../src/assets/assetStore.js";
import { parseCairoSpriteNames } from "../src/assets/cairoSprites.js";
import { assertAppearanceTic, cairoAppearance, selectCairoSprite, type CairoAppearance } from "../src/render/cairoAppearance.js";
import { decodeCairoSnapshot } from "../src/sim/cairoSnapshot.js";
import { encodeFelts } from "../src/sim/felts.js";
import { hudWeapon, hudWeaponAmmo } from "../src/ui/hud.js";
import type { InterpolatedMobj } from "../src/sim/snapshot.js";
import type { LevelJson } from "../src/map/level.js";

const source = JSON.parse(readFileSync(new URL("../../cairo/doom/doom_things/generated/sprites.json", import.meta.url), "utf8"));
const names = parseCairoSpriteNames(source);
const wadBytes = new Uint8Array(readFileSync(new URL("../public/freedoom1.wad", import.meta.url)));
const level = JSON.parse(readFileSync(new URL("../public/levels/e1m1.json", import.meta.url), "utf8")) as LevelJson;
const table = { names, sourceUrl: "source.json", licenseUrl: "GPL-2.0-only.txt" };
const store = buildAssetStore(wadBytes, level, undefined, table);
const actor = (id = 7, frame = 0): InterpolatedMobj => ({ id, type: 65535, frame, flags: 0, x: 10, y: 0, z: 0, angle: 0, sector: 0 });
const appearance = (prefix: string, frame = 0, flags = 0): CairoAppearance => ({ tic: 5, viewMobjId: 99,
  actors: new Map([[7, { state: 42, sprite: names.indexOf(prefix), frame, flags }]]) });

describe("Cairo appearance and atlas", () => {
  it("loads all 49 source prefixes and every referenced WAD rotation into the atlas", () => {
    const wad = Wad.fromBytes(wadBytes), defs = buildSpriteDefs(wad, new Set(names));
    const lumps = new Set<number>();
    for (const name of names) {
      const def = defs.get(name); expect(def, name).toBeDefined();
      for (const frame of def!.frames) if (frame) for (const lump of frame.lump) if (lump >= 0) {
        lumps.add(lump);
        const rect = store.spriteAtlas.rects.get(spriteKey(lump)); expect(rect, name).toBeDefined();
        const picture = decodePatch(wad.lumpData(wad.lumps[lump]!));
        expect([rect!.width, rect!.height, rect!.leftOffset, rect!.topOffset]).toEqual([picture.width, picture.height, picture.leftOffset, picture.topOffset]);
      }
    }
    expect(lumps.size).toBe(356); expect(store.spriteAtlas.overflow).toEqual([]); expect(store.stats.missing).toEqual([]);
    expect(store.spriteAtlas.data.byteLength).toBe(store.spriteAtlas.width * store.spriteAtlas.height * 2);
    console.log(JSON.stringify({ cairoAtlas: { prefixes: names.length, lumps: lumps.size, width: store.spriteAtlas.width,
      height: store.spriteAtlas.height, bytes: store.spriteAtlas.data.byteLength } }));
  });
  it("draws every formerly missing effect family without a doomednum, and BAR1 changes to BEXP", () => {
    for (const prefix of ["BAL1", "BEXP", "BLUD", "CHGF", "PISF", "PUFF", "SHTF"]) {
      expect(selectCairoSprite(store, appearance(prefix), actor(), 0).prefix).toBe(prefix);
    }
    const mo = { ...actor(), type: 2035 };
    const barrel = selectCairoSprite(store, appearance("BAR1"), mo, 0);
    const boom = selectCairoSprite(store, appearance("BEXP", 0, 1), mo, 0);
    expect(barrel.prefix).toBe("BAR1"); expect(boom.prefix).toBe("BEXP"); expect(boom.rect).not.toEqual(barrel.rect);
  });
  it("uses exact frames and flags, including corpse frames and non-fullbright states", () => {
    const last = store.spriteDefs.get("POSS")!.frames.reduce((last, frame, index) => frame ? index : last, -1);
    const corpse = selectCairoSprite(store, appearance("POSS", last, 8), actor(7, last), 0);
    expect(corpse.fullbright).toBe(false); expect(corpse.shadow).toBe(false);
    const dim = selectCairoSprite(store, appearance("SOUL", 0, 0), actor(), 0);
    expect(dim.fullbright).toBe(false); // Spawn metadata says fullbright, Cairo is authoritative.
    const bright = selectCairoSprite(store, appearance("BAL1", 0, 1 | 2 | 16), actor(), 0);
    expect(bright.fullbright).toBe(true); expect(bright.shadow).toBe(true);
    expect(() => selectCairoSprite(store, appearance("POSS", 999), actor(7, 999), 0)).toThrow("Missing Cairo sprite frame");
    expect(() => selectCairoSprite(store, appearance("POSS"), actor(8), 0)).toThrow("Missing or stale");
  });
  it("rejects missing sprite ids, rotations and atlas resources explicitly", () => {
    const unknown = appearance("PLAY"); unknown.actors = new Map([[7, { state: 1, sprite: 49, frame: 0, flags: 0 }]]);
    expect(() => selectCairoSprite(store, unknown, actor(), 0)).toThrow("Unknown Cairo sprite");
    const defs = new Map(store.spriteDefs), def = defs.get("PLAY")!;
    const frames = [...def.frames], original = frames[0]!;
    frames[0] = { ...original, lump: original.lump.map(() => -1) };
    defs.set("PLAY", { ...def, frames });
    expect(() => selectCairoSprite({ ...store, spriteDefs: defs }, appearance("PLAY"), actor(), 0)).toThrow("Missing Cairo sprite rotation");
    expect(() => selectCairoSprite({ ...store, spriteAtlas: { ...store.spriteAtlas, rects: new Map() } }, appearance("PLAY"), actor(), 0)).toThrow("Missing Cairo sprite atlas lump");
  });
  it("selects all actual rotations and mirrored lumps for the exact Cairo frame", () => {
    const frame = store.spriteDefs.get("TROO")!.frames[0]!;
    let mirrored = false;
    for (let angle = 0; angle < 8; angle++) {
      const bam = angle * 0x20000000, expected = selectSpriteLump(frame, bam, 0)!;
      const pick = selectCairoSprite(store, appearance("TROO"), actor(), bam);
      expect(pick.rect).toBe(store.spriteAtlas.rects.get(spriteKey(expected.lump)));
      expect(pick.flip).toBe(expected.flip); mirrored ||= pick.flip;
    }
    expect(mirrored).toBe(true);
  });
  it("retains actor id gaps and raw CORPSE without aliasing ring TELEPORTED, and rejects a stale tic", () => {
    const f: (number | bigint)[] = Array(36).fill(0); f[0] = 1; f[1] = 5; f[3] = 2;
    for (let i = 5; i <= 8; i++) f[i] = 1n << 32n;
    for (const [id, flags] of [[99, 0], [7, 8]]) f.push(id!, 65535, 42, names.indexOf("PLAY"), 0, flags!, 1n << 32n, 1n << 32n, 1n << 32n, 0, 0);
    const decoded = decodeCairoSnapshot(encodeFelts(f)), a = cairoAppearance(decoded, 99);
    expect([...a.actors.keys()]).toEqual([99, 7]); expect(a.viewMobjId).toBe(99);
    expect(a.actors.get(7)!.flags).toBe(8); expect(decoded.snapshot.mobjs[1]!.flags).toBe(0);
    expect(() => assertAppearanceTic(a, 5)).not.toThrow(); expect(() => assertAppearanceTic(a, 6)).toThrow("differs");
  });
  it("rejects malformed name tables instead of silently changing the numeric mapping", () => {
    expect(() => parseCairoSpriteNames({ sprites: ["TROO"] })).toThrow();
    expect(() => parseCairoSpriteNames({ sprites: Array(49).fill("TROO") })).toThrow();
    expect(names[0]).toBe("TROO"); expect(names[8]).toBe("SAWG");
  });
});

describe("compact Cairo HUD weapons preserve the demo", () => {
  it("uses chainsaw/no ammo for compact4 and rocket/rockets for demo4", () => {
    expect(hudWeapon(4, "cairo")).toBe(7); expect(hudWeaponAmmo(4, "cairo")).toBe(-1);
    expect(hudWeapon(4, "demo")).toBe(4); expect(hudWeaponAmmo(4, "demo")).toBe(3);
    expect(hudWeapon(5, "cairo")).toBe(-1); expect(hudWeaponAmmo(5, "cairo")).toBe(-1);
    expect([0, 1, 2, 3, 4].map(w => hudWeaponAmmo(w, "cairo"))).toEqual([-1, 0, 1, 0, -1]);
  });
});

import { readFileSync } from "node:fs";
import { expect, test } from "@playwright/test";

const source = JSON.parse(readFileSync(new URL("../../cairo/doom/doom_things/generated/sprites.json", import.meta.url), "utf8"));
const prefixes = ["BAL1", "BEXP", "BLUD", "CHGF", "PISF", "PUFF", "SHTF"];
const states = prefixes.map(prefix => source.states.findIndex((state: { sprite: string }) => state.sprite === prefix));
const playState = source.states.findIndex((state: { sprite: string }) => state.sprite === "PLAY");

test("Cairo projects effect states into actual GPU quads and excludes only the nonzero camera actor", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(String(error)));
  page.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  await page.goto("/?sim=cairo");
  await page.waitForFunction(() => Boolean((window as any).hellproof?.cairo?.latest));
  const result = await page.evaluate(async ({ states, playState, prefixes }) => {
    const app = (window as any).hellproof;
    // A canonical schema-2 fixture, validated/projected by the real Cairo VM.
    // It exercises rendering states, not a claim that gameplay produced them.
    const bytes: Uint8Array = await app.cairo.checkpoint();
    const data = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const fields: bigint[] = [];
    for (let offset = 0; offset < bytes.length; offset += 32) {
      let value = 0n;
      for (let lane = 3; lane >= 0; lane--) value = (value << 64n) | data.getBigUint64(offset + lane * 8, true);
      fields.push(value);
    }
    if (fields[1] !== 2n || Number(fields[46]) < 10) throw new Error("Unsupported state fixture layout");
    fields[10] = 1n; // player.mo is actor 1; actor 0 remains another PLAY.
    fields[47 + 27 + 12] = BigInt(playState);
    const kinds = [7, 6, 9, 9, 9, 8, 9]; // TROOPSHOT, BARREL, BLOOD, PUFF; original Cairo kind ids.
    for (let index = 0; index < states.length; index++) {
      fields[47 + (index + 2) * 27] = BigInt(kinds[index]!);
      fields[47 + (index + 2) * 27 + 12] = BigInt(states[index]!);
    }
    for (let index = 0; index < fields.length; index++) for (let lane = 0; lane < 4; lane++) {
      data.setBigUint64(index * 32 + lane * 8, BigInt.asUintN(64, fields[index]! >> BigInt(lane * 64)), true);
    }
    await app.cairo.restart(bytes);
    await app.captureFrame();
    const renderer = app.renderer;
    // Read actual GPU-uploaded vertices; no production test hook or extra per-frame allocation.
    const gl: WebGL2RenderingContext = renderer.gl;
    const vertices = new Float32Array(renderer.stats.sprites * 6 * 11);
    gl.bindBuffer(gl.ARRAY_BUFFER, renderer.spriteBuffer);
    gl.getBufferSubData(gl.ARRAY_BUFFER, 0, vertices);
    const rectKey = (rect: { x: number; y: number; width: number; height: number }) => [rect.x, rect.y, rect.width, rect.height].join(",");
    const family = new Map<string, string>();
    for (const [prefix, def] of app.store.spriteDefs) for (const frame of def.frames) if (frame) {
      for (const lump of frame.lump) if (lump >= 0) family.set(rectKey(app.store.spriteAtlas.rects.get(`S:${lump}`)), prefix);
    }
    const drawn: { prefix: string | undefined; flags: number }[] = [];
    for (let index = 0; index < vertices.length; index += 66) drawn.push({
      prefix: family.get(Array.from(vertices.slice(index + 5, index + 9)).join(",")), flags: vertices[index + 10]!,
    });
    const frame = app.cairo.latest;
    return { camera: app.cairo.viewMobjId, actors: frame.snapshot.mobjs.length, sprites: renderer.stats.sprites,
      expectedPlayCount: frame.actors.filter((actor: any) => actor.id !== 1 && app.store.cairoSprites.names[actor.sprite] === "PLAY").length,
      first: drawn[0], playCount: drawn.filter(value => value.prefix === "PLAY").length,
      effects: drawn.slice(1, 1 + prefixes.length),
      effectTypes: frame.snapshot.mobjs.slice(2, 2 + prefixes.length).map((actor: any) => actor.type),
      expectedFlags: frame.actors.slice(2, 2 + prefixes.length).map((actor: any) => actor.flags & 3),
      license: await (await fetch(app.store.cairoSprites.licenseUrl)).text(), missing: app.store.stats.missing,
      journal: app.cairo.journal.length, tic: frame.snapshot.tic, glError: gl.getError() };
  }, { states, playState, prefixes });
  expect(result.camera).toBe(1);
  expect(result.sprites).toBe(result.actors - 1);
  expect(result.first?.prefix).toBe("PLAY");
  expect(result.playCount).toBe(result.expectedPlayCount);
  expect(result.playCount).toBeGreaterThan(0);
  expect(result.effects.map(value => value.prefix)).toEqual(prefixes);
  expect(result.effects.map(value => value.flags)).toEqual(result.expectedFlags);
  expect(result.effectTypes).toEqual([65535, 2035, 65535, 65535, 65535, 65535, 65535]);
  expect(result.license).toContain("GNU GENERAL PUBLIC LICENSE");
  expect(result.missing).toEqual([]);
  expect(result.journal).toBe(0); expect(result.tic).toBe(0); expect(result.glError).toBe(0);
  expect(errors).toEqual([]);
});

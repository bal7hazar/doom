import { expect, test } from "@playwright/test";
import { guardWorkers } from "./proofWorkerGuard.js";

test("real Cairo psprites animate held fire, flash, pause and restore without extra tics", async ({ page }, testInfo) => {
  await guardWorkers(page);
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(String(error)));
  await page.goto("/?sim=cairo");
  await page.waitForFunction(() => Boolean((window as any).hellproof?.cairo?.latest));
  const initial = await page.evaluate(() => (window as any).hellproof.cairo.latest.snapshot.player.psprites);
  expect(initial).toHaveLength(2);
  await page.evaluate(async () => {
    const app = (window as any).hellproof;
    await app.cairo.resume();
    for (let i = 0; i < 25; i++) await app.cairo.advance(0x808080);
    await app.captureFrame();
  });
  await page.evaluate(() => { (window as any).hellproof.play.element.style.display = "none"; });
  const readyPixels = await page.evaluate(() => {
    const canvas = document.getElementById("overlay") as HTMLCanvasElement;
    return Array.from(canvas.getContext("2d")!.getImageData(250, 190, 140, 125).data);
  });
  expect(readyPixels.some((value, i) => i % 4 === 3 && value > 0)).toBe(true);
  await page.screenshot({ path: testInfo.outputPath("weapon-ready.png") });
  const result = await page.evaluate(async () => {
    const app = (window as any).hellproof, frames: any[] = [];
    const initialAmmo = app.cairo.latest.snapshot.player.ammo[0];
    let saved: Uint8Array | undefined, savedSlots: any;
    for (let i = 0; i < 40; i++) {
      await app.cairo.advance(0x1808080);
      const p = app.cairo.latest.snapshot.player;
      frames.push({ tic: app.cairo.latest.snapshot.tic, ammo: p.ammo[0], slots: p.psprites });
      if (!saved && p.psprites[1].state) {
        savedSlots = structuredClone(p.psprites); saved = await app.cairo.checkpoint();
      }
    }
    await app.cairo.pause();
    const pauseSlots = JSON.stringify(app.cairo.latest.snapshot.player.psprites), tic = app.cairo.latest.snapshot.tic;
    for (let i = 0; i < 3; i++) await app.captureFrame();
    const stable = JSON.stringify(app.cairo.latest.snapshot.player.psprites) === pauseSlots && app.cairo.latest.snapshot.tic === tic;
    if (!saved) throw new Error("No Cairo muzzle flash observed");
    await app.cairo.restart(saved); await app.captureFrame();
    return { initialAmmo, frames, stable, restored: app.cairo.latest.snapshot.player.psprites, savedSlots,
      ring: app.ring.readLatest().player.psprites, proves: (window as any).proofWorkerAudit.proves };
  });
  expect(result.frames.at(-1).ammo).toBeLessThan(result.initialAmmo);
  expect(new Set(result.frames.map(f => f.slots[0].frame)).size).toBeGreaterThan(1);
  expect(result.frames.some(f => f.slots[1].state !== 0)).toBe(true);
  expect(result.frames.some(f => f.slots[1].state === 0)).toBe(true);
  expect(result.stable).toBe(true);
  expect(result.restored).toEqual(result.savedSlots); expect(result.ring).toEqual(result.savedSlots);
  expect(result.proves).toBe(0); expect(errors).toEqual([]);
  const flashPixels = await page.evaluate(() => {
    const canvas = document.getElementById("overlay") as HTMLCanvasElement;
    return Array.from(canvas.getContext("2d")!.getImageData(250, 190, 140, 125).data);
  });
  expect(flashPixels).not.toEqual(readyPixels);
  await page.screenshot({ path: testInfo.outputPath("weapon-flash-restored.png") });
});

test("empty pistol has no flash and weapon change lowers then raises the Cairo slots", async ({ page }) => {
  await page.goto("/?sim=cairo");
  await page.waitForFunction(() => Boolean((window as any).hellproof?.cairo?.latest));
  const result = await page.evaluate(async () => {
    const a = (window as any).hellproof;
    await a.cairo.resume(); for (let i = 0; i < 25; i++) await a.cairo.advance(0x808080);
    const initialY = a.cairo.latest.snapshot.player.psprites[0].y;
    await a.cairo.advance(0x4808080); // BT_CHANGE to fist, which is owned at genesis.
    const switching = [];
    for (let i = 0; i < 45; i++) {
      await a.cairo.advance(0x808080); const p = a.cairo.latest.snapshot.player;
      switching.push({ weapon: p.weapon, y: p.psprites[0].y, state: p.psprites[0].state });
    }
    await a.cairo.restart(); await a.cairo.resume();
    for (let i = 0; i < 25; i++) await a.cairo.advance(0x808080);
    const bytes: Uint8Array = await a.cairo.checkpoint();
    // Canonical schema2 test state, Cairo validates the zero-ammo fixture.
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    for (let lane = 0; lane < 4; lane++) view.setBigUint64(15 * 32 + lane * 8, 0n, true);
    await a.cairo.restart(bytes); await a.cairo.resume();
    const empty = [];
    for (let i = 0; i < 40; i++) {
      await a.cairo.advance(0x1808080); const p = a.cairo.latest.snapshot.player;
      empty.push({ ammo: p.ammo[0], flash: p.psprites[1].state, weapon: p.weapon });
    }
    return { initialY, switching, empty };
  });
  expect(result.switching.some(s => s.y > result.initialY)).toBe(true);
  expect(result.switching.at(-1)?.weapon).toBe(0);
  expect(result.switching.at(-1)?.y).toBe(result.initialY);
  expect(result.empty.every(s => s.ammo === 0 && s.flash === 0)).toBe(true);
});

test("audited v1 save migration preserves state and allows subsequent v2 restores", async ({ page }) => {
  await guardWorkers(page);
  await page.goto("/?sim=cairo");
  await page.waitForFunction(() => Boolean((window as any).hellproof?.cairo?.latest));
  const result = await page.evaluate(async () => {
    const a = (window as any).hellproof;
    await a.cairo.resume(); for (let i = 0; i < 30; i++) await a.cairo.advance(0x1808080);
    await a.cairo.pause(); await a.cairo.checkpoint();
    const current = a.cairo.journal.export(), old = structuredClone(current);
    old.identity.snapshotSchema = 1;
    old.identity.hashes.session = "dcb7193cbb8d77cdb08c66517e1c5e68453b15687808e40ea2abb5acbc4a0cac";
    const unknown = structuredClone(old); unknown.identity.hashes.session = "a".repeat(64);
    let rejected = false;
    try { await a.play.restore(unknown); } catch { rejected = true; }
    const before = JSON.stringify(a.cairo.journal.export());
    await a.play.restore(old);
    const migrated = a.cairo.journal.export(), slots = a.cairo.latest.snapshot.player.psprites;
    await a.play.restore(current);
    const restored = a.cairo.journal.export();
    return { rejected, before, current: JSON.stringify(current), restored: JSON.stringify(restored),
      migratedInputs: migrated.inputs, inputs: current.inputs, migratedCheckpoint: migrated.checkpoint,
      checkpoint: current.checkpoint, slots, finalSlots: a.cairo.latest.snapshot.player.psprites,
      loadedSchema: a.cairo.loadedIdentity.snapshotSchema };
  });
  expect(result.rejected).toBe(true); expect(result.before).toBe(result.current);
  expect(result.restored).toBe(result.current);
  expect(result.migratedInputs).toEqual(result.inputs); expect(result.migratedCheckpoint).toEqual(result.checkpoint);
  expect(result.slots).toEqual(result.finalSlots); expect(result.loadedSchema).toBe(2);
});

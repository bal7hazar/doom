import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { expect, test } from "@playwright/test";

test.use({ headless: process.env.HELLPROOF_POINTER_LOCK !== "1" });
test.beforeEach(async ({ page }) => { page.setDefaultTimeout(15_000); });
test.setTimeout(60_000);

test.skip(!existsSync(resolve("public/sim/manifest.json")) || !existsSync(resolve("public/freedoom1.wad")), "stage simulation and WAD first");

test("real keyboard commands, explicit save and reload preserve the Cairo run", async ({ page }) => {
  const errors: string[] = [], proofRequests: string[] = [];
  page.on("pageerror", error => errors.push(String(error)));
  page.on("request", request => { if (request.url().includes("/prover/") || request.url().includes("/programs/")) proofRequests.push(request.url()); });
  await page.goto("/");
  await expect(page.getByRole("button", { name: "Start", exact: true })).toBeEnabled();
  await page.keyboard.press("w"); await page.waitForTimeout(100);
  const initial = await page.evaluate(() => {
    const c = (window as any).hellproof.cairo;
    return { tic: c.latest.snapshot.tic, length: c.journal.length, player: c.latest.snapshot.player };
  });
  expect(initial.tic).toBe(0); expect(initial.length).toBe(0);
  await page.getByRole("button", { name: "Start", exact: true }).click();
  await page.keyboard.down("w");
  await page.waitForFunction(position => { const p = (window as any).hellproof.cairo.latest.snapshot.player; return p.x !== position.x || p.y !== position.y; }, initial.player);
  await page.keyboard.up("w");
  const moved = await page.evaluate(() => (window as any).hellproof.cairo.latest.snapshot.player);
  expect([moved.x, moved.y]).not.toEqual([initial.player.x, initial.player.y]);
  const angle = moved.angle;
  await page.keyboard.down("ArrowRight");
  await page.waitForFunction(before => (window as any).hellproof.cairo.latest.snapshot.player.angle !== before, angle);
  await page.keyboard.up("ArrowRight");
  await page.keyboard.down("Control");
  await page.waitForFunction(ammo => (window as any).hellproof.cairo.latest.snapshot.player.ammo[0] < ammo, initial.player.ammo[0]);
  await page.keyboard.up("Control");
  await page.keyboard.down("e");
  const useTic = await page.evaluate(() => (window as any).hellproof.cairo.latest.snapshot.tic);
  await page.waitForFunction(tic => (window as any).hellproof.cairo.latest.snapshot.tic >= tic + 3, useTic);
  await page.keyboard.up("e"); await page.keyboard.press("1");
  await page.waitForFunction(() => (window as any).hellproof.cairo.latest.snapshot.player.weapon === 0);
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => !(window as any).hellproof.cairo.busy && !(window as any).hellproof.scheduler.isRunning);
  const pausedTic = await page.evaluate(() => (window as any).hellproof.cairo.latest.snapshot.tic);
  await page.keyboard.down("w"); await page.waitForTimeout(100); await page.keyboard.up("w");
  expect(await page.evaluate(() => (window as any).hellproof.cairo.latest.snapshot.tic)).toBe(pausedTic);
  expect(proofRequests).toEqual([]);
  await page.keyboard.press("F4");
  await expect(page.getByRole("region", { name: "Real game proof" })).toBeVisible();
  // Close proof controls; resuming the game stays an explicit action.
  await page.keyboard.press("F4");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByRole("status")).toContainText("Saved on this device");
  const before = await page.evaluate(() => {
    const c = (window as any).hellproof.cairo;
    return { journal: c.journal.export(), frame: Array.from(c.lastRawFrame) };
  });
  const words: number[] = [];
  for (const felt of before.journal.inputs) {
    let packed = BigInt(felt);
    for (let i = 0; i < 7 && words.length < before.journal.ticCount; i++, packed >>= 32n) words.push(Number(packed & 0xffffffffn));
  }
  expect(words.some(w => ((w >>> 24) & 1) !== 0)).toBe(true);
  expect(words.some(w => ((w >>> 24) & 2) !== 0)).toBe(true);
  expect(words.some(w => ((w >>> 24) & 4) !== 0)).toBe(true);
  await page.reload();
  await page.getByRole("button", { name: "Load save", exact: true }).click();
  await expect(page.getByRole("status")).toContainText("Saved game restored in pause");
  const after = await page.evaluate(() => {
    const c = (window as any).hellproof.cairo;
    return { journal: c.journal.export(), frame: Array.from(c.lastRawFrame), paused: c.paused, running: (window as any).hellproof.scheduler.isRunning };
  });
  expect(after.journal).toEqual(before.journal); expect(after.frame).toEqual(before.frame);
  expect(after.paused).toBe(true); expect(after.running).toBe(false);
  await page.getByRole("button", { name: "Resume", exact: true }).click();
  await page.waitForFunction(tic => (window as any).hellproof.cairo.latest.snapshot.tic > tic, pausedTic);
  await page.keyboard.press("Escape");
  expect(errors).toEqual([]); expect(proofRequests.some(url => url.includes("stub"))).toBe(false);
});

test("download/import and rejected identity keep the existing game usable", async ({ page }, testInfo) => {
  await page.goto("/");
  await expect(page.getByRole("button", { name: "Start", exact: true })).toBeEnabled();
  const original = await page.evaluate(() => (window as any).hellproof.cairo.journal.export());
  const downloadPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export", exact: true }).click();
  const download = await downloadPromise, path = testInfo.outputPath("game.json");
  await download.saveAs(path);
  await page.getByLabel("Import saved game").setInputFiles(path);
  await expect(page.getByRole("status")).toContainText("File restored in pause");
  expect(await page.evaluate(() => (window as any).hellproof.cairo.journal.export())).toEqual(original);
  const bad = structuredClone(original); bad.identity.hashes.session = "f".repeat(64);
  await page.getByLabel("Import saved game").setInputFiles({ name: "bad.json", mimeType: "application/json", buffer: Buffer.from(JSON.stringify(bad)) });
  await expect(page.getByRole("status")).toContainText("different game version");
  expect(await page.evaluate(() => (window as any).hellproof.cairo.journal.export())).toEqual(original);
  const malformedState = structuredClone(original);
  malformedState.checkpoint[3] = "0"; // Structurally valid envelope, wrong Cairo map identity.
  await page.getByLabel("Import saved game").setInputFiles({ name: "wrong-map.json", mimeType: "application/json", buffer: Buffer.from(JSON.stringify(malformedState)) });
  await expect(page.getByRole("status")).toContainText("Import rejected; current run recovered");
  expect(await page.evaluate(() => (window as any).hellproof.cairo.journal.export())).toEqual(original);
  await page.getByRole("button", { name: "Start", exact: true }).click();
  await page.waitForFunction(() => (window as any).hellproof.cairo.journal.length > 0);
  await page.keyboard.press("Escape");
});


test("native pointer lock turns and fires in Cairo", async ({ page }) => {
  test.skip(process.env.HELLPROOF_POINTER_LOCK !== "1", "Native pointer lock requires a headed browser here; run HELLPROOF_POINTER_LOCK=1. Keyboard fallback is always tested.");
  await page.goto("/");
  await page.getByRole("button", { name: "Start", exact: true }).click();
  await page.bringToFront();
  await page.mouse.click(620, 300);
  await page.waitForFunction(() => document.pointerLockElement === document.getElementById("view"));
  const before = await page.evaluate(() => (window as any).hellproof.cairo.latest.snapshot.player);
  await page.mouse.move(200, 200); await page.mouse.move(260, 200, { steps: 3 });
  await page.waitForFunction(angle => (window as any).hellproof.cairo.latest.snapshot.player.angle !== angle, before.angle);
  await page.mouse.down();
  await page.waitForFunction(ammo => (window as any).hellproof.cairo.latest.snapshot.player.ammo[0] < ammo, before.ammo[0]);
  await page.mouse.up(); await page.keyboard.press("Escape");
  await page.waitForFunction(() => !document.pointerLockElement && !(window as any).hellproof.cairo.busy);
  const tic = await page.evaluate(() => (window as any).hellproof.cairo.latest.snapshot.tic);
  await page.mouse.move(100, 100); await page.waitForTimeout(100);
  expect(await page.evaluate(() => (window as any).hellproof.cairo.latest.snapshot.tic)).toBe(tic);
});

import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { expect, test } from "@playwright/test";

test.skip(!existsSync(resolve("public/sim/manifest.json")) || !existsSync(resolve("public/freedoom1.wad")),
  "stage the pinned simulation and WAD artifacts first");

test("production client renders Cairo frames and never opens the stub proof path", async ({ page }) => {
  const proofRequests: string[] = [], errors: string[] = [];
  page.on("request", request => { if (request.url().includes("/prover/")) proofRequests.push(request.url()); });
  page.on("pageerror", error => errors.push(String(error)));
  await page.goto("/?sim=cairo");
  await page.waitForFunction(() => Boolean((window as any).hellproof?.cairo?.journal?.length));
  await page.evaluate(() => (window as any).hellproof.scheduler.stop());
  await page.waitForFunction(() => !(window as any).hellproof.cairo.busy);
  const before = await page.evaluate(async () => {
    const app = (window as any).hellproof;
    const checkpoint = await app.cairo.checkpoint();
    return { tic: app.cairo.latest.snapshot.tic, journal: app.cairo.journal.length,
      x: app.cairo.latest.snapshot.player.x, ringX: app.ring.readLatest().player.x,
      stateBytes: checkpoint.byteLength, shared: app.ring.shared, transport: app.profile.snapshotTransport,
      frame: await app.captureFrame() };
  });
  expect(before.journal).toBe(before.tic);
  expect(before.tic).toBeGreaterThan(0);
  expect(before.stateBytes).toBeGreaterThan(150_000);
  expect(before.ringX).toBe(before.x);
  expect(before.shared).toBe(false);
  expect(before.transport).toBe("copied");
  expect(before.frame.distinct).toBeGreaterThan(20);
  await page.keyboard.press("F4");
  await page.waitForTimeout(100);
  expect(await page.evaluate(() => (window as any).hellproof.cairo.latest.snapshot.tic)).toBe(before.tic);
  expect(proofRequests).toEqual([]);
  await page.evaluate(async () => { await (window as any).hellproof.cairo.restart(); });
  const reset = await page.evaluate(async () => {
    const app = (window as any).hellproof;
    return { tic: app.ring.readLatest().tic, pair: app.ring.readPair(), journal: app.cairo.journal.length,
      frame: await app.captureFrame() };
  });
  expect(reset.tic).toBe(0); expect(reset.pair).toBeNull(); expect(reset.journal).toBe(0);
  expect(reset.frame.distinct).toBeGreaterThan(20);
  expect(errors).toEqual([]);
});

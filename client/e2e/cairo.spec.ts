import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { guardWorkers } from "./proofWorkerGuard.js";
import { expect, test } from "@playwright/test";

test.skip(!existsSync(resolve("public/sim/manifest.json")) || !existsSync(resolve("public/freedoom1.wad")),
  "stage the pinned simulation and WAD artifacts first");

test("production client renders Cairo frames and never opens the stub proof path", async ({ page }) => {
  await guardWorkers(page);
  const proofRequests: string[] = [], errors: string[] = [], writes: string[] = [];
  page.on("request", request => { if (!["GET", "HEAD"].includes(request.method())) writes.push(request.url()); });
  page.on("request", request => { if (request.url().includes("/prover/") || request.url().includes("/programs/")) proofRequests.push(request.url()); });
  page.on("pageerror", error => errors.push(String(error)));
  await page.goto("/?sim=cairo");
  await page.getByRole("button", { name: "Start", exact: true }).click();
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
  expect(proofRequests).toEqual([]);
  await page.keyboard.press("F4");
  await expect(page.getByRole("region", { name: "Real game proof" })).toBeVisible();
  await page.waitForTimeout(100);
  expect(await page.evaluate(() => (window as any).hellproof.cairo.latest.snapshot.tic)).toBe(before.tic);
  expect(proofRequests.some(url => url.includes("stub"))).toBe(false);
  await page.evaluate(async () => { await (window as any).hellproof.cairo.restart(); });
  const reset = await page.evaluate(async () => {
    const app = (window as any).hellproof;
    return { tic: app.ring.readLatest().tic, pair: app.ring.readPair(), journal: app.cairo.journal.length,
      frame: await app.captureFrame() };
  });
  expect(reset.tic).toBe(0); expect(reset.pair).toBeNull(); expect(reset.journal).toBe(0);
  expect(reset.frame.distinct).toBeGreaterThan(20);
  expect(errors).toEqual([]); expect(writes).toEqual([]);
  expect(await page.evaluate(() => (window as any).proofWorkerAudit.proves)).toBe(0);
});

test("persisted page lifecycle preserves the real Worker journal and pause choice (synthetic events)", async ({ page }) => {
  await page.goto("/?sim=cairo");
  await page.getByRole("button", { name: "Start", exact: true }).click();
  await page.waitForFunction(() => Boolean((window as any).hellproof?.cairo?.journal?.length));
  await page.evaluate(() => {
    const app = (window as any).hellproof;
    (window as any).savedJournal = app.cairo.journal;
    window.dispatchEvent(new PageTransitionEvent("pagehide", { persisted: true }));
  });
  await page.waitForFunction(() => !(window as any).hellproof.cairo.busy);
  const tic = await page.evaluate(() => (window as any).hellproof.cairo.latest.snapshot.tic);
  await page.waitForTimeout(100);
  expect(await page.evaluate(() => (window as any).hellproof.cairo.latest.snapshot.tic)).toBe(tic);
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true })));
  await page.waitForFunction(before => (window as any).hellproof.cairo.latest.snapshot.tic > before, tic);
  expect(await page.evaluate(() => (window as any).hellproof.cairo.journal === (window as any).savedJournal)).toBe(true);
  await page.evaluate(() => (window as any).hellproof.scheduler.stop());
  await page.waitForFunction(() => !(window as any).hellproof.cairo.busy);
  const paused = await page.evaluate(() => {
    const app = (window as any).hellproof;
    window.dispatchEvent(new PageTransitionEvent("pagehide", { persisted: true }));
    window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true }));
    return app.cairo.latest.snapshot.tic;
  });
  await page.waitForTimeout(100);
  expect(await page.evaluate(() => ({ running: (window as any).hellproof.scheduler.isRunning,
    tic: (window as any).hellproof.cairo.latest.snapshot.tic }))).toEqual({ running: false, tic: paused });
  await page.evaluate(async () => { await (window as any).hellproof.cairo.checkpoint(); });
});

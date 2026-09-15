// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0
import { existsSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { devices, expect, test, type Page } from "@playwright/test";

/**
 * Touch-control smoke test on an emulated phone (`playwright.config.ts`'s
 * `mobile` project: Pixel 7 in landscape, touch emulation, SwiftShader). It
 * drives the renderer demo (`?sim=demo`), which needs no Cairo artifacts: the
 * on-screen controls must appear, a look-zone drag must turn the camera through
 * the same quantized ticcmd path as the keyboard, two fingers must coexist, and
 * the page must raise no error. Portrait shows the orientation notice; a desktop
 * viewport gets no controls at all.
 *
 * Touches are injected through CDP (`Input.dispatchTouchEvent`), the only way
 * to hold several touch points at once; Playwright's own `touchscreen` can only tap.
 */

const HERE = dirname(fileURLToPath(import.meta.url));
const ARTIFACTS = join(HERE, "artifacts");
const ASSETS_PRESENT =
  existsSync(resolve(HERE, "..", "public", "freedoom1.wad")) &&
  existsSync(resolve(HERE, "..", "public", "levels", "e1m1.json"));

test.skip(!ASSETS_PRESENT, "client/public/freedoom1.wad and levels/e1m1.json are missing - run `npm run assets`");
test.beforeAll(async () => { await mkdir(ARTIFACTS, { recursive: true }); });

async function boot(page: Page, url = "/?sim=demo"): Promise<string[]> {
  const errors: string[] = [];
  page.on("console", msg => { if (msg.type() === "error") errors.push(msg.text()); });
  page.on("pageerror", err => errors.push(String(err)));
  await page.goto(url);
  await expect(page.locator("#loading")).toBeHidden({ timeout: 120_000 });
  await page.waitForFunction(() => (window as never as { hellproof?: unknown }).hellproof !== undefined);
  return errors;
}

interface Point { x: number; y: number; id: number }
async function touches(page: Page) {
  const cdp = await page.context().newCDPSession(page);
  const send = (type: "touchStart" | "touchMove" | "touchEnd", points: Point[]) =>
    cdp.send("Input.dispatchTouchEvent", { type, touchPoints: points.map(p => ({ x: p.x, y: p.y, id: p.id, radiusX: 8, radiusY: 8 })) });
  return {
    /** Puts every point down (one event, so they are simultaneous). */
    down: (points: Point[]) => send("touchStart", points),
    move: (points: Point[]) => send("touchMove", points),
    /** Lifts every point. */
    up: () => send("touchEnd", []),
    detach: () => cdp.detach(),
  };
}

test("landscape phone: controls appear, a drag turns the view, two fingers coexist, no page error", async ({ page }, testInfo) => {
  const errors = await boot(page);
  const size = page.viewportSize()!;
  expect(size.width, "landscape viewport").toBeGreaterThan(size.height);

  // The device is detected as a touch screen and the demo starts playing at once.
  await expect(page.locator("body")).toHaveClass(/touch/);
  const controls = page.locator(".touch-controls");
  await expect(controls).toHaveClass(/playing/);
  await expect(controls).toBeVisible();
  for (const name of ["stick", "look", "fire", "use", "run", "weapon", "pause", "map"]) {
    await expect(controls.locator(`[data-touch="${name}"]`), name).toBeVisible();
  }
  await expect(page.locator("#orientation")).toBeHidden();
  const detected = await page.evaluate(() => ({
    coarse: matchMedia("(pointer: coarse)").matches,
    touchPoints: navigator.maxTouchPoints,
    demoTurn: (window as never as { hellproof: { demoTurn(): number } }).hellproof.demoTurn(),
  }));
  expect(detected.touchPoints).toBeGreaterThan(0);
  expect(detected.demoTurn).toBe(0);

  const screenshot = join(ARTIFACTS, "mobile-controls.png");
  await page.screenshot({ path: screenshot });
  await testInfo.attach("mobile-controls", { path: screenshot, contentType: "image/png" });

  // One finger on the stick (left half), one dragging right in the look zone
  // (right half, clear of the buttons), one on Fire — all at the same time.
  const t = await touches(page);
  const stick: Point = { x: Math.round(size.width * 0.2), y: Math.round(size.height * 0.55), id: 1 };
  const look: Point = { x: Math.round(size.width * 0.6), y: Math.round(size.height * 0.4), id: 2 };
  const fireBox = (await controls.locator('[data-touch="fire"]').boundingBox())!;
  const fire: Point = { x: Math.round(fireBox.x + fireBox.width / 2), y: Math.round(fireBox.y + fireBox.height / 2), id: 3 };
  await t.down([stick, look, fire]);
  const stickUp = { ...stick, y: stick.y - 60 };
  for (let step = 1; step <= 8; step++) {
    await t.move([stickUp, { ...look, x: look.x + step * 15 }, fire]);
    await page.waitForTimeout(30);
  }
  const held = await page.evaluate(() => {
    const h = (window as never as { hellproof: { touch: { axes(): { active: boolean; y: number }; firing: boolean }; demoTurn(): number } }).hellproof;
    return { axes: h.touch.axes(), firing: h.touch.firing, demoTurn: h.demoTurn() };
  });
  expect(held.axes.active, "stick finger tracked").toBe(true);
  expect(held.axes.y, "stick pushed forward").toBeGreaterThan(0.5);
  expect(held.firing, "Fire held").toBe(true);
  // A drag to the right turns right: negative BAM, on the 256 grid.
  expect(held.demoTurn).toBeLessThan(0);
  expect(Math.abs(held.demoTurn) % 256).toBe(0);
  const turned = held.demoTurn;

  await t.up();
  await page.waitForTimeout(100);
  const released = await page.evaluate(() => {
    const h = (window as never as { hellproof: { touch: { axes(): { active: boolean }; firing: boolean; consume(f: boolean): { turn: number } }; demoTurn(): number } }).hellproof;
    return { active: h.touch.axes().active, firing: h.touch.firing, demoTurn: h.demoTurn() };
  });
  expect(released.active).toBe(false);
  expect(released.firing).toBe(false);
  expect(released.demoTurn, "no turn after the finger lifts").toBe(turned);

  // The view still renders with the controls on top of it.
  const histogram = await page.evaluate(() =>
    (window as never as { hellproof: { captureFrame(): Promise<{ distinct: number }> } }).hellproof.captureFrame());
  expect(histogram.distinct).toBeGreaterThan(32);

  // Pause from the overlay stops the demo scheduler and hides the controls.
  await t.down([{ ...(await box(page, "pause")), id: 4 }]);
  await t.up();
  await expect(controls).not.toHaveClass(/playing/);
  expect(await page.evaluate(() => (window as never as { hellproof: { scheduler: { isRunning: boolean } } }).hellproof.scheduler.isRunning)).toBe(false);
  await t.detach();

  expect(errors, `console/page errors: ${errors.join(" | ")}`).toEqual([]);
});

async function box(page: Page, name: string): Promise<{ x: number; y: number }> {
  const b = (await page.locator(`[data-touch="${name}"]`).boundingBox())!;
  return { x: Math.round(b.x + b.width / 2), y: Math.round(b.y + b.height / 2) };
}

test.describe("portrait phone", () => {
  const { defaultBrowserType: _portraitBrowser, ...portrait } = devices["Pixel 7"]!;
  test.use({ ...portrait, deviceScaleFactor: 1 });
  test("shows the orientation notice until dismissed", async ({ page }, testInfo) => {
    const errors = await boot(page);
    const size = page.viewportSize()!;
    expect(size.height).toBeGreaterThan(size.width);
    const notice = page.locator("#orientation");
    await expect(notice).toBeVisible();
    await expect(notice).toContainText("landscape");
    const screenshot = join(ARTIFACTS, "mobile-portrait.png");
    await page.screenshot({ path: screenshot });
    await testInfo.attach("mobile-portrait", { path: screenshot, contentType: "image/png" });
    await page.locator("#orientation-dismiss").tap();
    await expect(notice).toBeHidden();
    expect(errors).toEqual([]);
  });
});

test.describe("desktop", () => {
  const { defaultBrowserType: _desktopBrowser, ...desktop } = devices["Desktop Chrome"]!;
  test.use({ ...desktop, viewport: { width: 640, height: 400 }, deviceScaleFactor: 1 });
  test("mounts no touch controls", async ({ page }) => {
    const errors = await boot(page);
    await expect(page.locator("body")).not.toHaveClass(/touch/);
    expect(await page.locator(".touch-controls").count()).toBe(0);
    await expect(page.locator("#orientation")).toBeHidden();
    expect(errors).toEqual([]);
  });
});

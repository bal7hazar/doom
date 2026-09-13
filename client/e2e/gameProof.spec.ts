import { readFile, writeFile } from "node:fs/promises";
import { expect, test } from "@playwright/test";

import { guardWorkers } from "./proofWorkerGuard.js";
import { legacyDoomIdentity } from "../test/fixtures/legacyDoomIdentity.js";

async function advance(page: import("@playwright/test").Page, count: number): Promise<void> {
  await page.evaluate(async count => {
    const cairo = (window as any).hellproof.cairo;
    await cairo.resume(); for (let i = 0; i < count; i++) await cairo.advance(0); await cairo.pause();
  }, count);
}

test("real F4 retains acknowledged inputs, refuses AIR without prove, exports and resumes", async ({ page }) => {
  await guardWorkers(page);
  const errors: string[] = [], writes: string[] = []; page.on("pageerror", e => errors.push(String(e)));
  page.on("request", request => { if (!["GET", "HEAD"].includes(request.method())) writes.push(request.url()); });
  await page.goto("/"); await page.waitForFunction(() => Boolean((window as any).hellproof?.cairo?.journal));
  await advance(page, 4);
  expect(await page.evaluate(() => (window as any).proofWorkerAudit.workers.filter((w: any) => w.url.includes("doomPrepare")).length)).toBe(0);
  await page.keyboard.press("F4");
  const ui = page.getByRole("region", { name: "Real game proof" });
  await expect(ui.getByRole("button", { name: "Check resources / prove", exact: true })).toBeVisible();
  await advance(page, 2);
  await ui.getByRole("button", { name: "Check resources / prove", exact: true }).click();
  await expect(ui.locator(".proof-queue-log")).toContainText("Proof refused:", { timeout: 120_000 });
  await expect(ui.locator(".proof-queue-log")).toContainText("not certified");
  await expect(ui.getByLabel("Keep offline", { exact: true })).toBeChecked();
  await ui.locator(".proof-queue-log").scrollIntoViewIfNeeded();
  await page.screenshot({ path: test.info().outputPath("real-proof-refusal.png") });
  const downloadPromise = page.waitForEvent("download");
  await ui.getByRole("button", { name: "Export .hellproof", exact: true }).click();
  const download = await downloadPromise, bytes = await readFile((await download.path())!);
  const manifest = JSON.parse(bytes.subarray(16, 16 + bytes.readUInt32LE(12)).toString());
  expect(manifest.run.program).toBe("doom"); expect(manifest.run.keepOffline).toBe(true);
  expect(manifest.inputs.ticCount).toBe(6); expect(manifest.run.admissionFailure.args.length).toBeGreaterThan(100);
  expect(manifest.run.admissionFailure.outputPreimage).toHaveLength(11); expect(manifest.segments).toHaveLength(0);
  await writeFile(test.info().outputPath("refusal.hellproof"), bytes);
  await writeFile(test.info().outputPath("admission-manifest.json"), JSON.stringify(manifest, null, 2));
  const metadata = legacyDoomIdentity;
  const invalidManifest = { ...manifest, run: { ...manifest.run, programIdentity: JSON.stringify(metadata) } };
  const invalidJson = Buffer.from(JSON.stringify(invalidManifest)), invalid = Buffer.alloc(16 + invalidJson.length);
  bytes.copy(invalid, 0, 0, 16); invalid.writeUInt32LE(invalidJson.length, 12); invalidJson.copy(invalid, 16);
  await ui.getByLabel("Resume real proof file").setInputFiles({ name: "incompatible.hellproof", mimeType: "application/octet-stream", buffer: invalid });
  await expect(ui.getByRole("status").first()).toContainText("identity");
  await expect(ui.getByRole("button", { name: /^Export stored run/ })).toHaveCount(1);
  const preserved = page.waitForEvent("download");
  await ui.getByRole("button", { name: /^Export stored run/ }).click();
  const preservedDownload = await preserved;
  expect(preservedDownload.suggestedFilename()).toContain(".hellproof");
  const preservedBytes = await readFile((await preservedDownload.path())!);
  const preservedManifest = JSON.parse(preservedBytes.subarray(16, 16 + preservedBytes.readUInt32LE(12)).toString());
  expect(preservedManifest.inputs).toEqual(manifest.inputs);
  expect(preservedManifest.run.programIdentity).toBe(manifest.run.programIdentity);
  expect(preservedManifest.run.admissionFailure).toEqual(manifest.run.admissionFailure);
  expect(preservedManifest.segments).toEqual(manifest.segments);
  expect(preservedManifest.proofs).toEqual(manifest.proofs);
  // File selection cannot rewrite the supplied incompatible export bytes.
  expect(invalid.subarray(16).toString()).toBe(invalidJson.toString());
  const storedCount = await ui.getByRole("button", { name: /^Export stored run/ }).count();
  await ui.getByLabel("Resume real proof file").setInputFiles({ name: "resume.hellproof", mimeType: "application/octet-stream", buffer: bytes });
  await expect(ui.getByRole("button", { name: "Check resources / prove", exact: true })).toBeVisible();
  await expect(ui.getByRole("button", { name: /^Export stored run/ })).toHaveCount(storedCount + 1);
  // Returning to the game keeps the imported run independently exportable.
  await ui.getByRole("button", { name: "Current game", exact: true }).click();
  await expect(ui.getByRole("button", { name: "Check resources / prove", exact: true })).toBeVisible();
  expect(await page.evaluate(() => (window as any).proofWorkerAudit.proves)).toBe(0);
  await page.keyboard.press("F4");
  await page.getByRole("button", { name: "Restart", exact: true }).click();
  await page.waitForFunction(() => (window as any).hellproof.cairo.journal.length === 0);
  await page.keyboard.press("F4");
  await expect(ui.getByRole("button", { name: "Export previous game (6 tics)", exact: true })).toBeVisible();
  expect(errors).toEqual([]); expect(writes).toEqual([]);
});

test("Restart during initialization and cached-page suspension leave no preparation Worker", async ({ page }) => {
  await guardWorkers(page);
  await page.goto("/"); await page.waitForFunction(() => Boolean((window as any).hellproof?.cairo?.journal));
  let release!: () => void; const held = new Promise<void>(resolve => { release = resolve; });
  let requested!: () => void; const request = new Promise<void>(resolve => { requested = resolve; });
  await page.route("**/prover/game-proof/genesis.json", async route => { requested(); await held; await route.continue().catch(() => undefined); });
  await page.keyboard.press("F4"); await request;
  // Use the existing real client API: the overlay intentionally covers game controls.
  await page.evaluate(() => (window as any).hellproof.cairo.restart());
  await expect.poll(() => page.evaluate(() => (window as any).proofWorkerAudit.workers.filter((w: any) => w.url.includes("doomPrepare") && !w.dead).length)).toBe(0);
  release(); await page.unroute("**/prover/game-proof/genesis.json");
  await page.getByRole("button", { name: "Current game", exact: true }).click();
  await expect(page.getByRole("button", { name: "Check resources / prove", exact: true })).toBeVisible();
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent("pagehide", { persisted: true })));
  await expect.poll(() => page.evaluate(() => (window as any).proofWorkerAudit.workers.filter((w: any) => w.url.includes("doomPrepare") && !w.dead).length)).toBe(0);
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true })));
  await page.getByRole("button", { name: "Current game", exact: true }).click();
  await expect(page.getByRole("button", { name: "Check resources / prove", exact: true })).toBeVisible();
  expect(await page.evaluate(() => (window as any).proofWorkerAudit.proves)).toBe(0);
});

test("F4 pauses real keyboard play and releases pointer lock without catch-up", async ({ page }) => {
  await guardWorkers(page);
  await page.goto("/"); await page.waitForFunction(() => Boolean((window as any).hellproof?.cairo?.journal));
  await page.getByRole("button", { name: "Start", exact: true }).click();
  if (process.env.HELLPROOF_POINTER_LOCK === "1") {
    await page.bringToFront(); await page.mouse.click(620, 300);
    await page.waitForFunction(() => document.pointerLockElement !== null);
  }
  await page.keyboard.down("w");
  await page.waitForFunction(() => (window as any).hellproof.cairo.journal.length >= 2);
  await page.keyboard.press("F4"); await page.keyboard.up("w");
  await page.waitForFunction(() => !(window as any).hellproof.scheduler.isRunning && document.pointerLockElement === null && !(window as any).hellproof.cairo.busy);
  const paused = await page.evaluate(() => (window as any).hellproof.cairo.journal.length);
  await expect(page.getByRole("button", { name: "Check resources / prove", exact: true })).toBeVisible();
  // Exercise F4 while a proof button owns focus, too.
  await page.getByRole("button", { name: "Current game", exact: true }).focus();
  await page.keyboard.press("F4");
  await expect(page.getByRole("region", { name: "Real game proof" })).toBeHidden();
  expect(await page.evaluate(() => (window as any).hellproof.cairo.journal.length)).toBe(paused);
  expect(await page.evaluate(() => (window as any).hellproof.scheduler.isRunning)).toBe(false);
  await page.getByRole("button", { name: "Resume", exact: true }).click();
  await page.waitForFunction(paused => (window as any).hellproof.cairo.journal.length > paused, paused);
  await page.keyboard.press("F4");
  await page.waitForFunction(() => !(window as any).hellproof.cairo.busy);
  expect(await page.evaluate(() => (window as any).hellproof.scheduler.isRunning)).toBe(false);
  expect(await page.evaluate(() => (window as any).proofWorkerAudit.proves)).toBe(0);
});

test("missing proof asset leaves game export available and a later opening recovers", async ({ page }) => {
  await guardWorkers(page);
  await page.goto("/"); await page.waitForFunction(() => Boolean((window as any).hellproof?.cairo?.journal));
  await advance(page, 1);
  await page.route("**/prover/game-proof/genesis.json", route => route.fulfill({ status: 503, body: "temporarily unavailable" }));
  await page.keyboard.press("F4");
  const ui = page.getByRole("region", { name: "Real game proof" });
  await expect(ui.getByRole("status").first()).toContainText("can still be exported");
  const downloading = page.waitForEvent("download");
  await ui.getByRole("button", { name: "Export game journal", exact: true }).click();
  const data = await readFile((await (await downloading).path())!, "utf8");
  expect(data).toContain('"ticCount":1');
  await page.unroute("**/prover/game-proof/genesis.json");
  await ui.getByRole("button", { name: "Current game", exact: true }).click();
  await expect(ui.getByRole("button", { name: "Check resources / prove", exact: true })).toBeVisible();
  expect(await page.evaluate(() => (window as any).proofWorkerAudit.proves)).toBe(0);
});

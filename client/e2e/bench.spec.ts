// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0
import { existsSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test } from "@playwright/test";

/**
 * The embedded cadence bench (`/?bench=1`, D35: measured on the device). With
 * the Cairo artifacts staged it measures the real Worker; here it runs on the
 * demo stand-in, which the result must label as such, for 70 tics (2 s), and
 * must end with the JSON the tester pastes back. The Cairo variant is checked
 * below only when `public/sim/` exists.
 */

const HERE = dirname(fileURLToPath(import.meta.url));
const ARTIFACTS = join(HERE, "artifacts");
const ASSETS_PRESENT =
  existsSync(resolve(HERE, "..", "public", "freedoom1.wad")) &&
  existsSync(resolve(HERE, "..", "public", "levels", "e1m1.json"));
const SIM_PRESENT = existsSync(resolve(HERE, "..", "public", "sim", "manifest.json"));

test.skip(!ASSETS_PRESENT, "client/public/freedoom1.wad and levels/e1m1.json are missing - run `npm run assets`");
test.beforeAll(async () => { await mkdir(ARTIFACTS, { recursive: true }); });

interface Result {
  format: string;
  label: string;
  environment: { simulator: string; script: string; userAgent: string; crossOriginIsolated: boolean };
  paced: { tics: number; plannedTics: number; ticsPerSecond: number; vmMs: { p50: number; p95: number }; roundTripMs: { p95: number } };
  burst: { tics: number; ticsPerSecond: number } | null;
  render: { frames: number; fps: number; cpuMs: { p50: number } };
  memory: { workerWasmBytes: number | null; jsHeapBytes: number | null; userAgentSpecificBytes: number | null };
  verdict: { sustained35: boolean };
}

async function runBench(page: import("@playwright/test").Page, url: string): Promise<{ result: Result; errors: string[] }> {
  const errors: string[] = [];
  page.on("pageerror", err => errors.push(String(err)));
  page.on("console", msg => { if (msg.type() === "error") errors.push(msg.text()); });
  await page.goto(url);
  await expect(page.locator("#loading")).toBeHidden({ timeout: 120_000 });
  await expect(page.locator(".bench-panel")).toBeVisible();
  const result = await page.evaluate(() => (window as never as { hellproof: { benchDone: Promise<Result> } }).hellproof.benchDone);
  return { result, errors };
}

test("measures the demo stand-in for 70 tics and labels it as such", async ({ page }, testInfo) => {
  const { result, errors } = await runBench(page, "/?sim=demo&bench=1&tics=70");
  expect(result.format).toBe("hellproof-cadence-bench/1");
  expect(result.environment.simulator).toBe("demo");
  expect(result.label).toContain("DEMO");
  expect(result.environment.script).toBe("builtin");
  expect(result.paced.tics).toBe(70);
  expect(result.paced.plannedTics).toBe(70);
  expect(result.paced.ticsPerSecond).toBeGreaterThan(20);
  expect(result.paced.vmMs.p50).toBeGreaterThan(0);
  expect(result.burst).toBeNull();
  expect(result.render.frames).toBeGreaterThan(10);
  expect(result.render.cpuMs.p50).toBeGreaterThan(0);
  expect(result.memory.workerWasmBytes).toBeNull();
  expect(result.environment.userAgent.length).toBeGreaterThan(10);
  expect(result.environment.crossOriginIsolated).toBe(true);

  const panel = page.locator(".bench-panel");
  await expect(panel).toContainText("DEMO SIMULATOR");
  await expect(panel.locator('[role="status"]')).toContainText("Done");
  const json = await panel.locator("textarea").inputValue();
  expect(JSON.parse(json).paced.tics).toBe(70);
  await expect(panel.getByRole("button", { name: "Copy JSON" })).toBeVisible();
  const screenshot = join(ARTIFACTS, "bench-demo.png");
  await page.screenshot({ path: screenshot });
  await testInfo.attach("bench-demo", { path: screenshot, contentType: "image/png" });
  await testInfo.attach("bench-demo.json", { body: json, contentType: "application/json" });
  console.log(`demo bench: ${result.paced.ticsPerSecond.toFixed(1)} tics/s, render cpu p50 ${result.render.cpuMs.p50.toFixed(2)} ms`);
  expect(errors).toEqual([]);
});

test("measures the real Cairo Worker with a burst phase", async ({ page }, testInfo) => {
  test.skip(!SIM_PRESENT, "public/sim/ is not staged (scripts/prepare-sim.py)");
  const { result, errors } = await runBench(page, "/?bench=1&tics=105&burst=35");
  expect(result.environment.simulator).toBe("cairo");
  expect(result.label).not.toContain("DEMO");
  expect(result.paced.tics).toBe(105);
  expect(result.burst).not.toBeNull();
  expect(result.burst!.tics).toBe(35);
  expect(result.memory.workerWasmBytes).toBeGreaterThan(0);
  await testInfo.attach("bench-cairo.json", { body: JSON.stringify(result, null, 2), contentType: "application/json" });
  console.log(`cairo bench: ${result.paced.ticsPerSecond.toFixed(1)} tics/s paced, ${result.burst!.ticsPerSecond.toFixed(1)} burst, VM p95 ${result.paced.vmMs.p95.toFixed(2)} ms`);
  expect(errors).toEqual([]);
});

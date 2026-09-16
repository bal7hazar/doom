// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0
// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";
import { BENCH_FORMAT, BUILTIN_SCRIPT, CadenceBench, CAIRO_LABEL, DEMO_LABEL, describeResult, journalScript, percentiles,
  probeMemory, SCRIPT_CYCLE, TIC_BUDGET_MS, type BenchEnvironment } from "../src/bench/cadence.js";
import { mountBenchPanel } from "../src/ui/benchPanel.js";
import { decodeCmd, isCanonical, packLog } from "../src/prove/ticcmd.js";

const environment: BenchEnvironment = {
  simulator: "cairo", script: "builtin", userAgent: "UA", platform: "Android", hardwareConcurrency: 8, deviceMemoryGiB: 4,
  crossOriginIsolated: true, viewport: { width: 915, height: 412, devicePixelRatio: 2.6 }, gpu: "Adreno", softwareRasterizer: false, touch: true,
};

describe("cadence bench", () => {
  it("computes nearest-rank percentiles", () => {
    expect(percentiles([])).toEqual({ count: 0, mean: 0, p50: 0, p95: 0, max: 0 });
    const values = Array.from({ length: 100 }, (_, i) => i + 1);
    expect(percentiles(values)).toEqual({ count: 100, mean: 50.5, p50: 50, p95: 95, max: 100 });
    expect(percentiles([3, 1, 2])).toMatchObject({ p50: 2, p95: 3, max: 3 });
  });

  it("scripts canonical words the keyboard could have produced, over a 10 s cycle", () => {
    const seen = new Set<string>();
    for (let tic = 0; tic < SCRIPT_CYCLE * 2; tic++) {
      const cmd = decodeCmd(BUILTIN_SCRIPT.word(tic));
      expect(isCanonical(cmd)).toBe(true);
      expect([0, 25, 50]).toContain(cmd.forward);
      expect([0, 24]).toContain(cmd.side);
      expect([0, 512, -512, 1280]).toContain(cmd.turn); // the keyboard's 640 / 1280, quantized
      expect([0, 1, 2]).toContain(cmd.buttons);
      seen.add(JSON.stringify(cmd));
    }
    expect(seen.size).toBe(7); // idle, walk, turn, walk+fire, strafe, use, run+turn
    expect(BUILTIN_SCRIPT.word(0)).toBe(BUILTIN_SCRIPT.word(SCRIPT_CYCLE));
    expect(decodeCmd(BUILTIN_SCRIPT.word(200))).toEqual({ forward: 25, side: 0, turn: 0, buttons: 1 });
  });

  it("replays a saved journal's words, then neutral", () => {
    const words = [0x01808099, 0x00808080, 0x02818080];
    const script = journalScript("journal:x", { inputs: packLog(words), ticCount: words.length });
    expect([0, 1, 2, 3].map(t => script.word(t))).toEqual([...words, 0x00808080]);
  });

  it("summarises the paced phase, the burst, the frames, memory and the verdict", () => {
    let clock = 0;
    const bench = new CadenceBench(4, 2, () => clock);
    expect(bench.running).toBe(false);
    bench.startPaced();
    clock = 10;
    expect(bench.recordTic({ vmMs: 8, roundTripMs: 10, steps: 100, memoryBytes: 5 })).toBe(false);
    bench.recordFrame({ cpuMs: 1, frameMs: 16 });
    clock = 40;
    expect(bench.recordTic({ vmMs: 30, roundTripMs: 30, steps: 120, memoryBytes: 9 })).toBe(false);
    bench.recordFrame({ cpuMs: 3, frameMs: 20 });
    clock = 70;
    expect(bench.recordTic({ vmMs: 9, roundTripMs: 12, steps: 110, memoryBytes: 7 })).toBe(false);
    expect(bench.progress).toEqual({ phase: "paced", tics: 3, planned: 4, ticsPerSecond: 3000 / 70 });
    clock = 100;
    expect(bench.recordTic({ vmMs: 9, roundTripMs: 11, steps: 105, memoryBytes: 7 })).toBe(true);
    bench.endPaced();
    bench.recordTic({ vmMs: 99, roundTripMs: 99 }); // between phases: ignored
    bench.recordFrame({ cpuMs: 99, frameMs: 99 });
    bench.startBurst();
    clock = 110;
    bench.recordTic({ vmMs: 4, roundTripMs: 5 });
    clock = 120;
    bench.recordTic({ vmMs: 6, roundTripMs: 6 });
    bench.endBurst();
    const result = bench.summarise(environment, { jsHeapBytes: 1000, userAgentSpecificBytes: null }, 0);
    expect(result.format).toBe(BENCH_FORMAT);
    expect(result.label).toBe(CAIRO_LABEL);
    expect(result.paced).toMatchObject({ tics: 4, plannedTics: 4, elapsedMs: 100, ticsPerSecond: 40, droppedTics: 0, overBudget: 1 });
    expect(result.paced.vmMs).toMatchObject({ p50: 9, p95: 30, max: 30 });
    expect(result.paced.stepsPerTic).toMatchObject({ p50: 105, max: 120 });
    expect(result.burst).toMatchObject({ tics: 2, elapsedMs: 20, ticsPerSecond: 100 });
    expect(result.render).toMatchObject({ frames: 2, fps: 20 });
    expect(result.render.cpuMs.max).toBe(3);
    expect(result.memory).toEqual({ workerWasmBytes: 9, jsHeapBytes: 1000, userAgentSpecificBytes: null });
    expect(result.verdict).toEqual({ sustained35: false, ticsPerSecond: 40, p95RoundTripMs: 30, overBudgetFraction: 0.25 });
    expect(bench.stage).toBe("done");
    const rows = describeResult(result);
    expect(rows.map(([k]) => k)).toEqual(["simulator", "verdict", "paced tics/s", "VM ms/tic", "round trip ms/tic", "Cairo steps/tic", "burst tics/s", "render", "memory", "device", "isolation", "user agent"]);
    expect(rows.find(([k]) => k === "verdict")![1]).toBe("below 35 tics/s");
  });

  it("passes a run that holds 35 tics/s and fails a terminal one", () => {
    let clock = 0;
    const good = new CadenceBench(70, 0, () => clock);
    good.startPaced();
    for (let i = 0; i < 70; i++) { clock += TIC_BUDGET_MS; good.recordTic({ vmMs: 10, roundTripMs: 12 }); }
    const result = good.summarise({ ...environment, simulator: "demo" }, { jsHeapBytes: null, userAgentSpecificBytes: null }, 0);
    expect(result.label).toBe(DEMO_LABEL);
    expect(result.burst).toBeNull();
    expect(result.verdict.sustained35).toBe(true);
    expect(result.verdict.ticsPerSecond).toBeCloseTo(35, 5);
    expect(describeResult(result).find(([k]) => k === "verdict")![1]).toBe("35 tics/s sustained");

    const dead = new CadenceBench(70, 0, () => clock);
    dead.startPaced();
    dead.recordTic({ vmMs: 10, roundTripMs: 12 });
    dead.terminal = true;
    dead.endPaced();
    const early = dead.summarise(environment, { jsHeapBytes: null, userAgentSpecificBytes: null }, 0);
    expect(early.terminal).toBe(true);
    expect(early.verdict.sustained35).toBe(false);
    expect(describeResult(early).find(([k]) => k === "verdict")![1]).toContain("terminal");
  });

  it("probes memory without throwing where the APIs are missing or reject", async () => {
    expect(await probeMemory()).toEqual({ jsHeapBytes: null, userAgentSpecificBytes: null });
    const perf = performance as Performance & { memory?: unknown; measureUserAgentSpecificMemory?: unknown };
    perf.memory = { usedJSHeapSize: 123 };
    perf.measureUserAgentSpecificMemory = () => Promise.reject(new Error("not isolated"));
    expect(await probeMemory()).toEqual({ jsHeapBytes: 123, userAgentSpecificBytes: null });
    perf.measureUserAgentSpecificMemory = () => Promise.resolve({ bytes: 456 });
    expect(await probeMemory()).toEqual({ jsHeapBytes: 123, userAgentSpecificBytes: 456 });
    delete perf.memory; delete perf.measureUserAgentSpecificMemory;
  });

  it("renders the panel: progress, then the table, the JSON and a working Copy", async () => {
    const bench = new CadenceBench(2, 0, () => 0);
    const panel = mountBenchPanel(document.body, DEMO_LABEL);
    expect(panel.element.getAttribute("aria-label")).toBe("Cadence bench");
    expect(panel.element.textContent).toContain(DEMO_LABEL);
    bench.startPaced();
    bench.recordTic({ vmMs: 1, roundTripMs: 1 });
    panel.progress(bench);
    expect(panel.element.querySelector('[role="status"]')!.textContent).toContain("paced: tic 1/2");
    bench.recordTic({ vmMs: 1, roundTripMs: 1 });
    const result = bench.summarise({ ...environment, simulator: "demo" }, { jsHeapBytes: null, userAgentSpecificBytes: null }, 0);
    const text = panel.show(result);
    expect(JSON.parse(text).format).toBe(BENCH_FORMAT);
    const textarea = panel.element.querySelector("textarea")!;
    expect(textarea.hidden).toBe(false);
    expect(textarea.value).toBe(text);
    expect(panel.element.querySelectorAll("tr").length).toBeGreaterThan(8);
    const writeText = vi.fn(() => Promise.resolve());
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText } });
    (panel.element.querySelector("button") as HTMLButtonElement).click();
    expect(writeText).toHaveBeenCalledWith(text);
    await vi.waitFor(() => expect(panel.element.querySelector("button")!.textContent).toBe("Copied"));
    panel.fail("boom");
    expect(panel.element.querySelector('[role="status"]')!.textContent).toBe("boom");
    document.body.innerHTML = "";
  });
});

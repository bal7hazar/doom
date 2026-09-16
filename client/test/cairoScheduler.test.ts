import { afterEach, expect, it, vi } from "vitest";
import { CairoScheduler } from "../src/sim/cairoScheduler.js";
import { bindCairoPageLifecycle } from "../src/sim/cairoPageLifecycle.js";
import type { CairoClient } from "../src/sim/cairoClient.js";

afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); });

it("keeps cached sessions alive, preserves manual pause and cleans up on actual exit", () => {
  const surface = new EventTarget();
  vi.stubGlobal("window", surface);
  const scheduler = {
    isRunning: true,
    start: vi.fn(() => { scheduler.isRunning = true; }),
    stop: vi.fn(() => { scheduler.isRunning = false; }),
    dispose: vi.fn(),
  };
  const client = { dispose: vi.fn() };
  bindCairoPageLifecycle(scheduler, client);
  const send = (type: string, persisted: boolean) => surface.dispatchEvent(Object.assign(new Event(type), { persisted }));
  send("pagehide", true);
  expect(scheduler.isRunning).toBe(false);
  expect(client.dispose).not.toHaveBeenCalled();
  send("pageshow", true);
  expect(scheduler.start).toHaveBeenCalledTimes(1);
  scheduler.stop();
  send("pagehide", true); send("pageshow", true);
  expect(scheduler.start).toHaveBeenCalledTimes(1);
  expect(scheduler.isRunning).toBe(false);
  send("pagehide", false);
  expect(scheduler.dispose).toHaveBeenCalledTimes(1);
  expect(client.dispose).toHaveBeenCalledTimes(1);
  send("pageshow", true); send("pagehide", false);
  expect(scheduler.start).toHaveBeenCalledTimes(1);
  expect(client.dispose).toHaveBeenCalledTimes(1);
});

it("samples only one input in flight and discards paused wall time instead of accumulating inputs", async () => {
  vi.useFakeTimers();
  const document = Object.assign(new EventTarget(), { hidden: false });
  vi.stubGlobal("document", document);
  let complete!: () => void;
  const client = {
    busy: false, terminal: false, paused: true, stepMs: 0, latest: { snapshot: { tic: 0 } },
    async pause() { this.paused = true; }, async resume() { this.paused = false; },
    async advance() {
      this.busy = true;
      await new Promise<void>(resolve => { complete = resolve; });
      this.busy = false; this.latest.snapshot.tic++;
    },
  };
  const sample = vi.fn(() => 0x808080), errors = vi.fn();
  const scheduler = new CairoScheduler(client as unknown as CairoClient, sample, errors);
  scheduler.start(); await vi.advanceTimersByTimeAsync(29);
  expect(sample).toHaveBeenCalledTimes(1);
  await vi.advanceTimersByTimeAsync(1000);
  expect(sample).toHaveBeenCalledTimes(1);
  scheduler.stop(); complete(); await vi.advanceTimersByTimeAsync(10000);
  expect(sample).toHaveBeenCalledTimes(1); expect(client.latest.snapshot.tic).toBe(1);
  scheduler.start(); await vi.advanceTimersByTimeAsync(29);
  expect(sample).toHaveBeenCalledTimes(2);
  document.hidden = true; document.dispatchEvent(new Event("visibilitychange"));
  complete(); await vi.advanceTimersByTimeAsync(10000);
  expect(sample).toHaveBeenCalledTimes(2);
  document.hidden = false; document.dispatchEvent(new Event("visibilitychange"));
  await vi.advanceTimersByTimeAsync(29);
  expect(sample).toHaveBeenCalledTimes(3);
  client.terminal = true; complete(); await vi.advanceTimersByTimeAsync(1000);
  expect(scheduler.isRunning).toBe(false); expect(sample).toHaveBeenCalledTimes(3);
  expect(errors).not.toHaveBeenCalled(); scheduler.dispose();
});

// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

import { encodeCmd, quantize, unpackLog } from "../prove/ticcmd.js";
import type { JournalExport } from "../game/inputJournal.js";

/**
 * Embedded cadence bench (`/?bench=1`, D35 / PLAN C1 revised: "35 tics/s on a
 * mid-range phone" has to be *measured*, on the phone, by whoever holds it).
 *
 * This module is the measurement half and has no DOM: it scripts the inputs,
 * accumulates per-tic and per-frame samples and summarises them as one JSON
 * document the panel shows and the tester pastes back. `main.ts` feeds it from
 * the real game loop, so what is measured is the real Worker (or the demo
 * stand-in, labelled as such), with the renderer and the HUD running as they
 * do in play.
 */

export const BENCH_FORMAT = "hellproof-cadence-bench/1";
/** One tic at 35 Hz. */
export const TIC_BUDGET_MS = 1000 / 35;
export const DEFAULT_BENCH_TICS = 700;
export const DEFAULT_BURST_TICS = 175;

export interface Percentiles {
  count: number;
  mean: number;
  p50: number;
  p95: number;
  max: number;
}

/** Nearest-rank percentiles, the convention of `prover/sim/bench`. */
export function percentiles(values: readonly number[]): Percentiles {
  if (values.length === 0) return { count: 0, mean: 0, p50: 0, p95: 0, max: 0 };
  const sorted = Float64Array.from(values).sort();
  const at = (p: number): number => sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * p) - 1))]!;
  let sum = 0;
  for (const v of values) sum += v;
  return { count: values.length, mean: sum / values.length, p50: at(0.5), p95: at(0.95), max: sorted[sorted.length - 1]! };
}

/** A source of one quantized ticcmd word per tic. */
export interface InputScript {
  readonly name: string;
  word(tic: number): number;
}

/** Length of the built-in script's cycle, in tics (10 s). */
export const SCRIPT_CYCLE = 350;

/**
 * The built-in script: ten seconds of ordinary play repeated - idle, walk,
 * turn, walk while firing, strafe, use, run while turning - with exactly the
 * keyboard's numbers, so the Worker sees the mix of tics a player produces
 * (movement, a door, shots) rather than the cheapest idle tic.
 */
export const BUILTIN_SCRIPT: InputScript = {
  name: "builtin",
  word(tic: number): number {
    const t = ((tic % SCRIPT_CYCLE) + SCRIPT_CYCLE) % SCRIPT_CYCLE;
    let cmd = { forward: 0, side: 0, turn: 0, buttons: 0 };
    if (t >= 35 && t < 140) cmd = { forward: 25, side: 0, turn: 0, buttons: 0 };
    else if (t >= 140 && t < 175) cmd = { forward: 0, side: 0, turn: -640, buttons: 0 };
    else if (t >= 175 && t < 245) cmd = { forward: 25, side: 0, turn: 0, buttons: 1 };
    else if (t >= 245 && t < 280) cmd = { forward: 0, side: 24, turn: 0, buttons: 0 };
    else if (t >= 280 && t < 300) cmd = { forward: 0, side: 0, turn: 0, buttons: 2 };
    else if (t >= 300 && t < 335) cmd = { forward: 50, side: 0, turn: 1280, buttons: 0 };
    return encodeCmd(quantize(cmd));
  },
};

/** Replays a saved game's journal (`Export` on the play panel); neutral once exhausted. */
export function journalScript(name: string, data: Pick<JournalExport, "inputs" | "ticCount">): InputScript {
  const words = unpackLog(data.inputs, data.ticCount);
  const neutral = encodeCmd({ forward: 0, side: 0, turn: 0, buttons: 0 });
  return { name, word: (tic) => words[tic] ?? neutral };
}

export interface TicSample {
  /** Time the Worker spent on the tic (VM + checkpoint maintenance), when it reports it. */
  vmMs: number;
  /** Main-thread wall time from the request to the acknowledged frame. */
  roundTripMs: number;
  steps?: number;
  memoryBytes?: number;
}

export interface FrameSample {
  /** Renderer CPU time for the frame. */
  cpuMs: number;
  /** Wall time since the previous frame. */
  frameMs: number;
}

export interface BenchEnvironment {
  simulator: "cairo" | "demo";
  script: string;
  userAgent: string;
  platform: string | null;
  hardwareConcurrency: number;
  deviceMemoryGiB: number | null;
  crossOriginIsolated: boolean;
  viewport: { width: number; height: number; devicePixelRatio: number };
  gpu: string | null;
  softwareRasterizer: boolean;
  touch: boolean;
}

export interface PhaseSummary {
  tics: number;
  elapsedMs: number;
  ticsPerSecond: number;
  vmMs: Percentiles;
  roundTripMs: Percentiles;
  /** Tics whose round trip exceeded the 28.57 ms budget. */
  overBudget: number;
  stepsPerTic: Percentiles | null;
}

export interface MemorySummary {
  /** Peak `wasm_memory_bytes()` the Worker reported during the run. */
  workerWasmBytes: number | null;
  /** `performance.memory.usedJSHeapSize` of the page (Chromium). */
  jsHeapBytes: number | null;
  /** `performance.measureUserAgentSpecificMemory()` total (Chromium, cross-origin isolated). */
  userAgentSpecificBytes: number | null;
}

export interface BenchResult {
  format: typeof BENCH_FORMAT;
  label: string;
  when: string;
  environment: BenchEnvironment;
  /** 35 Hz pacing, renderer running: what the player experiences. */
  paced: PhaseSummary & { droppedTics: number; plannedTics: number };
  /** Back-to-back tics, no pacing: the Worker's raw throughput. `null` for the demo. */
  burst: PhaseSummary | null;
  render: { frames: number; fps: number; cpuMs: Percentiles; frameMs: Percentiles };
  memory: MemorySummary;
  /** The game reached a terminal state before the planned tics (the script died or exited). */
  terminal: boolean;
  /** Everything held over 35 tics/s: the pass/fail the sponsor reads first. */
  verdict: { sustained35: boolean; ticsPerSecond: number; p95RoundTripMs: number; overBudgetFraction: number };
}

export const DEMO_LABEL = "DEMO SIMULATOR - renderer stand-in, not the Cairo VM";
export const CAIRO_LABEL = "real Cairo simulation Worker";

function phase(samples: readonly TicSample[], elapsedMs: number): PhaseSummary {
  const steps = samples.filter(s => s.steps !== undefined).map(s => s.steps!);
  return {
    tics: samples.length,
    elapsedMs,
    ticsPerSecond: elapsedMs > 0 ? (samples.length * 1000) / elapsedMs : 0,
    vmMs: percentiles(samples.map(s => s.vmMs)),
    roundTripMs: percentiles(samples.map(s => s.roundTripMs)),
    overBudget: samples.filter(s => s.roundTripMs > TIC_BUDGET_MS).length,
    stepsPerTic: steps.length ? percentiles(steps) : null,
  };
}

/** Accumulates the samples of one run and summarises them. */
export class CadenceBench {
  readonly paced: TicSample[] = [];
  readonly burst: TicSample[] = [];
  readonly frames: FrameSample[] = [];
  private pacedStart = 0;
  private pacedEnd = 0;
  private burstStart = 0;
  private burstEnd = 0;
  private phase: "idle" | "paced" | "burst" | "done" = "idle";
  private peakWorkerBytes: number | null = null;
  terminal = false;

  constructor(
    readonly plannedTics = DEFAULT_BENCH_TICS,
    readonly plannedBurst = DEFAULT_BURST_TICS,
    private readonly now: () => number = () => performance.now(),
  ) {}

  get running(): boolean { return this.phase === "paced" || this.phase === "burst"; }
  get stage(): "idle" | "paced" | "burst" | "done" { return this.phase; }
  /** Tics recorded so far in the current phase, for the progress line. */
  get progress(): { phase: string; tics: number; planned: number; ticsPerSecond: number } {
    const samples = this.phase === "burst" ? this.burst : this.paced;
    const start = this.phase === "burst" ? this.burstStart : this.pacedStart;
    const elapsed = this.now() - start;
    return { phase: this.phase, tics: samples.length, planned: this.phase === "burst" ? this.plannedBurst : this.plannedTics,
      ticsPerSecond: elapsed > 0 ? (samples.length * 1000) / elapsed : 0 };
  }

  startPaced(): void { this.phase = "paced"; this.pacedStart = this.now(); }
  /** Returns true when the paced phase has just reached its planned length. */
  recordTic(sample: TicSample): boolean {
    if (sample.memoryBytes !== undefined) this.peakWorkerBytes = Math.max(this.peakWorkerBytes ?? 0, sample.memoryBytes);
    if (this.phase === "paced") {
      this.paced.push(sample);
      if (this.paced.length >= this.plannedTics) { this.pacedEnd = this.now(); return true; }
    } else if (this.phase === "burst") {
      this.burst.push(sample);
    }
    return false;
  }
  recordFrame(sample: FrameSample): void {
    if (this.phase === "paced") this.frames.push(sample);
  }
  endPaced(): void {
    if (this.phase === "paced") { this.pacedEnd = this.now(); this.phase = "idle"; }
  }
  startBurst(): void { this.phase = "burst"; this.burstStart = this.now(); }
  endBurst(): void { this.burstEnd = this.now(); this.phase = "idle"; }

  summarise(environment: BenchEnvironment, memory: Omit<MemorySummary, "workerWasmBytes">, droppedTics: number): BenchResult {
    this.phase = "done";
    const pacedMs = this.pacedEnd - this.pacedStart;
    const paced = { ...phase(this.paced, pacedMs), droppedTics, plannedTics: this.plannedTics };
    const burst = this.burst.length ? phase(this.burst, this.burstEnd - this.burstStart) : null;
    const frameMs = percentiles(this.frames.map(f => f.frameMs));
    const fps = pacedMs > 0 ? (this.frames.length * 1000) / pacedMs : 0;
    const overBudgetFraction = paced.tics ? paced.overBudget / paced.tics : 1;
    return {
      format: BENCH_FORMAT,
      label: environment.simulator === "cairo" ? CAIRO_LABEL : DEMO_LABEL,
      when: new Date().toISOString(),
      environment,
      paced,
      burst,
      render: { frames: this.frames.length, fps, cpuMs: percentiles(this.frames.map(f => f.cpuMs)), frameMs },
      memory: { workerWasmBytes: this.peakWorkerBytes, ...memory },
      terminal: this.terminal,
      verdict: {
        // 34 rather than 35: the scheduler waits for each acknowledgement and
        // `setTimeout` rounds up, so a Worker that is exactly on budget lands a
        // hair under 35.0; anything below 34 means real tics are being lost.
        sustained35: !this.terminal && paced.tics === this.plannedTics && paced.ticsPerSecond >= 34 && overBudgetFraction < 0.05 && droppedTics / Math.max(1, paced.tics) < 0.01,
        ticsPerSecond: paced.ticsPerSecond,
        p95RoundTripMs: paced.roundTripMs.p95,
        overBudgetFraction,
      },
    };
  }
}

const ms = (v: number): string => `${v.toFixed(2)} ms`;
const mib = (bytes: number | null): string => bytes === null ? "n/a" : `${(bytes / 1024 / 1024).toFixed(1)} MiB`;

/** The rows of the results table, in reading order. */
export function describeResult(r: BenchResult): [string, string][] {
  const rows: [string, string][] = [
    ["simulator", r.label],
    ["verdict", r.verdict.sustained35 ? "35 tics/s sustained" : r.terminal ? "stopped early: terminal game state" : "below 35 tics/s"],
    ["paced tics/s", `${r.paced.ticsPerSecond.toFixed(2)} (${r.paced.tics}/${r.paced.plannedTics} tics in ${(r.paced.elapsedMs / 1000).toFixed(1)} s, ${r.paced.droppedTics} dropped)`],
    ["VM ms/tic", `p50 ${ms(r.paced.vmMs.p50)} · p95 ${ms(r.paced.vmMs.p95)} · max ${ms(r.paced.vmMs.max)}`],
    ["round trip ms/tic", `p50 ${ms(r.paced.roundTripMs.p50)} · p95 ${ms(r.paced.roundTripMs.p95)} · over ${TIC_BUDGET_MS.toFixed(2)} ms: ${r.paced.overBudget} (${(r.verdict.overBudgetFraction * 100).toFixed(1)} %)`],
  ];
  if (r.paced.stepsPerTic) rows.push(["Cairo steps/tic", `p50 ${r.paced.stepsPerTic.p50.toFixed(0)} · max ${r.paced.stepsPerTic.max.toFixed(0)}`]);
  if (r.burst) rows.push(["burst tics/s", `${r.burst.ticsPerSecond.toFixed(1)} (${r.burst.tics} unpaced tics; VM p50 ${ms(r.burst.vmMs.p50)}, p95 ${ms(r.burst.vmMs.p95)})`]);
  rows.push(
    ["render", `${r.render.fps.toFixed(1)} fps · cpu p50 ${ms(r.render.cpuMs.p50)} · p95 ${ms(r.render.cpuMs.p95)} · frame p95 ${ms(r.render.frameMs.p95)}`],
    ["memory", `Worker wasm peak ${mib(r.memory.workerWasmBytes)} · JS heap ${mib(r.memory.jsHeapBytes)} · UA-specific ${mib(r.memory.userAgentSpecificBytes)}`],
    ["device", `${r.environment.hardwareConcurrency} cores · ${r.environment.deviceMemoryGiB ?? "?"} GiB · ${r.environment.viewport.width}×${r.environment.viewport.height} @${r.environment.viewport.devicePixelRatio} · ${r.environment.gpu ?? "unknown GPU"}${r.environment.softwareRasterizer ? " (software)" : ""}`],
    ["isolation", `crossOriginIsolated ${r.environment.crossOriginIsolated} · touch ${r.environment.touch} · script ${r.environment.script}`],
    ["user agent", r.environment.userAgent],
  );
  return rows;
}

/** The page-side memory figures, each `null` where the browser does not expose it. */
export async function probeMemory(): Promise<Omit<MemorySummary, "workerWasmBytes">> {
  const perf = globalThis.performance as Performance & {
    memory?: { usedJSHeapSize: number };
    measureUserAgentSpecificMemory?: () => Promise<{ bytes: number }>;
  };
  let userAgentSpecificBytes: number | null = null;
  try {
    // Chromium, cross-origin isolated documents only; rejects elsewhere.
    if (typeof perf.measureUserAgentSpecificMemory === "function") userAgentSpecificBytes = (await perf.measureUserAgentSpecificMemory()).bytes;
  } catch { userAgentSpecificBytes = null; }
  return { jsHeapBytes: perf.memory?.usedJSHeapSize ?? null, userAgentSpecificBytes };
}

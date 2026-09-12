import { SnapshotRing, TICRATE, type RenderSnapshot } from "./snapshot.js";

export const TIC_MS = 1000 / TICRATE;

export interface SchedulerOptions {
  /** At most this many tics are caught up per wake-up (S3 §7.4: no spiral of death). */
  maxCatchup?: number;
  /** Deterministic pause when the tab is hidden, as PLAN.md phase 2 task 3 requires. */
  pauseWhenHidden?: boolean;
  /** Rate multiplier for debugging (`[` / `]` in the UI). 1 = 35 Hz. */
  rate?: number;
}

/**
 * Fixed-step 35 Hz scheduler, transcribed from `docs/spikes/S3.md` §7.4.
 *
 * `setTimeout` with an accumulator rather than `setInterval` (which drifts) or
 * `requestAnimationFrame` (60 Hz, and frozen when the tab is hidden). When the
 * loop falls more than `maxCatchup` tics behind it *abandons* the lost time
 * instead of manufacturing empty tics, because the ticcmd journal has to stay
 * exactly the sequence that will be proven.
 *
 * The stub sim runs here on the main thread. P2.3 moves the body of `run()`
 * into the Worker unchanged: it already writes through `SnapshotRing`, which is
 * SharedArrayBuffer-backed whenever the document is cross-origin isolated.
 */
export class TicScheduler {
  readonly ring: SnapshotRing;
  private readonly step: (tic: number) => RenderSnapshot;
  private readonly maxCatchup: number;
  private readonly pauseWhenHidden: boolean;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private nextDue = 0;
  private running = false;

  tic = 0;
  rate: number;
  /** Tics abandoned because the loop could not keep up; surfaced by the HUD. */
  droppedTics = 0;
  /** Rolling average of the time one `step()` call takes, in ms. */
  stepMs = 0;

  constructor(
    ring: SnapshotRing,
    step: (tic: number) => RenderSnapshot,
    options: SchedulerOptions = {},
  ) {
    this.ring = ring;
    this.step = step;
    this.maxCatchup = options.maxCatchup ?? 4;
    this.pauseWhenHidden = options.pauseWhenHidden ?? true;
    this.rate = options.rate ?? 1;
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.nextDue = performance.now();
    // Publish two tics immediately so the renderer has a pair to interpolate
    // from on its very first frame.
    this.runOne();
    this.runOne();
    this.schedule();
  }

  stop(): void {
    this.running = false;
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
  }

  get isRunning(): boolean {
    return this.running;
  }

  private schedule(): void {
    if (!this.running) return;
    const delay = Math.max(0, this.nextDue - performance.now());
    this.timer = setTimeout(() => this.loop(), delay);
  }

  private loop(): void {
    if (!this.running) return;
    if (this.pauseWhenHidden && typeof document !== "undefined" && document.visibilityState === "hidden") {
      // Deterministic pause: the tic counter does not advance, so the proof
      // stays a contiguous run of tics.
      this.nextDue = performance.now();
      this.schedule();
      return;
    }
    const interval = TIC_MS / Math.max(this.rate, 0.01);
    let ran = 0;
    while (performance.now() >= this.nextDue && ran < this.maxCatchup) {
      this.runOne();
      this.nextDue += interval;
      ran++;
    }
    if (performance.now() >= this.nextDue) {
      // Still behind after the catch-up budget: give up on the lost time.
      const behind = Math.floor((performance.now() - this.nextDue) / interval);
      this.droppedTics += Math.max(0, behind);
      this.nextDue = performance.now();
    }
    this.schedule();
  }

  private runOne(): void {
    const t0 = performance.now();
    const snapshot = this.step(this.tic);
    this.ring.publish(snapshot);
    this.tic++;
    const dt = performance.now() - t0;
    this.stepMs = this.stepMs === 0 ? dt : this.stepMs * 0.9 + dt * 0.1;
  }

  /**
   * How far into the current tic the wall clock is, for the renderer's
   * interpolation factor. Clamped to [0, 1]: a late frame must not extrapolate
   * past the newest snapshot, which would rubber-band on the next tic.
   */
  alpha(now = performance.now()): number {
    const interval = TIC_MS / Math.max(this.rate, 0.01);
    const t = 1 - (this.nextDue - now) / interval;
    return t < 0 ? 0 : t > 1 ? 1 : t;
  }
}

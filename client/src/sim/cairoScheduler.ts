import type { CairoClient } from "./cairoClient.js";

const TIC_MS = 1000 / 35;

/** No catch-up burst: each due tic samples one input after the previous acknowledgement. */
export class CairoScheduler {
  readonly rate = 1;
  droppedTics = 0;
  private running = false;
  private timer?: ReturnType<typeof setTimeout>;
  private lastPublished = 0;
  private epoch = 0;
  private readonly visibility = (): void => {
    if (!this.running) return;
    const epoch = ++this.epoch;
    clearTimeout(this.timer);
    if (document.hidden) void this.client.pause().catch(this.onError);
    else void this.begin(epoch);
  };
  constructor(private readonly client: CairoClient, private readonly sample: () => number,
    private readonly onError: (error: unknown) => void = console.error) {
    document.addEventListener("visibilitychange", this.visibility);
  }
  get tic(): number { return this.client.latest?.snapshot.tic ?? 0; }
  get stepMs(): number { return this.client.stepMs; }
  get isRunning(): boolean { return this.running; }
  start(): void {
    if (this.running || this.client.terminal) return;
    this.running = true;
    const epoch = ++this.epoch;
    if (!document.hidden) void this.begin(epoch);
  }
  stop(): void {
    this.running = false; ++this.epoch; clearTimeout(this.timer);
    void this.client.pause().catch(this.onError);
  }
  private async begin(epoch: number): Promise<void> {
    try {
      await this.client.resume();
      if (epoch === this.epoch && this.running && !document.hidden) this.schedule(epoch, TIC_MS);
    } catch (error) { this.running = false; this.onError(error); }
  }
  private schedule(epoch: number, delay: number): void {
    this.timer = setTimeout(() => { void this.tick(epoch); }, delay);
  }
  private async tick(epoch: number): Promise<void> {
    if (epoch !== this.epoch || !this.running || document.hidden) return;
    // A suspended input can still be completing after resume; never sample a second one.
    if (this.client.busy) { this.schedule(epoch, TIC_MS); return; }
    const start = performance.now();
    try {
      await this.client.advance(this.sample());
      this.lastPublished = performance.now();
      if (this.client.terminal) { this.running = false; return; }
      if (epoch === this.epoch && this.running && !document.hidden) {
        const elapsed = performance.now() - start;
        this.droppedTics += Math.floor(elapsed / TIC_MS);
        this.schedule(epoch, Math.max(0, TIC_MS - elapsed));
      }
    } catch (error) { this.running = false; this.onError(error); }
  }
  alpha(now = performance.now()): number { return this.running ? Math.min(1, Math.max(0, (now - this.lastPublished) / TIC_MS)) : 1; }
  dispose(): void { this.stop(); document.removeEventListener("visibilitychange", this.visibility); }
}

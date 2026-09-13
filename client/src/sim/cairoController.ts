import { decodeCairoSnapshot } from "./cairoSnapshot.js";
import { stateTic, word32 } from "./felts.js";
import type { CairoBackend, SimRequest, SimResponse } from "./cairoProtocol.js";

/** One retained VM, one outstanding command, no queue and no wall-clock inputs. */
export class CairoController {
  private backend?: CairoBackend;
  private busy = false;
  private paused = true;
  private failed = false;
  private terminal = false;
  private seq = 0;
  private tic = 0;
  private generation = 0;
  private wake?: () => void;

  constructor(
    private readonly load: (assets?: string) => Promise<CairoBackend>,
    private readonly emit: (response: SimResponse, transfer: ArrayBuffer[]) => void,
    private readonly yieldTask: () => Promise<void> = () => new Promise(resolve => setTimeout(resolve, 0)),
    private readonly quantum = 1_000_000,
    private readonly resumeQuantum = quantum,
  ) {}

  private error(id: number, code: Extract<SimResponse, { type: "error" }>["code"], message: string, fatal = false): void {
    this.emit({ type: "error", id, code, message, fatal }, []);
  }

  async handle(message: SimRequest): Promise<void> {
    if (!message || !Number.isSafeInteger(message.id) || message.id < 0) { this.error(-1, "invalid", "invalid request id"); return; }
    const id = message.id;
    if (message.type === "dispose") {
      this.generation++; this.wake?.(); this.wake = undefined;
      this.backend?.free(); this.backend = undefined; this.busy = false; this.paused = true;
      this.emit({ type: "disposed", id }, []); return;
    }
    if (message.type === "pause" || message.type === "resume") {
      if (!this.backend || this.failed) { this.error(id, "uninitialized", "no usable simulation"); return; }
      this.paused = message.type === "pause";
      if (!this.paused) { this.wake?.(); this.wake = undefined; }
      this.emit({ type: this.paused ? "paused" : "resumed", id }, []); return;
    }
    if (this.busy) { this.error(id, "busy", "one operation is already in flight"); return; }
    if (message.type !== "init" && (!this.backend || (this.failed && message.type !== "restart"))) {
      this.error(id, "uninitialized", "initialize or restart the simulation first"); return;
    }
    if (message.type === "advance") {
      if (this.terminal) { this.error(id, "terminal", "terminal state; restart required"); return; }
      if (this.paused) { this.error(id, "paused", "simulation is paused"); return; }
      if (message.seq !== this.seq) { this.error(id, "order", `expected sequence ${this.seq}`); return; }
      try { word32(message.word); } catch (error) { this.error(id, "invalid", String(error)); return; }
    } else if (!["init", "restart", "checkpoint"].includes(message.type)) {
      this.error(id, "invalid", "unknown request type"); return;
    }
    this.busy = true;
    const generation = this.generation;
    try {
      if (message.type === "init" || message.type === "restart") {
        if (message.type === "init") {
          this.backend?.free(); this.backend = undefined;
          const loaded = await this.load(message.assets);
          if (generation !== this.generation) { loaded.free(); return; }
          this.backend = loaded;
        }
        const backend = this.backend!;
        const initial = backend.initialize(message.state ? new Uint8Array(message.state) : undefined);
        const decoded = decodeCairoSnapshot(initial.frame);
        this.tic = stateTic(initial.state);
        if (decoded.snapshot.tic !== this.tic || decoded.status !== initial.status) throw new Error("inconsistent initial Cairo outputs");
        this.seq = 0; this.paused = true; this.failed = false; this.terminal = initial.status !== 0;
        const frame = initial.frame.slice().buffer, state = initial.state.slice().buffer;
        this.emit({ type: "ready", id, identity: backend.identity, frame, state, status: initial.status,
          tic: this.tic, transport: "arraybuffer", memoryBytes: backend.memoryBytes() }, [frame, state]);
      } else if (message.type === "advance") {
        const backend = this.backend!;
        const before = backend.totalSteps(), start = performance.now();
        await this.finish(backend.advance(message.word, this.quantum), generation, true);
        const raw = backend.snapshot(), status = backend.status();
        const decoded = decodeCairoSnapshot(raw);
        const nextTic = decoded.snapshot.tic, consumed = nextTic === this.tic + 1;
        // Cairo's ABORT can return the previous state unchanged (e.g. MAX_TIC).
        // Its operation status is then 3 while the raw state/snapshot still says Running.
        const unchangedAbort = status === 3 && nextTic === this.tic;
        if ((!consumed && !unchangedAbort) || (decoded.status !== status && !unchangedAbort)) throw new Error("Cairo tic/status order mismatch");
        const steps = backend.totalSteps() - before;
        this.tic = nextTic; this.seq++; this.terminal = status !== 0;
        let state: ArrayBuffer | undefined;
        // Bound the append-only VM before its 256-command/32M-step limits.
        // Checkpoints and the following restart use Cairo's exact schema 2.
        if (this.seq % 32 === 0 || this.terminal) {
          await this.finish(backend.requestCheckpoint(this.quantum), generation, false);
          const checkpoint = backend.checkpoint();
          if (stateTic(checkpoint) !== this.tic) throw new Error("checkpoint tic mismatch");
          state = checkpoint.slice().buffer;
          backend.restart(checkpoint);
        }
        const frame = raw.slice().buffer;
        this.emit({ type: "frame", id, seq: message.seq, word: message.word, consumed, frame, state, status,
          tic: this.tic, elapsedMs: performance.now() - start, steps, memoryBytes: backend.memoryBytes() },
          state ? [frame, state] : [frame]);
      } else {
        const backend = this.backend!;
        await this.finish(backend.requestCheckpoint(this.quantum), generation, false);
        const bytes = backend.checkpoint();
        if (stateTic(bytes) !== this.tic) throw new Error("checkpoint tic mismatch");
        // Explicit boundary requests also compact; repeated requests cannot exhaust the VM.
        backend.restart(bytes);
        const state = bytes.slice().buffer;
        this.emit({ type: "checkpoint", id, state, tic: this.tic }, [state]);
      }
    } catch (error) {
      if (generation === this.generation) {
        this.failed = true; this.paused = true;
        this.error(id, "execution", error instanceof Error ? error.message : String(error), true);
      }
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }

  private async finish(progress: number, generation: number, pauseable: boolean): Promise<void> {
    while (progress === 1) {
      await this.yieldTask();
      if (generation !== this.generation) throw new Error("disposed operation");
      if (pauseable && this.paused) await new Promise<void>(resolve => { this.wake = resolve; });
      if (generation !== this.generation) throw new Error("disposed operation");
      progress = this.backend!.resume(this.resumeQuantum);
    }
    if (progress !== 0) throw new Error("Cairo session ended unexpectedly");
  }
}

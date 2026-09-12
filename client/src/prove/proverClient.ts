/**
 * Main-thread client for `@hellproof/prover-wasm`'s Worker.
 *
 * The package ships its own `createProver()`, and this is deliberately *not* it.
 * Two things the pipeline needs are not in that wrapper:
 *
 * 1. **A per-call deadline.** `prove()` blocks its Worker thread for seconds and,
 *    with threads, on `Atomics.wait`; a hung prove (R1-A8: two of ~16 threaded
 *    runs at >= 2 M steps in Chrome) cannot be cancelled from inside. The only
 *    lever is `Worker.terminate()` from *another* thread, which is why the
 *    pipeline stays on the page's thread and the prover is the thing it can kill.
 * 2. **A URL it controls.** The Worker and the two 45 MB artifacts are served as
 *    static files out of `public/prover/` (`npm run prover`), not bundled, so
 *    the build does not have to pull a 90 MB dependency through Rollup and the
 *    artifacts stay out of git.
 *
 * The wire protocol is the package's own (`pkg/src/protocol.ts`); only the types
 * are restated here, because that module is not in the package's `exports` map.
 */
import type {
  ExecutionStats,
  Felt,
  InitOptions,
  ProofStats,
  ProverEvent,
  ProverInfo,
  ProverParams,
  ResourceSummary,
} from "@hellproof/prover-wasm";

type Req =
  | { id: number; op: "init"; opts: InitOptions }
  | { id: number; op: "execute"; executable: string; args: Felt[] | string }
  | { id: number; op: "prove"; input: Uint8Array; params?: ProverParams | string }
  | { id: number; op: "verify"; proof: Uint8Array; params?: ProverParams | string }
  | { id: number; op: "proofToFelts"; proof: Uint8Array; params?: ProverParams | string }
  | { id: number; op: "resources"; input: Uint8Array; params?: ProverParams | string }
  | { id: number; op: "defaultParams" }
  | { id: number; op: "terminate" };

type Res =
  | { id: number; ok: true; op: "init"; info: ProverInfo }
  | { id: number; ok: true; op: "execute"; input: Uint8Array; stats: ExecutionStats; ms: number }
  | { id: number; ok: true; op: "prove"; proof: Uint8Array; stats: ProofStats; ms: number }
  | { id: number; ok: true; op: "verify"; valid: boolean }
  | { id: number; ok: true; op: "proofToFelts"; felts: Felt[] }
  | { id: number; ok: true; op: "resources"; summary: ResourceSummary }
  | { id: number; ok: true; op: "defaultParams"; params: ProverParams }
  | { id: number; ok: true; op: "terminate" }
  | { id: number; ok: false; error: string }
  | { id: -1; event: ProverEvent };

/** `Omit` over a union keeps each member's own fields (plain `Omit` collapses them). */
type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never;
type ReqBody = DistributiveOmit<Req, "id">;

/**
 * What the pipeline needs from a prover. {@link ProverClient} is the real one;
 * the unit tests substitute a fake, which is why this is an interface and not
 * the class.
 */
export interface ProverLike {
  init(opts?: InitOptions): Promise<ProverInfo>;
  execute(
    executableJson: string,
    args: Felt[] | string,
  ): Promise<{ input: Uint8Array; stats: ExecutionStats; ms: number }>;
  resources(input: Uint8Array): Promise<ResourceSummary>;
  prove(
    input: Uint8Array,
    timeoutMs: number,
  ): Promise<{ proof: Uint8Array; stats: ProofStats; ms: number }>;
  verify(proof: Uint8Array): Promise<boolean>;
  terminate(): void;
  readonly isDead: boolean;
  readonly peakMemoryBytes: number;
}

/** Thrown when a call outlives its deadline. The Worker is dead afterwards. */
export class ProverTimeoutError extends Error {
  constructor(
    readonly op: string,
    readonly timeoutMs: number,
  ) {
    super(`prover ${op} exceeded its ${timeoutMs} ms deadline`);
    this.name = "ProverTimeoutError";
  }
}

/** Thrown when the Worker died (terminated, or a wasm panic aborted the module). */
export class ProverGoneError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ProverGoneError";
  }
}

export interface ProverClientOptions {
  /** URL of the package's `prover-worker.js`, served statically. */
  workerUrl: string | URL;
  onEvent?: (event: ProverEvent) => void;
  /** Overridable so unit tests can drive a fake Worker. */
  createWorker?: (url: string | URL) => Worker;
}

/** A live prover Worker. One per segment, by default (R1-A7: release the memory). */
export class ProverClient implements ProverLike {
  private readonly worker: Worker;
  private readonly onEvent: (event: ProverEvent) => void;
  private readonly pending = new Map<
    number,
    { resolve: (r: Res) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> | null }
  >();
  private nextId = 1;
  private dead: Error | null = null;
  /** Peak `WebAssembly.Memory.buffer.byteLength` reported since this client started. */
  peakMemoryBytes = 0;

  constructor(options: ProverClientOptions) {
    const make = options.createWorker ?? ((url) => new Worker(url, { type: "module", name: "hellproof-prover" }));
    this.worker = make(options.workerUrl);
    this.onEvent = options.onEvent ?? ((): void => {});
    this.worker.addEventListener("message", (ev: MessageEvent) => this.onMessage(ev.data as Res));
    this.worker.addEventListener("error", (ev) => {
      const message = (ev as ErrorEvent).message ?? "prover worker error";
      this.die(new ProverGoneError(`prover worker: ${message}`));
    });
  }

  private onMessage(message: Res): void {
    if ((message as { event?: unknown }).event !== undefined) {
      const event = (message as { id: -1; event: ProverEvent }).event;
      if (event.type !== "log" && typeof event.memoryBytes === "number") {
        this.peakMemoryBytes = Math.max(this.peakMemoryBytes, event.memoryBytes);
      }
      this.onEvent(event);
      return;
    }
    const answer = message as Exclude<Res, { id: -1 }>;
    const slot = this.pending.get(answer.id);
    if (!slot) return;
    this.pending.delete(answer.id);
    if (slot.timer !== null) clearTimeout(slot.timer);
    if (answer.ok) slot.resolve(answer);
    else slot.reject(new Error(answer.error));
  }

  private die(error: Error): void {
    this.dead ??= error;
    for (const [, slot] of this.pending) {
      if (slot.timer !== null) clearTimeout(slot.timer);
      slot.reject(error);
    }
    this.pending.clear();
  }

  private send(body: ReqBody, timeoutMs: number, transfer: Transferable[] = []): Promise<Res> {
    if (this.dead) return Promise.reject(this.dead);
    const id = this.nextId++;
    return new Promise<Res>((resolve, reject) => {
      const timer =
        timeoutMs > 0
          ? setTimeout(() => {
              this.pending.delete(id);
              const error = new ProverTimeoutError(body.op, timeoutMs);
              // Claim the cause before terminating, so the other pending calls are
              // rejected with the timeout rather than with the termination it causes.
              this.dead = error;
              // The Worker is stuck inside wasm and will never answer; kill it so
              // its 3-5 GiB of linear memory go with it.
              this.terminate();
              reject(error);
            }, timeoutMs)
          : null;
      this.pending.set(id, { resolve, reject, timer });
      this.worker.postMessage({ ...body, id } as Req, transfer);
    });
  }

  /** True once a call timed out or the Worker died: every later call rejects. */
  get isDead(): boolean {
    return this.dead !== null;
  }

  async init(opts: InitOptions = {}, timeoutMs = 120_000): Promise<ProverInfo> {
    const r = (await this.send({ op: "init", opts }, timeoutMs)) as Extract<Res, { op: "init" }>;
    this.peakMemoryBytes = Math.max(this.peakMemoryBytes, r.info.memoryBytes);
    return r.info;
  }

  async execute(
    executableJson: string,
    args: Felt[] | string,
    timeoutMs = 120_000,
  ): Promise<{ input: Uint8Array; stats: ExecutionStats; ms: number }> {
    const r = (await this.send(
      { op: "execute", executable: executableJson, args },
      timeoutMs,
    )) as Extract<Res, { op: "execute" }>;
    return { input: r.input, stats: r.stats, ms: r.ms };
  }

  async resources(
    input: Uint8Array,
    timeoutMs = 60_000,
    params?: ProverParams | string,
  ): Promise<ResourceSummary> {
    const r = (await this.send({ op: "resources", input, params }, timeoutMs)) as Extract<
      Res,
      { op: "resources" }
    >;
    return r.summary;
  }

  async prove(
    input: Uint8Array,
    timeoutMs: number,
    params?: ProverParams | string,
  ): Promise<{ proof: Uint8Array; stats: ProofStats; ms: number }> {
    const r = (await this.send({ op: "prove", input, params }, timeoutMs)) as Extract<
      Res,
      { op: "prove" }
    >;
    return { proof: r.proof, stats: r.stats, ms: r.ms };
  }

  async verify(proof: Uint8Array, timeoutMs = 120_000, params?: ProverParams | string): Promise<boolean> {
    // The proof is *copied* here rather than transferred: the caller still needs
    // the bytes to persist and to upload.
    const r = (await this.send({ op: "verify", proof, params }, timeoutMs)) as Extract<
      Res,
      { op: "verify" }
    >;
    return r.valid;
  }

  async proofToFelts(proof: Uint8Array, timeoutMs = 120_000, params?: ProverParams | string): Promise<Felt[]> {
    const r = (await this.send({ op: "proofToFelts", proof, params }, timeoutMs)) as Extract<
      Res,
      { op: "proofToFelts" }
    >;
    return r.felts;
  }

  /** Stops the Worker and releases the whole linear memory (R1-A7). */
  terminate(): void {
    try {
      this.worker.terminate();
    } catch {
      /* already gone */
    }
    this.die(new ProverGoneError("prover worker terminated"));
  }
}

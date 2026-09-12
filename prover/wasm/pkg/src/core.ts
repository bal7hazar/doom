/**
 * `ProverCore` — the prover itself, running in whatever context owns the wasm instance (the
 * package's prover Worker, a Worker of your own, or Node ≥ 24).
 *
 * The main thread should use {@link createProver} from `index.ts` instead: proving blocks its
 * thread for seconds, and with threads it blocks on `Atomics.wait`, which browsers forbid on the
 * main thread.
 */
import { ProverModule } from "./abi.js";
import { spawnThreadWorker, type ThreadWorkerHandle } from "./thread-pool.js";
import type {
  ExecutionStats,
  Felt,
  InitOptions,
  Proof,
  ProofStats,
  ProverEvent,
  ProverInfo,
  ProverInput,
  ProverParams,
  ResourceSummary,
  StageName,
} from "./types.js";

function isCrossOriginIsolated(): boolean {
  // Node has no such notion: SharedArrayBuffer is always available there.
  if (typeof globalThis.crossOriginIsolated === "boolean") return globalThis.crossOriginIsolated;
  return typeof SharedArrayBuffer !== "undefined";
}

/**
 * `hardwareConcurrency - 2` (R6-A1: leave cores for the game loop), capped at 4.
 *
 * The cap is measured, not conservative: on an M2 Max, 2^20 steps prove in 36.5 s with 1 thread,
 * 11.7 s with 4 and 12.4 s with 8 — witness generation starts losing to the allocator's spin lock
 * past 4 threads (README, Threads section). Pass an explicit `threads` to override.
 */
export const MAX_AUTO_THREADS = 4;

export function autoThreads(): number {
  const cores = globalThis.navigator?.hardwareConcurrency ?? 4;
  return Math.max(1, Math.min(MAX_AUTO_THREADS, cores - 2));
}

export class ProverCore {
  private mod: ProverModule | null = null;
  private info: ProverInfo | null = null;
  private threadWorkers: ThreadWorkerHandle[] = [];
  private idle: ThreadWorkerHandle[] = [];
  private stage: StageName = "execute";
  private onEvent: (e: ProverEvent) => void;

  constructor(onEvent: (e: ProverEvent) => void = () => {}) {
    this.onEvent = onEvent;
  }

  /** Loads an artifact and, if asked and possible, starts the rayon thread pool. */
  async init(opts: InitOptions = {}): Promise<ProverInfo> {
    if (this.info) return this.info;
    const t0 = performance.now();
    const coi = isCrossOriginIsolated();
    const want = opts.threads === "auto" ? autoThreads() : (opts.threads ?? 1);
    const threaded = want > 1 && coi;
    if (want > 1 && !coi) {
      this.onEvent({
        type: "log",
        level: "warn",
        message:
          "not cross-origin isolated (no SharedArrayBuffer): falling back to the single-threaded artifact",
      });
    }

    const url = new URL(
      String(
        threaded
          ? (opts.threadedWasmUrl ?? new URL("../wasm/hellproof_prover_wasm.threads.wasm", import.meta.url))
          : (opts.wasmUrl ?? new URL("../wasm/hellproof_prover_wasm.wasm", import.meta.url)),
      ),
      // Relative strings resolve against the package, like the defaults above.
      import.meta.url,
    );

    const module = await compile(url);
    let memory: WebAssembly.Memory | undefined;
    if (threaded) {
      // Memory64 + threads: a shared `WebAssembly.Memory` with 64-bit indices. Its descriptor
      // takes BigInt page counts and `address: "i64"`, neither of which lib.dom knows yet.
      memory = new WebAssembly.Memory({
        initial: BigInt(opts.initialPages ?? 512),
        maximum: BigInt(opts.maximumPages ?? 262144),
        shared: true,
        address: "i64",
      } as unknown as WebAssembly.MemoryDescriptor);
    }

    this.mod = await ProverModule.fromModule(module, {
      sharedMemory: memory,
      onLog: (level, message) => this.onEvent({ type: "log", level, message }),
      onSpan: (name, ms) =>
        this.onEvent({ type: "span", stage: this.stage, name, ms, memoryBytes: this.mod?.memoryBytes ?? 0 }),
      ...(threaded ? { spawnThread: (ptr: bigint) => this.handOverToWorker(ptr) } : {}),
    });

    let threads = 1;
    if (threaded && memory) {
      const stackBytes = opts.threadStackBytes ?? 16 * 1024 * 1024;
      for (let i = 0; i < want; i++) {
        this.threadWorkers.push(await spawnThreadWorker(this.mod, module, memory, i, stackBytes));
      }
      this.idle = [...this.threadWorkers];
      threads = this.mod.initThreadPool(want);
      if (threads === 0) throw new Error(`init_thread_pool(${want}) failed`);
    }

    this.info = {
      threads,
      threaded,
      crossOriginIsolated: coi,
      wasmUrl: url.href,
      instantiateMs: performance.now() - t0,
      memoryBytes: this.mod.memoryBytes,
    };
    return this.info;
  }

  private handOverToWorker(ptr: bigint): void {
    const w = this.idle.pop();
    if (!w) throw new Error("rayon asked for more threads than the pool was given");
    w.run(ptr);
  }

  private get module(): ProverModule {
    if (!this.mod) throw new Error("call init() first");
    return this.mod;
  }

  private run<I>(stage: StageName, fn: keyof typeof this.module.exports, args: (string | Uint8Array)[]) {
    this.stage = stage;
    this.onEvent({ type: "stage", stage, phase: "start", memoryBytes: this.module.memoryBytes });
    const r = this.module.call<I>(fn, args);
    this.onEvent({ type: "stage", stage, phase: "end", ms: r.ms, memoryBytes: r.memoryBytes });
    return r;
  }

  /**
   * Runs a Scarb executable under the leaf simple bootloader and adapts the run for the prover.
   * `args` are the program arguments as felts (`["0x1c"]` or `[28]`).
   */
  execute(executableJson: string, args: Felt[] | string): { input: ProverInput; stats: ExecutionStats; ms: number } {
    const argsJson = typeof args === "string" ? args : JSON.stringify(args);
    const r = this.run<ExecutionStats>("execute", "execute", [executableJson, argsJson]);
    return { input: r.data, stats: r.info, ms: r.ms };
  }

  /** Proves a `ProverInput`. Blocks this thread for seconds (see the class doc). */
  prove(input: ProverInput, params?: ProverParams | string): { proof: Proof; stats: ProofStats; ms: number } {
    const r = this.run<ProofStats>("prove", "prove", [input, paramsJson(params)]);
    return { proof: r.data, stats: r.info, ms: r.ms };
  }

  /** Verifies a proof in-process. Returns `true`, or throws with the verifier's reason. */
  verify(proof: Proof, params?: ProverParams | string): boolean {
    const r = this.run<{ ok: boolean }>("verify", "verify", [proof, paramsJson(params)]);
    return r.info.ok === true;
  }

  /** The cairo-serde felt stream of the proof (what the Cairo verifier / the leaf circuit take). */
  proofToFelts(proof: Proof, params?: ProverParams | string): Felt[] {
    const r = this.run<{ felts: number }>("proof_to_felts", "proof_to_felts", [proof, paramsJson(params)]);
    return JSON.parse(new TextDecoder().decode(r.data)) as Felt[];
  }

  /** Component sizes and counters of a `ProverInput`, without generating any trace. */
  resources(input: ProverInput, params?: ProverParams | string): ResourceSummary {
    return this.run<ResourceSummary>("resources", "resources", [input, paramsJson(params)]).info;
  }

  /** The built-in (leaf) prover parameters. */
  defaultParams(): ProverParams {
    const r = this.module.call<unknown>("default_params", []);
    return JSON.parse(new TextDecoder().decode(r.data)) as ProverParams;
  }

  get memoryBytes(): number {
    return this.module.memoryBytes;
  }

  get threads(): number {
    return this.info?.threads ?? 1;
  }

  /** Stops the thread workers. The wasm instance is released with this object. */
  terminate(): void {
    for (const w of this.threadWorkers) w.terminate();
    this.threadWorkers = [];
    this.idle = [];
    this.mod = null;
    this.info = null;
  }
}

function paramsJson(params?: ProverParams | string): string {
  if (params === undefined || params === null) return "";
  return typeof params === "string" ? params : JSON.stringify(params);
}

async function compile(url: URL): Promise<WebAssembly.Module> {
  if (url.protocol === "file:") {
    const { readFile } = await import("node:fs/promises");
    return WebAssembly.compile(await readFile(url));
  }
  return WebAssembly.compileStreaming(fetch(url));
}

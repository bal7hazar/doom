/**
 * JS side of the hand-written wasm64 ABI of `prover/wasm/src/lib.rs` (no wasm-bindgen).
 *
 * * `alloc(len) -> ptr` / `dealloc(ptr, len)` own the input buffers;
 * * every entry point takes `(ptr, len)` pairs and returns a pointer to a 40-byte result header
 *   (five little-endian u64: status, info_ptr, info_len, data_ptr, data_len), released with
 *   `free_result(ptr)`;
 * * `info` is a UTF-8 JSON string, `data` the payload.
 *
 * On wasm64 every pointer and length crosses the boundary as a BigInt.
 *
 * Two artifacts share this binding: the single-threaded one (module-owned memory) and the
 * threaded one (`+atomics`, memory imported from JS as a shared `WebAssembly.Memory`, extra
 * exports `init_thread_pool`/`worker_entry`/`__stack_pointer`/`__wasm_init_tls`/`__tls_size`).
 */

export interface HostHooks {
  /** Called for every tracing event and panic message of the module. */
  onLog?: (level: "error" | "warn" | "info" | "debug", message: string) => void;
  /** Called for every closed tracing span: `name` and its duration. */
  onSpan?: (name: string, ms: number) => void;
  /**
   * Threaded build only: start a Worker that instantiates the module on {@link memory}, points
   * `__stack_pointer` at a private stack, calls `__wasm_init_tls` and then `worker_entry(ptr)`.
   * Must return only once the Worker is queued; the calling thread then blocks.
   */
  spawnThread?: (ptr: bigint) => void;
}

const LOG_LEVELS = ["error", "warn", "info", "debug"] as const;

export interface ProverExports {
  memory?: WebAssembly.Memory;
  init(): void;
  alloc(len: bigint): bigint;
  dealloc(ptr: bigint, len: bigint): void;
  free_result(ptr: bigint): void;
  init_thread_pool(n: bigint): bigint;
  thread_count(): bigint;
  worker_entry?(ptr: bigint): void;
  execute(a: bigint, b: bigint, c: bigint, d: bigint): bigint;
  prove(a: bigint, b: bigint, c: bigint, d: bigint): bigint;
  verify(a: bigint, b: bigint, c: bigint, d: bigint): bigint;
  proof_to_felts(a: bigint, b: bigint, c: bigint, d: bigint): bigint;
  resources(a: bigint, b: bigint, c: bigint, d: bigint): bigint;
  default_params(): bigint;
  __stack_pointer?: WebAssembly.Global;
  __tls_size?: WebAssembly.Global;
  __tls_align?: WebAssembly.Global;
  __wasm_init_tls?(base: bigint): void;
}

export interface CallResult<I = unknown> {
  info: I;
  data: Uint8Array;
  ms: number;
  memoryBytes: number;
}

/** Builds the import object: the `host` module plus a loud stub for every other import. */
export function buildImports(
  module: WebAssembly.Module,
  memory: WebAssembly.Memory | undefined,
  host: {
    log: (level: number, ptr: bigint, len: bigint) => void;
    random: (ptr: bigint, len: bigint) => void;
    now: () => number;
    spawn_thread?: (ptr: bigint) => void;
  },
): WebAssembly.Imports {
  const imports: WebAssembly.Imports = { host: host as unknown as WebAssembly.ModuleImports };
  if (memory) imports["env"] = { memory };
  // `web-time` <- `microlp` <- `cairo-lang-eq-solver` links the wasm-bindgen runtime glue even
  // though nothing on the prover's path reaches it. Stub it loudly instead of patching.
  for (const imp of WebAssembly.Module.imports(module)) {
    if (imp.module === "host" || imp.module === "env") continue;
    if (imp.kind !== "function") {
      throw new Error(`unsupported non-function import ${imp.module}.${imp.name}`);
    }
    const slot = (imports[imp.module] ??= {}) as Record<string, unknown>;
    slot[imp.name] = () => {
      throw new Error(`unexpected call into stubbed import ${imp.module}.${imp.name}`);
    };
  }
  return imports;
}

/** Fills `[ptr, len)` of `memory` with cryptographic randomness (`crypto.getRandomValues`). */
export function fillRandom(memory: WebAssembly.Memory, ptr: bigint, len: bigint): void {
  const view = new Uint8Array(memory.buffer, Number(ptr), Number(len));
  // crypto.getRandomValues caps at 65536 bytes per call, and refuses SharedArrayBuffer views.
  const chunk = new Uint8Array(Math.min(view.length, 65536));
  for (let off = 0; off < view.length; off += 65536) {
    const n = Math.min(65536, view.length - off);
    crypto.getRandomValues(chunk.subarray(0, n));
    view.set(chunk.subarray(0, n), off);
  }
}

/** A wasm instance of the prover, with the ABI helpers. */
export class ProverModule {
  readonly exports: ProverExports;
  readonly memory: WebAssembly.Memory;
  readonly threaded: boolean;
  lastPanic: string | null = null;
  private hooks: HostHooks;

  private constructor(
    instance: WebAssembly.Instance,
    memory: WebAssembly.Memory,
    threaded: boolean,
    hooks: HostHooks,
  ) {
    this.exports = instance.exports as unknown as ProverExports;
    this.memory = memory;
    this.threaded = threaded;
    this.hooks = hooks;
    this.exports.init();
  }

  /**
   * Compiles and instantiates the module. `sharedMemory` must be given for the threaded artifact
   * (which imports `env.memory`) and omitted for the single-threaded one.
   */
  static async instantiate(
    source: BufferSource | Response | Promise<Response>,
    opts: HostHooks & { sharedMemory?: WebAssembly.Memory } = {},
  ): Promise<ProverModule> {
    const module =
      source instanceof Response || source instanceof Promise
        ? await WebAssembly.compileStreaming(source)
        : await WebAssembly.compile(source);
    return ProverModule.fromModule(module, opts);
  }

  /** Instantiates an already-compiled module (what the thread workers get by postMessage). */
  static async fromModule(
    module: WebAssembly.Module,
    opts: HostHooks & { sharedMemory?: WebAssembly.Memory } = {},
  ): Promise<ProverModule> {
    const wantsMemory = WebAssembly.Module.imports(module).some(
      (i) => i.module === "env" && i.name === "memory",
    );
    if (wantsMemory && !opts.sharedMemory) {
      throw new Error("this artifact imports env.memory: pass sharedMemory (threaded build)");
    }
    let self: ProverModule | null = null;
    const memoryForHost = () => self?.memory ?? (opts.sharedMemory as WebAssembly.Memory);
    const imports = buildImports(module, wantsMemory ? opts.sharedMemory : undefined, {
      log: (level, ptr, len) => self?.handleLog(level, ptr, len),
      random: (ptr, len) => fillRandom(memoryForHost(), ptr, len),
      now: () => performance.now(),
      ...(opts.spawnThread ? { spawn_thread: (ptr: bigint) => opts.spawnThread!(ptr) } : {}),
    });
    const instance = await WebAssembly.instantiate(module, imports);
    const memory =
      opts.sharedMemory ?? ((instance.exports as unknown as ProverExports).memory as WebAssembly.Memory);
    self = new ProverModule(instance, memory, wantsMemory, opts);
    return self;
  }

  /** Builds rayon's global pool; returns the number of threads it ended up with (0 = failed). */
  initThreadPool(n: number): number {
    return Number(this.exports.init_thread_pool(BigInt(n)));
  }

  get threadCount(): number {
    return Number(this.exports.thread_count());
  }

  get memoryBytes(): number {
    return this.memory.buffer.byteLength;
  }

  private handleLog(level: number, ptr: bigint, len: bigint): void {
    const msg = new TextDecoder().decode(this.bytes(ptr, len));
    const span = /^span:(.+):([\d.]+)$/.exec(msg);
    if (span) {
      this.hooks.onSpan?.(span[1]!, Number(span[2]));
      return;
    }
    if (msg.startsWith("panic:")) this.lastPanic = msg;
    this.hooks.onLog?.(LOG_LEVELS[level] ?? "debug", msg);
  }

  /** A *copy* of `[ptr, len)`: views on a SharedArrayBuffer cannot be handed to most JS APIs. */
  private bytes(ptr: bigint, len: bigint): Uint8Array {
    return new Uint8Array(this.memory.buffer, Number(ptr), Number(len)).slice();
  }

  private push(bytes: Uint8Array): [bigint, bigint] {
    if (bytes.byteLength === 0) return [0n, 0n];
    const len = BigInt(bytes.byteLength);
    const ptr = this.exports.alloc(len);
    new Uint8Array(this.memory.buffer, Number(ptr), bytes.byteLength).set(bytes);
    return [ptr, len];
  }

  /** Calls an export taking `(ptr,len)` pairs and returning a result header. */
  call<I = unknown>(fn: keyof ProverExports, args: (string | Uint8Array)[]): CallResult<I> {
    const enc = new TextEncoder();
    const pushed = args.map((a) => this.push(typeof a === "string" ? enc.encode(a) : a));
    this.lastPanic = null;
    const t0 = performance.now();
    let hdr: bigint;
    try {
      hdr = (this.exports[fn] as (...a: bigint[]) => bigint)(...pushed.flat());
    } catch (e) {
      const panic = this.lastPanic ? ` (${this.lastPanic})` : "";
      throw new Error(`${String(fn)} trapped: ${(e as Error)?.message ?? e}${panic}`);
    }
    const ms = performance.now() - t0;
    for (const [p, l] of pushed) if (l !== 0n) this.exports.dealloc(p, l);

    const dv = new DataView(this.memory.buffer);
    const h = Number(hdr);
    const status = dv.getBigUint64(h, true);
    const infoStr = new TextDecoder().decode(this.bytes(dv.getBigUint64(h + 8, true), dv.getBigUint64(h + 16, true)));
    const data = this.bytes(dv.getBigUint64(h + 24, true), dv.getBigUint64(h + 32, true));
    this.exports.free_result(hdr);

    let info: unknown;
    try {
      info = JSON.parse(infoStr);
    } catch {
      info = { raw: infoStr };
    }
    if (status !== 0n) {
      throw new Error(`${String(fn)} failed: ${(info as { error?: string })?.error ?? infoStr}`);
    }
    return { info: info as I, data, ms, memoryBytes: this.memoryBytes };
  }
}

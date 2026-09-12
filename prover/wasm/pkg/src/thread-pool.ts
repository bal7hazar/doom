/**
 * Host side of the rayon thread pool: one Worker per rayon thread, started **before**
 * `init_thread_pool` so that failures surface while the calling thread can still see them (it
 * blocks on `Atomics.wait` as soon as the pool is being built).
 *
 * Each Worker instantiates the same module on the same shared memory, then:
 *
 * 1. `__stack_pointer` is pointed at the top of a private stack allocated here, on this thread,
 *    with the module's own allocator (running wasm code in the Worker *before* its stack pointer
 *    is set would corrupt the spawning thread's stack);
 * 2. `__wasm_init_tls(tlsBase)` gives it its thread-local block;
 * 3. `worker_entry(ptr)` runs the rayon thread body handed over by `host.spawn_thread`.
 *
 * Works in browsers (nested module Workers) and in Node ≥ 24 (`node:worker_threads`).
 */
import type { ProverModule } from "./abi.js";

export interface ThreadWorkerHandle {
  /** Hands a rayon thread body (a leaked `Box<Box<dyn FnOnce()>>`) to this Worker. */
  run(ptr: bigint): void;
  terminate(): void;
}

export interface ThreadInitMessage {
  type: "init";
  module: WebAssembly.Module;
  memory: WebAssembly.Memory;
  stackTop: number;
  tlsBase: number;
  id: number;
}

export type ThreadMessage = ThreadInitMessage | { type: "run"; ptr: string };

const isNode = typeof (globalThis as { process?: { versions?: { node?: string } } }).process?.versions?.node === "string";

/** Allocates the thread's stack + TLS block and starts its Worker; resolves once it is ready. */
export async function spawnThreadWorker(
  mod: ProverModule,
  module: WebAssembly.Module,
  memory: WebAssembly.Memory,
  id: number,
  stackBytes: number,
): Promise<ThreadWorkerHandle> {
  const tlsSize = Number(mod.exports.__tls_size?.value ?? 0n);
  const tlsAlign = Math.max(Number(mod.exports.__tls_align?.value ?? 16n), 16);
  const block = Number(mod.exports.alloc(BigInt(stackBytes + tlsSize + tlsAlign)));
  const stackTop = block + stackBytes;
  const tlsBase = Math.ceil(stackTop / tlsAlign) * tlsAlign;
  const init: ThreadInitMessage = { type: "init", module, memory, stackTop, tlsBase, id };

  if (isNode) {
    const { Worker } = await import("node:worker_threads");
    const worker = new Worker(new URL("./thread-worker.js", import.meta.url));
    await new Promise<void>((resolve, reject) => {
      worker.once("message", (m: { type: string; error?: string }) =>
        m.type === "ready" ? resolve() : reject(new Error(m.error ?? JSON.stringify(m))),
      );
      worker.once("error", reject);
      worker.postMessage(init);
    });
    worker.unref();
    return {
      run: (ptr) => worker.postMessage({ type: "run", ptr: ptr.toString() }),
      terminate: () => void worker.terminate(),
    };
  }

  const worker = new Worker(new URL("./thread-worker.js", import.meta.url), {
    type: "module",
    name: `hellproof-rayon-${id}`,
  });
  await new Promise<void>((resolve, reject) => {
    const onMessage = (ev: MessageEvent) => {
      worker.removeEventListener("message", onMessage as EventListener);
      const m = ev.data as { type: string; error?: string };
      m.type === "ready" ? resolve() : reject(new Error(m.error ?? JSON.stringify(m)));
    };
    worker.addEventListener("message", onMessage as EventListener);
    worker.addEventListener("error", (e) => reject(new Error(`thread worker ${id}: ${e.message}`)), {
      once: true,
    });
    worker.postMessage(init);
  });
  return {
    run: (ptr) => worker.postMessage({ type: "run", ptr: ptr.toString() }),
    terminate: () => worker.terminate(),
  };
}

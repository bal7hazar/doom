/**
 * One rayon thread. Entry point of the Workers started by `thread-pool.ts`; never imported
 * directly. Runs in a browser Worker or a Node `worker_threads` Worker.
 *
 * It instantiates the *same* module on the *same* shared memory — Rust statics therefore live in
 * the shared linear memory and this thread sees the same allocator, tracing subscriber and rayon
 * registry as the prover thread — then sets its private shadow stack and TLS block before running
 * the rayon thread body.
 */
import { buildImports, fillRandom } from "./abi.js";
import type { ThreadMessage } from "./thread-pool.js";

interface ThreadExports {
  __stack_pointer: WebAssembly.Global;
  __wasm_init_tls(base: bigint): void;
  worker_entry(ptr: bigint): void;
}

let exports: ThreadExports | null = null;

async function onInit(m: Extract<ThreadMessage, { type: "init" }>, post: (v: unknown) => void) {
  const { module, memory, stackTop, tlsBase } = m;
  const imports = buildImports(module, memory, {
    // A rayon thread produces no user-visible logs; keep them on the console of this Worker so a
    // panic is never silent (the prover thread is blocked and cannot pump messages).
    log: (level, ptr, len) => {
      if (level <= 1) {
        console.error(`[hellproof rayon ${m.id}] ${new TextDecoder().decode(new Uint8Array(memory.buffer, Number(ptr), Number(len)).slice())}`);
      }
    },
    random: (ptr, len) => fillRandom(memory, ptr, len),
    now: () => performance.now(),
    spawn_thread: () => {
      throw new Error("a rayon thread cannot spawn further threads");
    },
  });
  const instance = await WebAssembly.instantiate(module, imports);
  exports = instance.exports as unknown as ThreadExports;
  // Order matters: give this thread its own stack and TLS before any Rust code runs on it.
  exports.__stack_pointer.value = BigInt(stackTop);
  exports.__wasm_init_tls(BigInt(tlsBase));
  post({ type: "ready" });
}

function handle(m: ThreadMessage, post: (v: unknown) => void): void {
  if (m.type === "init") {
    onInit(m, post).catch((e) => post({ type: "error", error: String((e as Error)?.message ?? e) }));
  } else if (m.type === "run") {
    // Runs until the pool is torn down; the Worker's event loop is blocked meanwhile, which is
    // exactly what a rayon worker thread does.
    exports?.worker_entry(BigInt(m.ptr));
  }
}

const nodeThreads = (globalThis as { process?: { versions?: { node?: string } } }).process?.versions?.node;
if (nodeThreads) {
  const { parentPort } = await import("node:worker_threads");
  parentPort?.on("message", (m: ThreadMessage) => handle(m, (v) => parentPort.postMessage(v)));
} else {
  self.addEventListener("message", (ev: MessageEvent) =>
    handle(ev.data as ThreadMessage, (v) => (self as unknown as Worker).postMessage(v)),
  );
}

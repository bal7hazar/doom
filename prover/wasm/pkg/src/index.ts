/**
 * `@hellproof/prover-wasm` — the Stwo Cairo prover of the Hellproof recursion leaf, compiled to
 * WASM64 (Memory64) and driven from the page.
 *
 * ```ts
 * import { createProver } from "@hellproof/prover-wasm";
 *
 * const prover = createProver({ onEvent: (e) => console.log(e) });
 * await prover.init({ threads: "auto" });          // needs crossOriginIsolated for threads
 * const { input, stats } = await prover.execute(executableJson, ["0x1c"]);
 * const budget = await prover.resources(input);    // steps + largest AIR component
 * const { proof } = await prover.prove(input);     // runs in a Worker, never blocks the page
 * await prover.verify(proof);
 * const felts = await prover.proofToFelts(proof);  // what the recursion leaf consumes
 * ```
 *
 * Everything heavy happens in a Worker; the returned promises resolve on the main thread. Proving
 * with threads *blocks* the prover Worker on `Atomics.wait`, which is why the module is never run
 * on the page's own thread.
 */
import { isEvent, type Request, type RequestBody, type Response } from "./protocol.js";
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
} from "./types.js";

export type {
  ExecutionStats,
  Felt,
  FriConfig,
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
export { ProverCore, autoThreads } from "./core.js";

export interface CreateProverOptions {
  /** Progress, memory and log events forwarded from the Worker. */
  onEvent?: (event: ProverEvent) => void;
  /** Use an existing Worker instead of starting `dist/prover-worker.js`. */
  worker?: Worker;
}

/** Handle on the prover Worker. Every method resolves when the Worker is done. */
export interface Prover {
  /** Loads the artifact (threaded when asked *and* cross-origin isolated) and starts the pool. */
  init(opts?: InitOptions): Promise<ProverInfo>;
  /** Runs a Scarb executable under the leaf bootloader; returns the `ProverInput` for `prove`. */
  execute(executableJson: string, args: Felt[] | string): Promise<{ input: ProverInput; stats: ExecutionStats; ms: number }>;
  /** Proves a `ProverInput` with the leaf parameters (override with `params`). */
  prove(input: ProverInput, params?: ProverParams | string): Promise<{ proof: Proof; stats: ProofStats; ms: number }>;
  /** Verifies a proof in the browser. Resolves to `true` or rejects with the verifier's reason. */
  verify(proof: Proof, params?: ProverParams | string): Promise<boolean>;
  /** Cairo-serde felt stream of a proof (the format the recursion leaf and `scarb verify` take). */
  proofToFelts(proof: Proof, params?: ProverParams | string): Promise<Felt[]>;
  /** Component sizes and counters of a `ProverInput` — segment sizing, no trace generated. */
  resources(input: ProverInput, params?: ProverParams | string): Promise<ResourceSummary>;
  /** The built-in leaf parameters. */
  defaultParams(): Promise<ProverParams>;
  /** Stops the Worker (and its thread pool), releasing the whole linear memory. */
  terminate(): Promise<void>;
  /** The underlying Worker, e.g. to transfer it or to listen for errors. */
  readonly worker: Worker;
}

export function createProver(opts: CreateProverOptions = {}): Prover {
  const worker =
    opts.worker ??
    new Worker(new URL("./prover-worker.js", import.meta.url), {
      type: "module",
      name: "hellproof-prover",
    });

  let nextId = 1;
  const pending = new Map<number, { resolve: (r: Response) => void; reject: (e: Error) => void }>();

  worker.addEventListener("message", (ev: MessageEvent) => {
    const m = ev.data as Response;
    if (isEvent(m)) {
      opts.onEvent?.(m.event);
      return;
    }
    const slot = pending.get(m.id);
    if (!slot) return;
    pending.delete(m.id);
    if (m.ok) slot.resolve(m);
    else slot.reject(new Error(m.error));
  });
  worker.addEventListener("error", (e) => {
    for (const [, slot] of pending) slot.reject(new Error(`prover worker: ${e.message}`));
    pending.clear();
  });

  function send(req: RequestBody, transfer: Transferable[] = []): Promise<Response> {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      worker.postMessage({ ...req, id } as Request, transfer);
    });
  }

  return {
    worker,
    async init(initOpts: InitOptions = {}) {
      const r = (await send({ op: "init", opts: initOpts })) as Extract<Response, { op: "init" }>;
      return r.info;
    },
    async execute(executableJson, args) {
      const r = (await send({ op: "execute", executable: executableJson, args })) as Extract<Response, { op: "execute" }>;
      return { input: r.input, stats: r.stats, ms: r.ms };
    },
    async prove(input, params) {
      const r = (await send({ op: "prove", input, params })) as Extract<Response, { op: "prove" }>;
      return { proof: r.proof, stats: r.stats, ms: r.ms };
    },
    async verify(proof, params) {
      const r = (await send({ op: "verify", proof, params })) as Extract<Response, { op: "verify" }>;
      return r.valid;
    },
    async proofToFelts(proof, params) {
      const r = (await send({ op: "proofToFelts", proof, params })) as Extract<Response, { op: "proofToFelts" }>;
      return r.felts;
    },
    async resources(input, params) {
      const r = (await send({ op: "resources", input, params })) as Extract<Response, { op: "resources" }>;
      return r.summary;
    },
    async defaultParams() {
      const r = (await send({ op: "defaultParams" })) as Extract<Response, { op: "defaultParams" }>;
      return r.params;
    },
    async terminate() {
      try {
        await send({ op: "terminate" });
      } finally {
        worker.terminate();
      }
    },
  };
}

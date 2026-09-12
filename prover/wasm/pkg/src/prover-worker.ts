/**
 * The prover Worker: owns the wasm instance and runs every blocking call off the main thread.
 * Started by {@link createProver}; you only import it directly if you want to wire your own
 * message plumbing (`@hellproof/prover-wasm/worker`).
 */
import { ProverCore } from "./core.js";
import type { Request, Response } from "./protocol.js";

const isNode = typeof (globalThis as { process?: { versions?: { node?: string } } }).process?.versions?.node === "string";

let post: (m: Response, transfer?: Transferable[]) => void = () => {};
const core = new ProverCore((event) => post({ id: -1, event }));

async function handle(req: Request): Promise<void> {
  try {
    switch (req.op) {
      case "init":
        post({ id: req.id, ok: true, op: "init", info: await core.init(req.opts) });
        break;
      case "execute": {
        const { input, stats, ms } = core.execute(req.executable, req.args);
        post({ id: req.id, ok: true, op: "execute", input, stats, ms }, [input.buffer as ArrayBuffer]);
        break;
      }
      case "prove": {
        const { proof, stats, ms } = core.prove(req.input, req.params);
        post({ id: req.id, ok: true, op: "prove", proof, stats, ms }, [proof.buffer as ArrayBuffer]);
        break;
      }
      case "verify":
        post({ id: req.id, ok: true, op: "verify", valid: core.verify(req.proof, req.params) });
        break;
      case "proofToFelts":
        post({ id: req.id, ok: true, op: "proofToFelts", felts: core.proofToFelts(req.proof, req.params) });
        break;
      case "resources":
        post({ id: req.id, ok: true, op: "resources", summary: core.resources(req.input, req.params) });
        break;
      case "defaultParams":
        post({ id: req.id, ok: true, op: "defaultParams", params: core.defaultParams() });
        break;
      case "terminate":
        core.terminate();
        post({ id: req.id, ok: true, op: "terminate" });
        break;
    }
  } catch (e) {
    post({ id: req.id, ok: false, error: String((e as Error)?.stack ?? (e as Error)?.message ?? e) });
  }
}

if (isNode) {
  const { parentPort } = await import("node:worker_threads");
  post = (m, transfer) => parentPort?.postMessage(m, transfer as never);
  parentPort?.on("message", (m: Request) => void handle(m));
} else {
  const scope = self as unknown as Worker;
  post = (m, transfer) => scope.postMessage(m, { transfer: transfer ?? [] });
  self.addEventListener("message", (ev: MessageEvent) => void handle(ev.data as Request));
}

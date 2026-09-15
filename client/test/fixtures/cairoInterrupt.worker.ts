/** Browser-only protocol fixture: force one real Cairo interruption before resuming normally. */
import { CairoController } from "../../src/sim/cairoController.js";
import { loadCairoBackend } from "../../src/sim/cairoBackend.js";
import type { SimRequest, SimResponse } from "../../src/sim/cairoProtocol.js";

const port = globalThis as unknown as {
  postMessage(response: SimResponse, transfer: ArrayBuffer[]): void;
  onmessage: ((event: MessageEvent<SimRequest>) => void) | null;
};
const controller = new CairoController(loadCairoBackend,
  (response, transfer) => port.postMessage(response, transfer),
  () => new Promise(resolve => setTimeout(resolve, 10)), 101, 1_000_000);
port.onmessage = event => { void controller.handle(event.data); };

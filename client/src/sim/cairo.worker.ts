import { loadCairoBackend } from "./cairoBackend.js";
import { CairoController } from "./cairoController.js";
import type { SimRequest, SimResponse } from "./cairoProtocol.js";

// Explicit owned ArrayBuffers work with and without cross-origin isolation.
// The existing renderer ring stays on the main thread: no concurrent slot overwrite.
const port = globalThis as unknown as {
  postMessage(message: SimResponse, transfer: ArrayBuffer[]): void;
  onmessage: ((event: MessageEvent<SimRequest>) => void) | null;
};
const controller = new CairoController(loadCairoBackend, (message, transfer) => port.postMessage(message, transfer));
port.onmessage = event => { void controller.handle(event.data); };

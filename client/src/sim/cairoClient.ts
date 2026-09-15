import type { SimIdentity } from "./cairoProtocol.js";
import { compatibleSimulation } from "./simulationCompatibility.js";
import { InputJournal, type JournalExport } from "../game/inputJournal.js";
import { encodeCmd, quantize, type TicCmd } from "../prove/ticcmd.js";
import { decodeCairoSnapshot, type CairoFrame } from "./cairoSnapshot.js";
import type { SimRequest, SimResponse } from "./cairoProtocol.js";
import { RING_BYTES, SnapshotRing } from "./snapshot.js";
import { decodeFelts, u32, word32 } from "./felts.js";

type ResponseOf<T extends SimResponse["type"]> = Extract<SimResponse, { type: T }>;
type Request = SimRequest extends infer R ? R extends { id: number } ? Omit<R, "id"> : never : never;
interface WorkerPort {
  postMessage(message: SimRequest, transfer: Transferable[]): void;
  addEventListener(type: "message", callback: (event: MessageEvent<SimResponse>) => void): void;
  addEventListener(type: "error", callback: (event: ErrorEvent) => void): void;
  terminate(): void;
}

/** Player.mo in an already Cairo-validated schema-2 state (3 header + 7 scalars).
 * Read only this field; never derive the camera actor from list order or position.
 */
export function viewMobjFromValidatedState(state: Uint8Array): number {
  return u32(decodeFelts(state.subarray(10 * 32, 11 * 32))[0]);
}

export class CairoClient {
  readonly ring = new SnapshotRing(new ArrayBuffer(RING_BYTES));
  journal?: InputJournal;
  /** Artifact identity currently loaded, distinct from an imported journal’s provenance. */
  loadedIdentity?: SimIdentity;
  latest?: CairoFrame;
  lastRawFrame?: Uint8Array;
  viewMobjId = 0;
  paused = true;
  terminal = false;
  /** Operation status; an unchanged ABORT need not equal the state's snapshot status. */
  status = 0;
  busy = false;
  stepMs = 0;
  memoryBytes = 0;
  private nextId = 0;
  private pauseEpoch = 0;
  private sequence = 0;
  private disposed = false;
  private readonly pending = new Map<number, { resolve: (value: SimResponse) => void; reject: (error: Error) => void }>();

  constructor(private readonly worker: WorkerPort = new Worker(new URL("./cairo.worker.ts", import.meta.url), { type: "module" })) {
    worker.addEventListener("message", event => {
      const message = event.data, pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.type === "error") {
        if (message.fatal) this.paused = true;
        pending.reject(new Error(`${message.code}: ${message.message}`));
      } else pending.resolve(message);
    });
    worker.addEventListener("error", event => {
      this.paused = true;
      for (const pending of this.pending.values()) pending.reject(new Error(event.message));
      this.pending.clear();
    });
  }

  private request<T extends SimResponse["type"]>(request: Request, expected: T, transfer: Transferable[] = []): Promise<ResponseOf<T>> {
    if (this.disposed) return Promise.reject(new Error("simulation disposed; create a new client"));
    const id = this.nextId++;
    return new Promise<SimResponse>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      try { this.worker.postMessage({ ...request, id } as SimRequest, transfer); }
      catch (error) { this.pending.delete(id); reject(error); }
    }).then(response => {
      if (response.type !== expected) throw new Error(`expected ${expected}, received ${response.type}`);
      return response as ResponseOf<T>;
    });
  }

  private ready(message: ResponseOf<"ready">): void {
    this.sequence = 0; ++this.pauseEpoch;
    this.loadedIdentity = structuredClone(message.identity);
    this.journal = new InputJournal(message.identity, new Uint8Array(message.state));
    this.viewMobjId = viewMobjFromValidatedState(new Uint8Array(message.state));
    this.ring.resetLocal();
    this.publish(message.frame);
    this.paused = true; this.status = message.status; this.terminal = message.status !== 0; this.memoryBytes = message.memoryBytes;
  }
  private acceptCheckpoint(state: Uint8Array): void {
    if (viewMobjFromValidatedState(state) !== this.viewMobjId) throw new Error("Cairo view actor changed within a session");
    this.journal!.checkpoint(state);
  }
  private publish(frame: ArrayBuffer): void {
    this.lastRawFrame = new Uint8Array(frame);
    this.latest = decodeCairoSnapshot(this.lastRawFrame);
    this.ring.publish(this.latest.snapshot);
  }
  async init(assets = "/sim/", state?: Uint8Array): Promise<void> {
    if (this.busy) throw new Error("busy: another operation is in flight");
    this.busy = true;
    const buffer = state?.slice().buffer;
    try { this.ready(await this.request({ type: "init", assets, state: buffer }, "ready", buffer ? [buffer] : [])); }
    finally { this.busy = false; }
  }
  async restart(state?: Uint8Array): Promise<void> {
    if (this.busy) throw new Error("busy: cannot restart during an input");
    this.busy = true;
    const buffer = state?.slice().buffer;
    try { this.ready(await this.request({ type: "restart", state: buffer }, "ready", buffer ? [buffer] : [])); }
    finally { this.busy = false; }
  }
  /** Restore a locally saved journal; Cairo replays its suffix from the last checkpoint.
   * Checkpoints remain untrusted for certification: proofs must replay from genesis.
   */
  async restore(data: JournalExport, assets = "/sim/"): Promise<void> {
    const journal = InputJournal.import(data), plan = journal.boundary(journal.ticEnd);
    await this.init(assets, plan.state);
    if (!compatibleSimulation(journal.identity, this.journal!.identity)) {
      throw new Error("journal executable identity differs from loaded simulation");
    }
    await this.resume();
    for (const word of plan.prefix) await this.advance(word);
    await this.pause();
    journal.checkpoint(await this.checkpoint());
    this.journal = journal;
    if (journal.rejected) { this.terminal = true; this.status = 3; }
  }
  async pause(): Promise<void> { ++this.pauseEpoch; this.paused = true; await this.request({ type: "pause" }, "paused"); }
  async resume(): Promise<void> {
    const epoch = ++this.pauseEpoch;
    await this.request({ type: "resume" }, "resumed");
    if (epoch === this.pauseEpoch) this.paused = false;
  }

  advanceCmd(command: TicCmd): Promise<ResponseOf<"frame">> { return this.advance(encodeCmd(quantize(command))); }
  async advance(word: number): Promise<ResponseOf<"frame">> {
    word32(word);
    if (!this.journal || this.paused || this.terminal || this.busy) throw new Error("simulation is not ready for an input");
    this.busy = true;
    try {
      const message = await this.request({ type: "advance", word, seq: this.sequence }, "frame");
      if (message.seq !== this.sequence || message.word !== word) throw new Error("input acknowledgement mismatch");
      if (message.consumed) this.journal.record(this.journal.length, message.word, message.tic);
      else {
        if (message.status !== 3) throw new Error("unconsumed input without ABORT");
        this.journal.abort(message.word, message.tic);
      }
      this.sequence++;
      if (message.state) this.acceptCheckpoint(new Uint8Array(message.state));
      this.publish(message.frame);
      this.status = message.status; this.terminal = message.status !== 0;
      if (this.terminal) this.paused = true;
      this.stepMs = message.elapsedMs; this.memoryBytes = message.memoryBytes;
      return message;
    } catch (error) { this.paused = true; throw error; }
    finally { this.busy = false; }
  }
  async checkpoint(): Promise<Uint8Array> {
    if (this.busy) throw new Error("busy: wait for the input acknowledgement");
    this.busy = true;
    try {
      const message = await this.request({ type: "checkpoint" }, "checkpoint");
      const state = new Uint8Array(message.state);
      this.acceptCheckpoint(state);
      return state;
    } finally { this.busy = false; }
  }
  dispose(): void {
    this.disposed = true; ++this.pauseEpoch;
    this.worker.terminate(); this.paused = true;
    for (const pending of this.pending.values()) pending.reject(new Error("simulation disposed"));
    this.pending.clear();
  }
}

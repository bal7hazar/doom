export interface SimIdentity {
  version: 1;
  stateSchema: 2;
  snapshotSchema: 1;
  revision: string;
  hashes: { session: string; genesis: string; step: string; wasm: string };
}

export type SimRequest =
  | { type: "init"; id: number; assets?: string; state?: ArrayBuffer }
  | { type: "advance"; id: number; seq: number; word: number }
  | { type: "pause" | "resume" | "checkpoint" | "dispose"; id: number }
  | { type: "restart"; id: number; state?: ArrayBuffer };

export type SimResponse =
  | { type: "ready"; id: number; identity: SimIdentity; frame: ArrayBuffer; state: ArrayBuffer; status: number; tic: number; transport: "arraybuffer"; memoryBytes: number }
  | { type: "frame"; id: number; seq: number; word: number; consumed: boolean; frame: ArrayBuffer; state?: ArrayBuffer; status: number; tic: number; elapsedMs: number; steps: number; memoryBytes: number }
  | { type: "checkpoint"; id: number; state: ArrayBuffer; tic: number }
  | { type: "paused" | "resumed" | "disposed"; id: number }
  | { type: "error"; id: number; code: "busy" | "order" | "paused" | "terminal" | "invalid" | "uninitialized" | "execution"; message: string; fatal: boolean };

export interface InitialFrame { state: Uint8Array; frame: Uint8Array; status: number }
/** Same real Cairo game functions in both adapters; the injectable interface is for protocol tests. */
export interface CairoBackend {
  identity: SimIdentity;
  initialize(state?: Uint8Array): InitialFrame;
  advance(word: number, quantum: number): number;
  resume(quantum: number): number;
  snapshot(): Uint8Array;
  status(): number;
  requestCheckpoint(quantum: number): number;
  checkpoint(): Uint8Array;
  restart(state: Uint8Array): void;
  totalSteps(): number;
  memoryBytes(): number;
  free(): void;
}

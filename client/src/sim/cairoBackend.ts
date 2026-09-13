import { decodeFelts, encodeFelts, sameBytes, stateTic, u32 } from "./felts.js";
import type { CairoBackend, SimIdentity } from "./cairoProtocol.js";

interface Program { run(bytes: Uint8Array): Uint8Array; free(): void }
interface Continuation {
  advance(word: number, quantum: number): number;
  resume(quantum: number): number;
  snapshot(): Uint8Array;
  status(): number;
  request_checkpoint(quantum: number): number;
  checkpoint(): Uint8Array;
  restart(state: Uint8Array): void;
  total_steps(): number;
  free(): void;
}
interface SimModule {
  default(options: { module_or_path: Uint8Array }): Promise<unknown>;
  SimProgram: { load(json: string): Program };
  SimContinuation: { load(json: string, state: Uint8Array): Continuation };
  wasm_memory_bytes(): number;
}

async function fetchBytes(url: URL): Promise<Uint8Array> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url.pathname}: HTTP ${response.status}; stage scripts/prepare-sim.py first`);
  return new Uint8Array(await response.arrayBuffer());
}

async function verified(base: URL, file: string, sha: string): Promise<Uint8Array> {
  if (!/^[a-f0-9]{64}$/.test(sha)) throw new Error("invalid artifact SHA256");
  const bytes = await fetchBytes(new URL(file, base));
  const actual = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>)), n => n.toString(16).padStart(2, "0")).join("");
  if (actual !== sha) throw new Error(`artifact SHA256 mismatch: ${file}`);
  return bytes;
}

export async function loadCairoBackend(assets = "/sim/"): Promise<CairoBackend> {
  const base = new URL(assets, globalThis.location.href);
  if (base.origin !== globalThis.location.origin || !base.pathname.endsWith("/")) throw new Error("simulation assets must be a same-origin directory");
  const identity = JSON.parse(new TextDecoder().decode(await fetchBytes(new URL("manifest.json", base)))) as SimIdentity;
  if (identity.version !== 1 || identity.stateSchema !== 2 || (identity.snapshotSchema !== 1 && identity.snapshotSchema !== 2)) throw new Error("unsupported simulation manifest");
  const [wasm, session, genesis, step] = await Promise.all([
    verified(base, "hellproof_sim_bg.wasm", identity.hashes.wasm),
    verified(base, "session.json", identity.hashes.session),
    verified(base, "genesis.json", identity.hashes.genesis),
    verified(base, "step.json", identity.hashes.step),
  ]);
  const url = new URL("hellproof_sim.js", base).href;
  const mod = await import(/* @vite-ignore */ url) as SimModule;
  await mod.default({ module_or_path: wasm });
  const text = new TextDecoder();
  const sessionJson = text.decode(session);
  const genesisProgram = mod.SimProgram.load(text.decode(genesis));
  let stepProgram: Program;
  try { stepProgram = mod.SimProgram.load(text.decode(step)); }
  catch (error) { genesisProgram.free(); throw error; }
  let sim: Continuation | undefined;
  const current = (): Continuation => { if (!sim) throw new Error("simulation not initialized"); return sim; };
  const checkedFrame = (bytes: Uint8Array): Uint8Array => {
    if (decodeFelts(bytes)[0] !== BigInt(identity.snapshotSchema)) throw new Error("Cairo frame schema differs from manifest");
    return bytes;
  };
  return {
    identity,
    initialize(initial) {
      sim?.free(); sim = undefined;
      let state = initial;
      if (!state) {
        const output = decodeFelts(genesisProgram.run(encodeFelts([0])));
        const count = u32(output[0]);
        if (!count || output.length !== count + 2) throw new Error("invalid genesis output");
        state = encodeFelts(output.slice(1, count + 1));
      }
      const fields = decodeFelts(state);
      const output = decodeFelts(stepProgram.run(encodeFelts([fields.length, ...fields, 0])));
      const status = u32(output[0]), count = u32(output[1]);
      const frameCount = u32(output[count + 2]);
      if (!count || output.length !== count + frameCount + 3 || status > 3) throw new Error("Cairo rejected the initial state");
      const canonical = encodeFelts(output.slice(2, count + 2));
      if (!sameBytes(state, canonical)) throw new Error("checkpoint changed during zero-tic validation");
      stateTic(canonical);
      sim = mod.SimContinuation.load(sessionJson, canonical);
      return { state: canonical, frame: checkedFrame(identity.snapshotSchema === 2 ? sim.snapshot() : encodeFelts(output.slice(count + 3))), status };
    },
    advance: (word, quantum) => current().advance(word, quantum),
    resume: quantum => current().resume(quantum),
    snapshot: () => checkedFrame(current().snapshot()),
    status: () => current().status(),
    requestCheckpoint: quantum => current().request_checkpoint(quantum),
    checkpoint: () => current().checkpoint(),
    restart: state => current().restart(state),
    totalSteps: () => current().total_steps(),
    memoryBytes: () => mod.wasm_memory_bytes(),
    free() { sim?.free(); sim = undefined; genesisProgram.free(); stepProgram.free(); },
  };
}

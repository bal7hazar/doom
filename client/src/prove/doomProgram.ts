import type { SimIdentity } from "../sim/cairoProtocol.js";
import { InputJournal, type JournalExport } from "../game/inputJournal.js";
import { D29_PROOF_ARTIFACTS as pins } from "./doomArtifacts.js";
import { checkedWords, exactFelts, type PreparedDoomSegment } from "./doomPreparation.js";
import type { SegmentProgram, SegmentRequest } from "./program.js";
import type { Felt, RunRecord } from "./types.js";
import { encodeFelts } from "../sim/felts.js";
import { normalizeFelt } from "./felt.js";
import { unpackLog } from "./ticcmd.js";

export interface PreparationPort {
  request<T>(body: object): Promise<T>;
  dispose(): void;
}
/** Dedicated Worker with bounded calls; no simulation or proof on the game thread. */
export class DoomPreparationClient implements PreparationPort {
  private id = 0;
  private dead = false;
  private readonly pending = new Map<number, { resolve(v: unknown): void; reject(e: Error): void; timer: ReturnType<typeof setTimeout> }>();
  constructor(private readonly worker = new Worker(new URL("./doomPrepare.worker.ts", import.meta.url), { type: "module" }), private readonly timeoutMs = 120_000) {
    worker.onmessage = ({ data }: MessageEvent<{ id: number; error?: string; result?: unknown }>) => {
      const p = this.pending.get(data.id); if (!p) return;
      this.pending.delete(data.id); clearTimeout(p.timer);
      if (data.error) p.reject(new Error(data.error)); else p.resolve(data.result);
    };
    worker.onerror = event => this.dispose(new Error(event.message));
  }
  request<T>(body: object): Promise<T> {
    if (this.dead) return Promise.reject(new Error("preparation worker is closed"));
    const id = this.id++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => this.dispose(new Error("Cairo preparation exceeded its deadline; journal remains recoverable")), this.timeoutMs);
      this.pending.set(id, { resolve: v => resolve(v as T), reject, timer });
      try { this.worker.postMessage({ id, ...body }); }
      catch (error) { this.pending.delete(id); clearTimeout(timer); reject(error); }
    });
  }
  dispose(error = new Error("Cairo preparation disposed")): void {
    this.dead = true; this.worker.terminate();
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(error); }
    this.pending.clear();
  }
}
function simulationKey(i: SimIdentity): string {
  if (i.version !== 1 || i.stateSchema !== 2 || i.snapshotSchema !== 1 || typeof i.revision !== "string"
      || Object.values(i.hashes).some(h => typeof h !== "string" || !/^[a-f0-9]{64}$/.test(h))) throw new Error("incompatible Cairo journal identity");
  return JSON.stringify([i.version, i.stateSchema, i.snapshotSchema, i.revision,
    i.hashes.session, i.hashes.genesis, i.hashes.step, i.hashes.wasm]);
}

export interface DoomProgramOptions {
  /** Journal created by CairoClient at tic zero, independent of the proof panel. */
  journal?(): JournalExport;
  /** Exported .hellproof inputs; reconstruct from pinned genesis, never from stored args/checkpoints. */
  resume?: { run: RunRecord; words: readonly number[] };
  assets?: string;
  /** Public execution boundary injected only by tests. */
  preparation?: PreparationPort;
}
export interface DoomProgram extends SegmentProgram { dispose(): void; journalWords(): number[] }
export async function createDoomProgram(options: DoomProgramOptions): Promise<DoomProgram> {
  const port = options.preparation ?? new DoomPreparationClient();
  try {
    const ready = await port.request<{ initial: Felt[]; genesis: Felt; executable: string }>({ op: "init", assets: options.assets });
    if (Boolean(options.journal) === Boolean(options.resume)) throw new Error("provide exactly one live journal or persisted run");
    let source = options.journal;
    if (options.resume) {
      const saved = options.resume;
      if (saved.run.program !== "doom" || saved.run.programHashFunction !== "blake" || !saved.run.programIdentity
          || normalizeFelt(saved.run.genesis) !== normalizeFelt(ready.genesis)) throw new Error("incompatible persisted Doom run");
      const metadata = JSON.parse(saved.run.programIdentity) as { simulation: string };
      const fields = JSON.parse(metadata.simulation) as [1, 2, 1, string, string, string, string, string];
      const sim: SimIdentity = { version: fields[0], stateSchema: fields[1], snapshotSchema: fields[2], revision: fields[3],
        hashes: { session: fields[4], genesis: fields[5], step: fields[6], wasm: fields[7] } };
      if (saved.words.length !== saved.run.ticCount) throw new Error("persisted journal length differs from run");
      const journal = new InputJournal(sim, encodeFelts(ready.initial));
      saved.words.forEach((word, seq) => journal.record(seq, word, seq + 1));
      source = () => journal.export();
    }
    const readSource = source!;
    const origin = structuredClone(readSource().identity);
    const identity = JSON.stringify({ adapter: "doom_run/state2/d14v1", artifacts: pins, simulation: simulationKey(origin) });
    const readJournal = (): number[] => {
      const data = readSource();
      InputJournal.import(data); // Canonical envelope/input packing only; its checkpoint is never a proof root.
      if (data.identity.version !== 1 || data.identity.stateSchema !== 2 || data.identity.snapshotSchema !== 1
          || data.identity.hashes.genesis !== pins.genesis || data.identity.hashes.step !== pins.step || data.identity.hashes.wasm !== pins.wasm
          || simulationKey(data.identity) !== simulationKey(origin)) throw new Error("incompatible Cairo journal identity");
      if (!exactFelts(data.initial, ready.initial)) throw new Error("proof journal must start at the pinned real genesis; imported checkpoint is not a root");
      if (data.rejected) throw new Error("journal contains a rejected Cairo command; export it before recovery");
      const words = unpackLog(data.inputs, data.ticCount); checkedWords(words); return words;
    };
    readJournal();
    if (options.resume && options.resume.run.programIdentity !== identity) throw new Error("persisted Doom executable/ABI identity differs");
    const prepared = new Map<string, Felt[]>();
    let active = false;
    return {
      id: "doom", hashFunction: "blake", genesis: ready.genesis, identity,
      executableJson: async () => ready.executable,
      encodeArgs() { throw new Error("doom_run requires asynchronous genesis replay preparation"); },
      journalWords: readJournal,
      validateJournal(words) {
        checkedWords(words); const journal = readJournal();
        if (words.length > journal.length || words.some((w, i) => journal[i] !== w)) throw new Error("persisted inputs disagree with the game journal");
      },
      async prepareArgs(request: SegmentRequest): Promise<Felt[]> {
        if (active) throw new Error("Cairo proof preparation already running");
        active = true;
        try {
          const result = await port.request<PreparedDoomSegment>({ op: "prepare", request, journal: readJournal() });
          prepared.clear(); // At most one full argument buffer; retry/resume always prepares afresh.
          prepared.set(JSON.stringify(result.args), result.expected);
          return result.args;
        } finally { active = false; }
      },
      validateOutput(args, preimage) {
        const expected = prepared.get(JSON.stringify(args));
        if (!expected || preimage.length !== 11 || normalizeFelt(preimage[0]!) !== pins.programHash || !exactFelts(preimage.slice(1), expected)) throw new Error("prover D14/D13 differs from the pinned Cairo journal replay");
      },
      dispose() { port.dispose(); prepared.clear(); },
    };
  } catch (error) { port.dispose(); throw error; }
}

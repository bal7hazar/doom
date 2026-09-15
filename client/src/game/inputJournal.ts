import { packLog, unpackLog } from "../prove/ticcmd.js";
import type { Felt } from "../prove/types.js";
import type { SimIdentity } from "../sim/cairoProtocol.js";
import { decodeFelts, encodeFelts, stateTic, word32 } from "../sim/felts.js";

export interface JournalExport {
  version: 1;
  identity: SimIdentity;
  initial: string[];
  checkpoint: string[];
  ticCount: number;
  inputs: Felt[];
  rejected?: { word: number; tic: number; status: 3 };
}
export interface ReplayBoundary {
  identity: SimIdentity;
  /** Exact consensus state at stateTic; includes historical ThingGrid order. */
  state: Uint8Array;
  stateTic: number;
  ticStart: number;
  /** Cairo must replay these before proving at a boundary between saved checkpoints. */
  prefix: number[];
  words: number[];
}

/** Acknowledged words, including tic zero, independent of opening the proof UI. */
export class InputJournal {
  readonly ticStart: number;
  private readonly initial: Uint8Array;
  private saved: Uint8Array;
  private readonly words: number[] = [];
  rejected?: { word: number; tic: number; status: 3 };

  constructor(readonly identity: SimIdentity, state: Uint8Array) {
    this.ticStart = stateTic(state);
    this.initial = state.slice(); this.saved = state.slice();
  }
  get length(): number { return this.words.length; }
  get ticEnd(): number { return this.ticStart + this.length; }

  record(seq: number, word: number, tic: number): void {
    word32(word);
    if (this.rejected || seq !== this.length || tic !== this.ticEnd + 1) throw new Error("journal order mismatch");
    this.words.push(word);
  }
  abort(word: number, tic: number): void {
    word32(word);
    if (this.rejected || tic !== this.ticEnd) throw new Error("rejected input order mismatch");
    this.rejected = { word, tic, status: 3 };
  }
  checkpoint(state: Uint8Array): void {
    if (stateTic(state) !== this.ticEnd) throw new Error("checkpoint must match the last acknowledged input");
    this.saved = state.slice();
  }
  boundary(ticStart: number, ticEnd = this.ticEnd): ReplayBoundary {
    if (!Number.isInteger(ticStart) || !Number.isInteger(ticEnd) || ticStart < this.ticStart || ticEnd < ticStart || ticEnd > this.ticEnd) {
      throw new RangeError("boundary outside journal");
    }
    const state = stateTic(this.saved) <= ticStart ? this.saved : this.initial;
    const from = stateTic(state);
    return { identity: structuredClone(this.identity), state: state.slice(), stateTic: from, ticStart,
      prefix: this.words.slice(from - this.ticStart, ticStart - this.ticStart),
      words: this.words.slice(ticStart - this.ticStart, ticEnd - this.ticStart) };
  }
  export(): JournalExport {
    return { version: 1, identity: structuredClone(this.identity), initial: decodeFelts(this.initial).map(String),
      checkpoint: decodeFelts(this.saved).map(String), ticCount: this.length, inputs: packLog(this.words),
      ...(this.rejected ? { rejected: { ...this.rejected } } : {}) };
  }
  /** Validates the envelope, not cryptographic provenance. Imported play still needs Cairo replay for proof. */
  static import(data: JournalExport): InputJournal {
    if (data.version !== 1 || data.identity.stateSchema !== 2 || (data.identity.snapshotSchema !== 1 && data.identity.snapshotSchema !== 2) || !Number.isSafeInteger(data.ticCount) || data.ticCount < 0) throw new Error("invalid journal envelope");
    const initial = encodeFelts(data.initial), saved = encodeFelts(data.checkpoint);
    const journal = new InputJournal(data.identity, initial);
    const words = unpackLog(data.inputs, data.ticCount);
    if (words.length !== data.ticCount || JSON.stringify(packLog(words)) !== JSON.stringify(data.inputs)) throw new Error("noncanonical input packing");
    words.forEach((word, seq) => journal.record(seq, word, journal.ticEnd + 1));
    if (stateTic(saved) < journal.ticStart || stateTic(saved) > journal.ticEnd) throw new Error("checkpoint outside journal");
    journal.saved = saved;
    if (data.rejected) {
      if (data.rejected.status !== 3) throw new Error("invalid rejected operation status");
      journal.abort(data.rejected.word, data.rejected.tic);
    }
    return journal;
  }
}

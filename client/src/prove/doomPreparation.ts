import { decodeSegmentOutput, type SegmentRequest } from "./program.js";
import { normalizeFelt, toFelt } from "./felt.js";
import type { Felt } from "./types.js";

export interface DoomExecutor { run(name: "genesis" | "step" | "segment", args: Felt[]): Felt[] }
export interface PreparedDoomSegment { args: Felt[]; expected: Felt[] }
const MAX_TIC = 2 ** 30;
export function exactFelts(a: readonly Felt[], b: readonly Felt[]): boolean {
  return a.length === b.length && a.every((v, i) => normalizeFelt(v) === normalizeFelt(b[i]!));
}
export function checkState(state: readonly Felt[]): number {
  const n = state.map(BigInt);
  if (n.length < 47 || n[0] !== 0x48502e5354415445n || n[1] !== 2n || n[2] !== BigInt(n.length - 3)
      || n.some(v => v < 0n || v >= 2n ** 72n) || n[4]! >= BigInt(MAX_TIC) || n[5]! > 2n) throw new Error("invalid Doom state schema 2");
  return Number(n[4]);
}
function range(n: number): void { if (!Number.isSafeInteger(n) || n < 0 || n >= MAX_TIC) throw new Error("invalid Doom tic range"); }
export function checkedWords(words: readonly number[]): void {
  if (words.some(w => !Number.isInteger(w) || w < 0 || w > 0xffffffff)) throw new Error("noncanonical Doom input word");
}
export function stepArgs(state: readonly Felt[], words: readonly number[]): Felt[] {
  return [toFelt(state.length), ...state, toFelt(words.length), ...words.map(toFelt)];
}
/** Worker-owned preparation. Only states produced from the pinned genesis enter its cache. */
export class DoomPreparation {
  readonly initial: Felt[];
  readonly genesis: Felt;
  private state: Felt[];
  private prefix: number[] = [];
  constructor(private readonly engine: DoomExecutor) {
    const output = engine.run("genesis", ["0x0"]);
    const count = Number(BigInt(output[0] ?? "-1"));
    if (count < 47 || output.length !== count + 2) throw new Error("invalid Doom genesis envelope");
    this.initial = output.slice(1, -1).map(normalizeFelt);
    if (checkState(this.initial) !== 0 || BigInt(this.initial[5]!) !== 0n) throw new Error("Doom genesis is not running tic zero");
    this.genesis = normalizeFelt(output.at(-1)!);
    this.state = [...this.initial];
    const empty = this.engine.run("segment", [...stepArgs(this.initial, []), "0x0", "0x0"]);
    const out = decodeSegmentOutput(empty);
    if (out.hIn !== this.genesis || out.hOut !== this.genesis || out.ticEnd !== 0 || out.status !== 0) throw new Error("Doom genesis hash disagrees with run_segment");
  }
  prepare(request: SegmentRequest, journal: readonly number[]): PreparedDoomSegment {
    range(request.ticStart); range(request.ticCount); range(request.index);
    checkedWords(journal); checkedWords(request.words);
    const end = request.ticStart + request.ticCount;
    if (end >= MAX_TIC || end > journal.length || request.words.length !== request.ticCount
        || request.words.some((w, i) => journal[request.ticStart + i] !== w)) throw new Error("segment is not the exact journal slice");
    if (this.prefix.some((w, i) => journal[i] !== w)) throw new Error("journal prefix changed after preparation");
    let tic = checkState(this.state);
    if (tic > request.ticStart) { this.state = [...this.initial]; tic = 0; }
    while (tic < request.ticStart) {
      const words = journal.slice(tic, Math.min(tic + 32, request.ticStart));
      const output = this.engine.run("step", stepArgs(this.state, words));
      const count = Number(BigInt(output[1] ?? "-1"));
      if (count < 47 || output.length < count + 3 || Number(BigInt(output[count + 2]!)) !== output.length - count - 3) throw new Error("invalid replay envelope");
      const state = output.slice(2, count + 2);
      const advanced = checkState(state);
      if (advanced !== tic + words.length || BigInt(output[0]!) !== BigInt(state[5]!)) throw new Error("journal reaches a terminal state before segment boundary");
      if (BigInt(state[5]!) !== 0n) throw new Error("terminal start boundaries are not supported, including empty EXIT/DEAD segments");
      this.state = state; tic = advanced;
    }
    this.prefix = journal.slice(0, request.ticStart);
    const args = [...stepArgs(this.state, request.words), toFelt(request.ticStart), toFelt(request.ticCount)];
    const expected = this.engine.run("segment", args).map(normalizeFelt);
    const out = decodeSegmentOutput(expected);
    if (out.hIn !== normalizeFelt(request.hIn) || out.ticStart !== request.ticStart || out.ticEnd < request.ticStart
        || out.ticEnd > end || out.status > 2 || (out.status === 0 && out.ticEnd !== end)
        || (request.ticCount > 0 && out.ticEnd === request.ticStart)) throw new Error("Doom D14 does not match requested chain");
    return { args, expected };
  }
}

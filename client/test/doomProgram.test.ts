import { describe, expect, it } from "vitest";
import { DoomPreparation, type DoomExecutor } from "../src/prove/doomPreparation.js";
import { createDoomProgram, type PreparationPort } from "../src/prove/doomProgram.js";
import { D29_PROOF_ARTIFACTS as pins } from "../src/prove/doomArtifacts.js";
import { InputJournal } from "../src/game/inputJournal.js";
import { encodeFelts } from "../src/sim/felts.js";
import { toFelt } from "../src/prove/felt.js";
import type { SegmentRequest } from "../src/prove/program.js";
import type { RunRecord } from "../src/prove/types.js";
import type { SimIdentity } from "../src/sim/cairoProtocol.js";
const initial = Array.from({ length: 47 }, () => "0x0");
initial[0] = "0x48502e5354415445"; initial[1] = "0x2"; initial[2] = toFelt(44); initial[6] = toFelt(100);
const identity: SimIdentity = { version: 1, stateSchema: 2, snapshotSchema: 1, revision: pins.revision,
  hashes: { genesis: pins.genesis, step: pins.step, wasm: pins.wasm, session: "a".repeat(64) } };
class Engine implements DoomExecutor {
  calls: string[] = [];
  run(name: "genesis" | "step" | "segment", args: string[]): string[] {
    this.calls.push(name);
    if (name === "genesis") return [toFelt(initial.length), ...initial, toFelt(100)];
    const n = Number(BigInt(args[0]!)), state = args.slice(1, n + 1), count = Number(BigInt(args[n + 1]!));
    const words = args.slice(n + 2, n + 2 + count).map(BigInt), tic = Number(BigInt(state[4]!));
    const h = BigInt(state[6]!), next = h + words.reduce((a, b) => a + b, 0n);
    if (name === "segment") return [1n, h, next, BigInt(tic), BigInt(tic + count), 0n,
      words.reduce((a, b) => a + b, 0n), 0n, 0n, 0n].map(toFelt);
    state[4] = toFelt(tic + count); state[6] = toFelt(next);
    return ["0x0", toFelt(n), ...state, "0x0"];
  }
}
const words = Array.from({ length: 45 }, (_, i) => i + 1);
function request(start: number, count: number): SegmentRequest {
  return { hIn: toFelt(100 + words.slice(0, start).reduce((a, b) => a + b, 0)), ticStart: start,
    ticCount: count, words: words.slice(start, start + count), index: 0 };
}
function journal() {
  const j = new InputJournal(identity, encodeFelts(initial));
  words.forEach((w, i) => j.record(i, w, i + 1)); return j.export();
}
function port(): PreparationPort {
  const prep = new DoomPreparation(new Engine());
  return { async request<T>(body: object): Promise<T> {
    const b = body as { op: string; request: SegmentRequest; journal: number[] };
    return (b.op === "init" ? { initial: prep.initial, genesis: prep.genesis, executable: "{}" } : prep.prepare(b.request, b.journal)) as T;
  }, dispose() {} };
}
describe("real program preparation contract", () => {
  it("replays from genesis to a boundary between maintenance checkpoints", () => {
    const engine = new Engine(), prep = new DoomPreparation(engine);
    const result = prep.prepare(request(33, 4), words);
    expect(engine.calls.filter(c => c === "step")).toHaveLength(2);
    expect(result.args[5]).toBe(toFelt(33)); // state tic, behind its array length
    expect(result.expected[3]).toBe(toFelt(33));
    expect(result.expected[4]).toBe(toFelt(37));
    expect(prep.prepare(request(3, 1), words).expected[3]).toBe(toFelt(3)); // rewind is genesis replay
  });
  it("rejects changed prefixes, forged hIn, wrong slices and noncanonical input", () => {
    const prep = new DoomPreparation(new Engine()); prep.prepare(request(33, 1), words);
    expect(() => prep.prepare(request(34, 1), [9, ...words.slice(1)])).toThrow(/prefix/);
    expect(() => prep.prepare({ ...request(0, 1), hIn: "0xdead" }, words)).toThrow(/D14/);
    expect(() => prep.prepare({ ...request(0, 1), words: [9] }, words)).toThrow(/slice/);
    expect(() => prep.prepare(request(0, 1), [-1])).toThrow(/noncanonical/);
  });
  it("accepts only a real genesis journal and never uses an imported checkpoint as proof root", async () => {
    const data = journal(); data.checkpoint[6] = "999"; // structurally valid, untrusted checkpoint
    const program = await createDoomProgram({ journal: () => data, preparation: port() });
    const args = await program.prepareArgs!(request(33, 4));
    expect(args[7]).toBe(request(33, 4).hIn);
    expect(() => program.encodeArgs(request(0, 1))).toThrow(/asynchronous/);
    data.initial[6] = "999";
    await expect(program.prepareArgs!(request(0, 1))).rejects.toThrow(/genesis/);
    program.dispose();
  });
  it("reconstructs an exported run only from its pinned genesis and complete persisted identity", async () => {
    const live = await createDoomProgram({ journal, preparation: port() });
    const run: RunRecord = { id: "resume", createdAt: 0, updatedAt: 0, program: live.id,
      programHashFunction: live.hashFunction, programIdentity: live.identity, genesis: live.genesis,
      stage: "recording", ticCount: words.length, ticsPlanned: 0, segments: 0,
      keepOffline: true, finished: false, submission: {} };
    live.dispose();
    const resumed = await createDoomProgram({ resume: { run, words }, preparation: port() });
    expect(resumed.journalWords()).toEqual(words);
    expect((await resumed.prepareArgs!(request(33, 4)))[7]).toBe(request(33, 4).hIn);
    resumed.dispose();
    await expect(createDoomProgram({ resume: { run: { ...run, programIdentity: run.programIdentity!.replace(pins.segment, "b".repeat(64)) }, words }, preparation: port() })).rejects.toThrow(/identity differs/);
    await expect(createDoomProgram({ resume: { run, words: words.slice(1) }, preparation: port() })).rejects.toThrow(/length/);
  });
  it("checks the entire D14 including D13 and refuses journal identity or persistence mismatch", async () => {
    const data = journal(), program = await createDoomProgram({ journal: () => data, preparation: port() });
    const args = await program.prepareArgs!(request(0, 4));
    const reference = new DoomPreparation(new Engine()).prepare(request(0, 4), words).expected;
    expect(() => program.validateOutput!(args, [pins.programHash, ...reference])).not.toThrow();
    expect(() => program.validateOutput!(args, ["0x123", ...reference])).toThrow(/D14\/D13/);
    const wrong = [...reference]; wrong[6] = "0x999";
    expect(() => program.validateOutput!(args, [pins.programHash, ...wrong])).toThrow(/D14\/D13/);
    expect(() => program.validateJournal!([99])).toThrow(/persisted inputs/);
    data.identity.hashes.step = "b".repeat(64);
    expect(() => program.journalWords()).toThrow(/identity/);
    program.dispose();
  });
});

import { describe, expect, it } from "vitest";
import { CairoController } from "../src/sim/cairoController.js";
import { CairoClient } from "../src/sim/cairoClient.js";
import { decodeCairoSnapshot } from "../src/sim/cairoSnapshot.js";
import { decodeFelts, encodeFelts, PRIME, stateTic } from "../src/sim/felts.js";
import { InputJournal } from "../src/game/inputJournal.js";
import type { CairoBackend, SimIdentity, SimResponse } from "../src/sim/cairoProtocol.js";

const identity: SimIdentity = { version: 1, stateSchema: 2, snapshotSchema: 1, revision: "test",
  hashes: { wasm: "a".repeat(64), session: "b".repeat(64), genesis: "c".repeat(64), step: "d".repeat(64) } };
const state = (tic: number, viewMobj = 0): Uint8Array => {
  const fields: (number | bigint)[] = Array(46).fill(0);
  fields[0] = 0x48502e5354415445n; fields[1] = 2; fields[2] = 43; fields[3] = 0x45314d31; fields[4] = tic; fields[10] = viewMobj;
  return encodeFelts(fields);
};
function frame(tic: number, status = 0): Uint8Array {
  const words: (number | bigint)[] = Array(36).fill(0);
  words[0] = 1; words[1] = tic; words[2] = status;
  for (let i = 5; i <= 8; i++) words[i] = 1n << 32n;
  words[35] = tic;
  return encodeFelts(words);
}
class Backend implements CairoBackend {
  identity = identity;
  viewMobj = 0; tic = 0; steps = 0; calls = 0; restarts = 0; freed = false; fail = false;
  pending = false; interrupted = false; terminalAt = Infinity;
  initialize(initial?: Uint8Array) {
    this.tic = initial ? stateTic(initial) : 0;
    this.viewMobj = initial ? Number(decodeFelts(initial)[10]) : 0;
    this.steps = 0; this.fail = false;
    return { state: state(this.tic, this.viewMobj), frame: frame(this.tic), status: 0 };
  }
  advance() {
    if (this.fail) throw new Error("command/step limit; poisoned");
    this.calls++; this.pending = true;
    return this.interrupted ? 1 : this.resume();
  }
  resume() { if (this.pending) { this.tic++; this.steps += 100; this.pending = false; } return 0; }
  snapshot() { return frame(this.tic, this.status()); }
  status(): number { return this.tic >= this.terminalAt ? 1 : 0; }
  requestCheckpoint() { return 0; }
  checkpoint() { return state(this.tic, this.viewMobj); }
  restart(s: Uint8Array) { this.tic = stateTic(s); this.restarts++; this.steps = 0; }
  totalSteps() { return this.steps; }
  memoryBytes() { return 512 * 1024 * 1024; }
  free() { this.freed = true; }
}
function setup(backend = new Backend(), yieldTask?: () => Promise<void>) {
  const messages: SimResponse[] = [];
  const controller = new CairoController(async () => backend, (m, transfers) => {
    // Actually detach each outgoing buffer, as a Worker does.
    messages.push(structuredClone(m, { transfer: transfers }));
  }, yieldTask);
  return { controller, messages, backend };
}

function clientPort(backend = new Backend()) {
  let receive: ((event: MessageEvent<SimResponse>) => void) | undefined;
  const controller = new CairoController(async () => backend, (response, transfer) => {
    const copy = structuredClone(response, { transfer });
    queueMicrotask(() => receive?.({ data: copy } as MessageEvent<SimResponse>));
  });
  const client = new CairoClient({
    addEventListener(type: string, callback: unknown) {
      if (type === "message") receive = callback as typeof receive;
    },
    postMessage(message, transfer) {
      const copy = structuredClone(message, { transfer });
      queueMicrotask(() => { void controller.handle(copy); });
    },
    terminate() { void controller.handle({ type: "dispose", id: 99999 }); },
  });
  return { client, backend };
}

describe("Cairo Worker protocol", () => {
  it("publishes genesis at tic zero without consuming an input, and requires resume", async () => {
    const { controller: c, messages: m, backend: b } = setup();
    await c.handle({ type: "init", id: 1 });
    expect(b.calls).toBe(0); expect(m[0]).toMatchObject({ type: "ready", tic: 0, transport: "arraybuffer" });
    await c.handle({ type: "advance", id: 2, seq: 0, word: 0x808080 });
    expect(m.at(-1)).toMatchObject({ code: "paused", fatal: false });
    await c.handle({ type: "resume", id: 3 });
    await c.handle({ type: "advance", id: 4, seq: 1, word: 0x808080 });
    expect(m.at(-1)).toMatchObject({ code: "order" });
    await c.handle({ type: "advance", id: 5, seq: 0, word: -1 });
    expect(m.at(-1)).toMatchObject({ code: "invalid" });
    await c.handle({ type: "advance", id: 6, seq: 0, word: 0x808080 });
    expect(m.at(-1)).toMatchObject({ type: "frame", tic: 1, seq: 0 });
    expect(b.calls).toBe(1);
  });
  it("rejects busy commands, pauses an interrupted tic, then acknowledges it exactly once", async () => {
    let release!: () => void;
    const { controller: c, messages: m, backend: b } = setup(new Backend(), () => new Promise(resolve => { release = resolve; }));
    b.interrupted = true;
    await c.handle({ type: "init", id: 0 }); await c.handle({ type: "resume", id: 1 });
    const pending = c.handle({ type: "advance", id: 2, seq: 0, word: 0 });
    await c.handle({ type: "advance", id: 3, seq: 1, word: 1 });
    expect(m.at(-1)).toMatchObject({ code: "busy" });
    await c.handle({ type: "restart", id: 4 }); expect(m.at(-1)).toMatchObject({ code: "busy" });
    await c.handle({ type: "pause", id: 5 }); release(); await Promise.resolve();
    expect(b.tic).toBe(0);
    await c.handle({ type: "resume", id: 6 }); await pending;
    expect(b.tic).toBe(1); expect(m.filter(x => x.type === "frame")).toHaveLength(1);
    await c.handle({ type: "advance", id: 7, seq: 0, word: 0 }); expect(m.at(-1)).toMatchObject({ code: "order" });
  });
  it("exports exact boundaries, compacts at 32, stops terminal inputs, restarts cleanly", async () => {
    const { controller: c, messages: m, backend: b } = setup(); b.terminalAt = 33;
    await c.handle({ type: "init", id: 0 }); await c.handle({ type: "resume", id: 1 });
    for (let seq = 0; seq < 33; seq++) await c.handle({ type: "advance", id: seq + 2, seq, word: seq });
    expect(b.restarts).toBe(2);
    const frames = m.filter((x): x is Extract<SimResponse, { type: "frame" }> => x.type === "frame");
    expect(stateTic(new Uint8Array(frames[31]!.state!))).toBe(32);
    await c.handle({ type: "advance", id: 90, seq: 33, word: 0 }); expect(m.at(-1)).toMatchObject({ code: "terminal" });
    await c.handle({ type: "checkpoint", id: 91 }); expect(m.at(-1)).toMatchObject({ type: "checkpoint", tic: 33 });
    await c.handle({ type: "restart", id: 92 }); expect(m.at(-1)).toMatchObject({ type: "ready", tic: 0 });
  });
  it("poisons after execution errors and can restart from a checkpoint", async () => {
    const { controller: c, messages: m, backend: b } = setup();
    await c.handle({ type: "init", id: 0 }); await c.handle({ type: "resume", id: 1 }); b.fail = true;
    await c.handle({ type: "advance", id: 2, seq: 0, word: 0 }); expect(m.at(-1)).toMatchObject({ code: "execution", fatal: true });
    await c.handle({ type: "advance", id: 3, seq: 0, word: 0 }); expect(m.at(-1)).toMatchObject({ code: "uninitialized" });
    await c.handle({ type: "restart", id: 4, state: state(40).buffer as ArrayBuffer });
    await c.handle({ type: "resume", id: 5 }); await c.handle({ type: "advance", id: 6, seq: 0, word: 0 });
    expect(m.at(-1)).toMatchObject({ type: "frame", tic: 41 });
  });
  it("disposal cancels a suspended operation without an obsolete response", async () => {
    let release!: () => void;
    const { controller: c, messages: m, backend: b } = setup(new Backend(), () => new Promise(resolve => { release = resolve; }));
    b.interrupted = true;
    await c.handle({ type: "init", id: 0 }); await c.handle({ type: "resume", id: 1 });
    const pending = c.handle({ type: "advance", id: 2, seq: 0, word: 0 });
    await c.handle({ type: "dispose", id: 3 }); release(); await pending;
    expect(b.freed).toBe(true); expect(m.at(-1)).toMatchObject({ type: "disposed" });
    expect(m.some(x => x.id === 2)).toBe(false);
  });
});

describe("raw Cairo outputs and input journal", () => {
  it("rejects noncanonical/truncated felts and translates Fixed.enc without truncation", () => {
    expect(() => decodeFelts(new Uint8Array(31))).toThrow();
    expect(() => encodeFelts([PRIME])).toThrow();
    const words = decodeFelts(frame(5)); words[5] = (1n << 32n) - 65536n;
    expect(decodeCairoSnapshot(encodeFelts(words)).snapshot.player.x).toBe(-65536);
    words[5] = 1n; expect(() => decodeCairoSnapshot(encodeFelts(words))).toThrow();
  });
  it("retains sprite/state/flags and never aliases CORPSE to TELEPORTED", () => {
    const words = decodeFelts(frame(0)); words[3] = 1n;
    words.push(...[7n, 3004n, 123n, 4n, 2n, 31n, 1n << 32n, 1n << 32n, 1n << 32n, 0n, 0n]);
    const decoded = decodeCairoSnapshot(encodeFelts(words));
    expect(decoded.actors[0]).toEqual({ id: 7, state: 123, sprite: 4, flags: 31 });
    expect(decoded.snapshot.mobjs[0]!.flags).toBe(7);
    expect(() => decodeCairoSnapshot(encodeFelts([...words, 0]))).toThrow();
  });
  it("journals the first tic, validates order, exports/imports and supplies arbitrary replay boundaries", () => {
    const journal = new InputJournal(identity, state(0));
    for (let i = 0; i < 35; i++) {
      journal.record(i, 0x808080 + i, i + 1);
      if (i === 31) journal.checkpoint(state(32));
    }
    expect(journal.boundary(0, 1).words).toEqual([0x808080]);
    expect(journal.boundary(34)).toMatchObject({ stateTic: 32, prefix: [0x8080a0, 0x8080a1], words: [0x8080a2] });
    expect(journal.boundary(5, 8).prefix).toHaveLength(5);
    expect(() => journal.record(0, 0, 36)).toThrow();
    const data = JSON.parse(JSON.stringify(journal.export()));
    expect(InputJournal.import(data).export()).toEqual(data);
    data.inputs.push("0x0"); expect(() => InputJournal.import(data)).toThrow();
  });
});

describe("main-thread Worker client", () => {
  it("bounds inputs and checkpoint operations before posting to the Worker", async () => {
    const { client, backend } = clientPort();
    await client.init(); expect(client.journal!.length).toBe(0);
    await client.resume();
    const input = client.advance(0x808080);
    const otherInput = client.advance(1), whileBusy = client.checkpoint();
    await Promise.all([expect(otherInput).rejects.toThrow("not ready"), expect(whileBusy).rejects.toThrow("busy")]);
    await input;
    expect(client.journal!.boundary(0, 1).words).toEqual([0x808080]);
    const checkpoint = client.checkpoint();
    await expect(client.advance(1)).rejects.toThrow("not ready");
    await checkpoint;
    expect(backend.calls).toBe(1); client.dispose();
    await expect(client.init()).rejects.toThrow("disposed");
  });
  it("keeps the validated camera actor on restart/restore, including nonzero ids", async () => {
    const { client } = clientPort(); await client.init(undefined, state(40, 9));
    expect(client.viewMobjId).toBe(9); await client.resume(); await client.advance(0x808080);
    await client.checkpoint();
    const saved = client.journal!.export();
    await client.restart(); expect(client.viewMobjId).toBe(0);
    await client.restore(saved); expect(client.viewMobjId).toBe(9);
    expect(client.journal!.ticEnd).toBe(41); client.dispose();
  });
  it("refuses a foreign journal identity before any init, leaving the live VM and journal untouched", async () => {
    const backend = new Backend(), initialize = backend.initialize.bind(backend), loads: (Uint8Array | undefined)[] = [];
    backend.initialize = (initial?: Uint8Array) => { loads.push(initial); return initialize(initial); };
    const { client } = clientPort(backend); await client.init(); await client.resume();
    for (let i = 0; i < 3; i++) await client.advance(i);
    await client.pause();
    const journal = client.journal!, loaded = structuredClone(client.loadedIdentity), tic = client.latest!.snapshot.tic;
    const foreign = journal.export();
    foreign.identity = { ...foreign.identity, hashes: { ...foreign.identity.hashes, wasm: "e".repeat(64) } };
    await expect(client.restore(foreign)).rejects.toThrow("identity differs");
    expect(loads).toHaveLength(1); expect(backend.restarts).toBe(0);
    expect(client.journal).toBe(journal); expect(journal.length).toBe(3);
    expect(client.loadedIdentity).toEqual(loaded); expect(client.latest!.snapshot.tic).toBe(tic);
    await client.resume(); await client.advance(3); expect(client.journal!.length).toBe(4);
    client.dispose();
    // A client with nothing loaded learns the identity at genesis and never loads the foreign checkpoint.
    const fresh = new Backend(), freshInit = fresh.initialize.bind(fresh), freshLoads: (Uint8Array | undefined)[] = [];
    fresh.initialize = (initial?: Uint8Array) => { freshLoads.push(initial); return freshInit(initial); };
    const other = clientPort(fresh).client;
    await expect(other.restore(foreign)).rejects.toThrow("identity differs");
    expect(freshLoads).toEqual([undefined]); expect(fresh.restarts).toBe(0);
    expect(other.journal!.length).toBe(0); expect(other.journal!.ticEnd).toBe(0);
    other.dispose();
  });
  it("a late resume acknowledgement cannot undo a newer pause", async () => {
    const { client } = clientPort(); await client.init();
    const resume = client.resume(), pause = client.pause();
    await Promise.all([resume, pause]);
    expect(client.paused).toBe(true); client.dispose();
  });
  it("restores checkpoint + suffix with a new wire sequence and keeps the complete journal", async () => {
    const { client } = clientPort();
    await client.init(); await client.resume();
    for (let i = 0; i < 35; i++) await client.advance(i);
    const exported = client.journal!.export(); client.dispose();
    const other = clientPort().client;
    await other.restore(JSON.parse(JSON.stringify(exported)));
    expect(other.journal!.length).toBe(35); expect(other.latest!.snapshot.tic).toBe(35);
    expect(other.paused).toBe(true);
    await other.resume(); await other.advance(35);
    expect(other.journal!.boundary(0).words).toEqual(Array.from({ length: 36 }, (_, i) => i));
    other.dispose();
  });
  it("keeps an unchanged Cairo ABORT distinct from a consumed tic, including export/reload", async () => {
    const backend = new Backend();
    backend.advance = () => { backend.calls++; return 0; };
    backend.status = () => 3;
    backend.snapshot = () => frame(backend.tic, 0);
    const client = clientPort(backend).client;
    await client.init(); await client.resume();
    const response = await client.advance(0x808080);
    expect(response).toMatchObject({ consumed: false, status: 3, tic: 0 });
    expect(client.journal!.length).toBe(0); expect(client.status).toBe(3);
    expect(client.latest!.status).toBe(0); expect(client.terminal).toBe(true);
    const exported = client.journal!.export(); client.dispose();
    expect(exported.rejected).toEqual({ word: 0x808080, tic: 0, status: 3 });
    const next = clientPort().client;
    await next.restore(exported);
    expect(next.terminal).toBe(true); expect(next.status).toBe(3);
    await next.resume(); await expect(next.advance(1)).rejects.toThrow("not ready");
    next.dispose();
  });
});

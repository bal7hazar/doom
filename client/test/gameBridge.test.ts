import { describe, it, expect, vi } from "vitest";
import { GameProofBridge } from "../src/prove/gameBridge.js";
import type { InputJournal } from "../src/game/inputJournal.js";
import type { DoomProgram, DoomProgramOptions } from "../src/prove/doomProgram.js";
import type { ProveSession } from "../src/prove/session.js";
const journal = (tag: string) => ({ export: () => ({ tag }), length: 0 } as unknown as InputJournal);
const program = () => ({ dispose: vi.fn() } as unknown as DoomProgram);
function session(id: string) {
  return { cancelVerification: vi.fn(), element: { remove: vi.fn() }, pipeline: { state: { runId: id }, stop: vi.fn(async () => {}), syncGameJournal: vi.fn(async () => {}) },
    dispose: vi.fn(async () => {}) } as unknown as ProveSession;
}
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }
describe("real game proof bridge lifecycle", () => {
  it("does no preparation before F4 and captures each journal object across restart", async () => {
    const sources: DoomProgramOptions[] = [], archived = vi.fn();
    const bridge = new GameProofBridge({ createProgram: async o => { sources.push(o); return program(); },
      createSession: async () => session(String(sources.length)), notify: vi.fn(), archived });
    const first = journal("first"), next = journal("next");
    bridge.observe(first); expect(sources).toHaveLength(0);
    await bridge.open(); await bridge.sync(); bridge.observe(next); await bridge.open();
    expect(sources[0]!.journal!()).toEqual({ tag: "first" });
    expect(sources[1]!.journal!()).toEqual({ tag: "next" });
    expect(archived).toHaveBeenCalledWith({ journal: first, runId: "1" });
    await bridge.dispose();
  });
  it("deduplicates simultaneous opens and releases a programme resolved after restart", async () => {
    const deferredProgram = deferred<DoomProgram>(), p = program(), createSession = vi.fn(async () => session("one"));
    let signal: AbortSignal | undefined;
    const createProgram = vi.fn((o: DoomProgramOptions) => { signal = o.signal; return deferredProgram.promise; });
    const bridge = new GameProofBridge({ createProgram, createSession, notify: vi.fn() });
    bridge.observe(journal("first")); const a = bridge.open(), b = bridge.open();
    await Promise.resolve(); expect(createProgram).toHaveBeenCalledTimes(1);
    bridge.observe(journal("second")); expect(signal!.aborted).toBe(true);
    deferredProgram.resolve(p); await Promise.all([a, b]);
    expect(p.dispose).toHaveBeenCalledOnce(); expect(createSession).not.toHaveBeenCalled(); await bridge.dispose();
  });
  it("disposes a session that finishes creating after BFCache suspension", async () => {
    const pending = deferred<ProveSession>(), s = session("old"), started = deferred<void>();
    const bridge = new GameProofBridge({ createProgram: async () => program(),
      createSession: () => { started.resolve(); return pending.promise; }, notify: vi.fn() });
    bridge.observe(journal("same")); const opening = bridge.open(); await started.promise;
    bridge.suspend(); pending.resolve(s); await opening;
    expect(s.dispose).toHaveBeenCalledOnce(); expect(bridge.session).toBeUndefined(); await bridge.dispose();
  });
  it("recovers from initialization failure without replacing the captured journal", async () => {
    const notify = vi.fn(), createProgram = vi.fn().mockRejectedValueOnce(new Error("missing asset")).mockResolvedValueOnce(program());
    const bridge = new GameProofBridge({ createProgram, createSession: async () => session("retry"), notify });
    const j = journal("retained"); bridge.observe(j); expect(await bridge.open()).toBeUndefined();
    expect(notify).toHaveBeenCalledWith(expect.stringContaining("can still be exported"));
    expect(await bridge.open()).toBeDefined(); expect(bridge.currentRun!.journal).toBe(j); await bridge.dispose();
  });
  it("flushes the retired run before closing it and reattaches its id explicitly", async () => {
    const s = session("persisted"), createSession = vi.fn(async (_program: DoomProgram, _runId?: string) => s);
    const bridge = new GameProofBridge({ createProgram: async () => program(), createSession, notify: vi.fn() });
    bridge.observe(journal("a")); await bridge.open(); const archived = bridge.currentRun!;
    bridge.observe(journal("b")); bridge.select(archived); await bridge.open();
    expect(s.pipeline.syncGameJournal).toHaveBeenCalled(); expect(s.dispose).toHaveBeenCalled();
    expect(createSession.mock.calls[1]![1]).toBe("persisted"); await bridge.dispose();
  });
  it("retires a session with one hard stop, then the journal copy, then dispose, in that order", async () => {
    const order: string[] = [], stopped = deferred<void>(), synced = deferred<void>();
    const s = session("ordered");
    vi.mocked(s.pipeline.stop).mockImplementation(async hard => { order.push(`stop(${String(hard)})`); await stopped.promise; });
    vi.mocked(s.pipeline.syncGameJournal).mockImplementation(async () => { order.push("sync"); await synced.promise; });
    vi.mocked(s.dispose).mockImplementation(async () => { order.push("dispose"); });
    const notify = vi.fn();
    const bridge = new GameProofBridge({ createProgram: async () => program(), createSession: async () => s, notify });
    bridge.observe(journal("a")); await bridge.open();
    bridge.suspend(); bridge.suspend(); // retiring twice cannot stop or dispose twice
    expect(order).toEqual(["stop(true)"]); expect(bridge.session).toBeUndefined();
    await Promise.resolve(); await Promise.resolve(); expect(order).toEqual(["stop(true)"]);
    stopped.resolve(); await vi.waitFor(() => expect(order).toEqual(["stop(true)", "sync"]));
    expect(s.dispose).not.toHaveBeenCalled();
    synced.resolve(); await bridge.settle();
    expect(order).toEqual(["stop(true)", "sync", "dispose"]);
    expect(s.pipeline.stop).toHaveBeenCalledOnce(); expect(s.dispose).toHaveBeenCalledOnce();
    expect(notify).not.toHaveBeenCalledWith(expect.stringContaining("retained"));
    await bridge.dispose(); expect(s.dispose).toHaveBeenCalledOnce();
  });
  it("still copies the journal and disposes when the hard stop fails to persist", async () => {
    const order: string[] = [], s = session("failing"), notify = vi.fn();
    vi.mocked(s.pipeline.stop).mockImplementation(async () => { order.push("stop"); throw new Error("IndexedDB unavailable"); });
    vi.mocked(s.pipeline.syncGameJournal).mockImplementation(async () => { order.push("sync"); });
    vi.mocked(s.dispose).mockImplementation(async () => { order.push("dispose"); });
    const bridge = new GameProofBridge({ createProgram: async () => program(), createSession: async () => s, notify });
    bridge.observe(journal("a")); await bridge.open(); await bridge.dispose();
    expect(order).toEqual(["stop", "sync", "dispose"]);
    expect(notify).toHaveBeenCalledWith(expect.stringContaining("IndexedDB unavailable"));
  });
  it("coalesces overlapping acknowledged journal synchronization", async () => {
    const s = session("id"), done = deferred<void>();
    vi.mocked(s.pipeline.syncGameJournal).mockReturnValueOnce(done.promise);
    const bridge = new GameProofBridge({ createProgram: async () => program(), createSession: async () => s, notify: vi.fn() });
    bridge.observe(journal("a")); await bridge.open(); const sync = bridge.sync(); await bridge.sync();
    expect(s.pipeline.syncGameJournal).toHaveBeenCalledOnce(); done.resolve(); await sync; await bridge.dispose();
  });
});

it("closes program, UI and storage even if final journal persistence fails", async () => {
  const { ProveSession } = await import("../src/prove/session.js");
  const p = program(), remove = vi.fn(), close = vi.fn();
  const s = Object.assign(Object.create(ProveSession.prototype), {
    pipeline: { stop: vi.fn(async () => { throw new Error("IndexedDB unavailable"); }) },
    options: { program: p }, panel: { element: { remove } }, store: { close },
  }) as ProveSession;
  await expect(s.dispose()).rejects.toThrow("IndexedDB unavailable");
  expect(p.dispose).toHaveBeenCalledOnce(); expect(remove).toHaveBeenCalledOnce(); expect(close).toHaveBeenCalledOnce();
});

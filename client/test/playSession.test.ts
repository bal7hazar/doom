// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { PlaySession, gameOutcome } from "../src/game/playSession.js";
import { InputJournal } from "../src/game/inputJournal.js";
import { SavedGameStore } from "../src/game/savedGame.js";
import { decodeCmd } from "../src/prove/ticcmd.js";
import { encodeFelts } from "../src/sim/felts.js";
import type { CairoClient } from "../src/sim/cairoClient.js";
import type { CairoScheduler } from "../src/sim/cairoScheduler.js";

const sessions: PlaySession[] = [];
afterEach(() => { sessions.splice(0).forEach(s => s.input.dispose()); vi.restoreAllMocks(); document.body.innerHTML = ""; });
const state = (tic = 0) => encodeFelts([0x48502e5354415445n, 2, 3, 0x45314d31, tic, 0]);
function setup() {
  const journal = new InputJournal({ version: 1, stateSchema: 2, snapshotSchema: 1, revision: "test",
    hashes: { wasm: "a".repeat(64), session: "b".repeat(64), genesis: "c".repeat(64), step: "d".repeat(64) } }, state());
  const client = { journal, paused: true, terminal: false, status: 0, busy: false,
    pause: vi.fn(async () => { client.paused = true; }),
    resume: vi.fn(async () => { client.paused = false; }),
    checkpoint: vi.fn(async () => { const value = state(client.journal.ticEnd); client.journal.checkpoint(value); return value; }),
    restart: vi.fn(async () => {}), restore: vi.fn(async () => {}),
  };
  const scheduler = { isRunning: false, start: vi.fn(() => { scheduler.isRunning = true; }), stop: vi.fn(() => { scheduler.isRunning = false; }) };
  const canvas = document.createElement("canvas"); document.body.append(canvas);
  canvas.requestPointerLock = vi.fn(async () => {});
  const session = new PlaySession(client as unknown as CairoClient, scheduler as unknown as CairoScheduler, canvas, document.body);
  sessions.push(session);
  const click = (name: string) => (Array.from(session.element.querySelectorAll("button")).find(b => b.textContent === name)!).click();
  return { session, client, scheduler, canvas, click };
}

describe("user session operations", () => {
  it("starts only on request and refuses resume while saving the last acknowledged input", async () => {
    const save = vi.spyOn(SavedGameStore.prototype, "save").mockResolvedValue();
    const { session, client, scheduler, click } = setup();
    expect(scheduler.start).not.toHaveBeenCalled();
    session.start(); expect(scheduler.start).toHaveBeenCalledTimes(1);
    client.busy = true;
    client.resume.mockImplementation(async () => {
      client.journal.record(0, 0x808099, 1); client.busy = false;
    });
    click("Save"); session.start();
    await vi.waitFor(() => expect(save).toHaveBeenCalledOnce());
    expect(scheduler.start).toHaveBeenCalledTimes(1);
    expect(client.journal.length).toBe(1);
    expect(save.mock.calls[0]![0]).toEqual(client.journal.export());
    expect(client.paused).toBe(true);
  });
  it("keeps keys pressed during resume and releases a late pointer acquisition after pause", async () => {
    const { session, canvas, client } = setup();
    let resolve!: () => void;
    canvas.requestPointerLock = vi.fn(() => new Promise<void>(done => { resolve = done; }));
    Object.defineProperty(document, "pointerLockElement", { configurable: true, get: () => null });
    const lock = vi.spyOn(document, "pointerLockElement", "get");
    document.exitPointerLock = vi.fn();
    session.start();
    expect(client.paused).toBe(true); // Worker resume acknowledgement has not arrived.
    window.dispatchEvent(new KeyboardEvent("keydown", { code: "KeyW" }));
    expect(decodeCmd(session.input.sample()).forward).toBe(25);
    session.pause();
    lock.mockReturnValue(canvas); resolve();
    await Promise.resolve();
    expect(document.exitPointerLock).toHaveBeenCalled();
    lock.mockReturnValue(null);
  });
  it("reports a storage quota failure without replacing the live journal", async () => {
    vi.spyOn(SavedGameStore.prototype, "save").mockRejectedValue(new Error("QuotaExceededError"));
    const { session, client, click } = setup(); const original = client.journal;
    click("Save");
    await vi.waitFor(() => expect(session.element.textContent).toContain("QuotaExceededError"));
    expect(client.journal).toBe(original);
    expect(session.element.textContent).not.toContain("Current position saved");
  });
  it("rejects a mismatched identity before reinitializing the Worker", async () => {
    const { session, client, click } = setup();
    const data = client.journal.export(); data.identity.hashes.session = "f".repeat(64);
    vi.spyOn(SavedGameStore.prototype, "load").mockResolvedValue(data);
    click("Load save");
    await vi.waitFor(() => expect(session.element.textContent).toContain("different game version"));
    expect(client.restore).not.toHaveBeenCalled(); expect(client.journal.length).toBe(0);
  });
  it("bounds replay before touching the Worker", async () => {
    const { session, client, click } = setup();
    const imported = InputJournal.import(client.journal.export());
    for (let i = 0; i < 257; i++) imported.record(i, 0x808080, i + 1);
    vi.spyOn(SavedGameStore.prototype, "load").mockResolvedValue(imported.export());
    click("Load save");
    await vi.waitFor(() => expect(session.element.textContent).toContain("too much replay"));
    expect(client.restore).not.toHaveBeenCalled();
  });
  it("can restart after an unusable VM rejects pause", async () => {
    const { client, click } = setup(); client.pause.mockRejectedValue(new Error("uninitialized"));
    click("Restart"); await vi.waitFor(() => expect(client.restart).toHaveBeenCalledOnce());
  });
  it("uses the actual operation status for each terminal screen", () => {
    expect([1, 2, 3].map(gameOutcome)).toEqual(["You died", "Level complete", "Run stopped"]);
    const { session, client } = setup(); client.terminal = true; client.status = 3; session.refresh();
    expect(session.element.querySelector("h1")!.textContent).toBe("Run stopped");
    expect(Array.from(session.element.querySelectorAll("button")).find(b => b.textContent === "Start")!.disabled).toBe(true);
  });
});

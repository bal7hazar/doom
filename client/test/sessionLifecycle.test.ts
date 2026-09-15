import { expect, it, vi } from "vitest";
import { ProveSession } from "../src/prove/session.js";
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }
function session(chain: Promise<unknown> = Promise.resolve({ ok: true, tics: 1 })) {
  return Object.assign(Object.create(ProveSession.prototype), {
    disposed: false, verifying: false, verificationEpoch: 0, run: { id: "run" },
    options: { program: { dispose: vi.fn() }, proverWorkerUrl: "fake://worker" },
    panel: { log: vi.fn(), element: { remove: vi.fn() } },
    pipeline: { verifyPersistedChain: () => chain, stop: vi.fn(async () => {}) },
    store: { listSegments: async () => [{ index: 0 }], getProof: async () => new Uint8Array([1]), close: vi.fn() },
  }) as ProveSession;
}
it.each(["init", "verify"])("dispose immediately terminates local verification during %s", async blocked => {
  const started = deferred<void>(); const instances: FakeWorker[] = [];
  class FakeWorker {
    readonly listeners: Record<string, (value: unknown) => void> = {};
    terminated = false;
    constructor() { instances.push(this); }
    addEventListener(name: string, callback: (value: unknown) => void) { this.listeners[name] = callback; }
    postMessage(message: { op: string; id: number }) {
      if (message.op === blocked) { started.resolve(); return; }
      if (message.op === "init") queueMicrotask(() => this.listeners.message!({ data: { id: message.id, ok: true, op: "init", info: { threads: 1, memoryBytes: 0 } } }));
    }
    terminate() { this.terminated = true; }
  }
  vi.stubGlobal("Worker", FakeWorker);
  try {
    const s = session(), verifying = s.verifyLocally(); await started.promise;
    expect(await s.verifyLocally()).toBe(false); expect(instances).toHaveLength(1);
    await s.dispose();
    expect(instances[0]!.terminated).toBe(true);
    expect(await verifying).toBe(false);
    expect(await s.verifyLocally()).toBe(false); expect(instances).toHaveLength(1);
  } finally { vi.unstubAllGlobals(); }
});
it("does not construct a verifier if disposal races the persisted chain lookup", async () => {
  const pending = deferred<unknown>(), Worker = vi.fn(); vi.stubGlobal("Worker", Worker);
  try {
    const s = session(pending.promise), verifying = s.verifyLocally(); await s.dispose();
    pending.resolve({ ok: true, tics: 1 }); expect(await verifying).toBe(false); expect(Worker).not.toHaveBeenCalled();
  } finally { vi.unstubAllGlobals(); }
});

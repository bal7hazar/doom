import "fake-indexeddb/auto";
import { IDBFactory } from "fake-indexeddb";
import { describe, expect, it } from "vitest";
import { createStubProgram } from "../src/prove/program.js";
import { ProofPipeline } from "../src/prove/pipeline.js";
import { RunStore } from "../src/store/runStore.js";

// The runtime hash identifies the task; it must reach new records without migrating old ones.
describe("stub program runtime identity (D31)", () => {
  it("records Blake on a new run and preserves full felt precision", async () => {
    globalThis.indexedDB = new IDBFactory();
    const store = await RunStore.open("program-new");
    try {
      const genesis = "0x20000000000001";
      const program = createStubProgram({ genesis });
      const pipeline = new ProofPipeline({ store, program, proverWorkerUrl: "unused" });
      const run = await pipeline.attach();
      expect(program.hashFunction).toBe("blake");
      expect(run.programHashFunction).toBe("blake");
      expect(run.genesis).toBe(genesis);
      expect((await store.getRun(run.id))?.programHashFunction).toBe("blake");
      expect(program.encodeArgs({ hIn: genesis, ticStart: 0, ticCount: 1, words: [0], index: 0 })[0])
        .toBe(genesis);
    } finally { store.close(); }
  });

  it("does not rewrite an existing persisted run's hash metadata", async () => {
    globalThis.indexedDB = new IDBFactory();
    const store = await RunStore.open("program-existing");
    try {
      const existing = await store.createRun({
        id: "old-poseidon", program: "segment_stub10", programHashFunction: "poseidon", genesis: "0x1",
      });
      const before = await store.getRun(existing.id);
      const pipeline = new ProofPipeline({ store, program: createStubProgram(), proverWorkerUrl: "unused" });
      const resumed = await pipeline.attach(existing.id);
      expect(resumed.programHashFunction).toBe("poseidon");
      expect(await store.getRun(existing.id)).toEqual(before);
    } finally { store.close(); }
  });
});

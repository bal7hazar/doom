import "fake-indexeddb/auto";
import { IDBFactory } from "fake-indexeddb";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type {
  ExecutionStats,
  ProofStats,
  ProverInfo,
  ResourceSummary,
} from "@hellproof/prover-wasm";
import { ProofPipeline } from "../src/prove/pipeline.js";
import { nextPow2 } from "../src/prove/planner.js";
import type { SegmentProgram, SegmentRequest } from "../src/prove/program.js";
import { ProverTimeoutError, type ProverLike } from "../src/prove/proverClient.js";
import { toFelt } from "../src/prove/felt.js";
import { RunStore } from "../src/store/runStore.js";
import type { Felt, PipelineEvent } from "../src/prove/types.js";

/**
 * A fake segment engine: `h_out = h_in + n_tics`, `steps = 100 000 + 500·K`,
 * largest component `1 000 + 1 000·K` rows. Affine in K like the real thing, so
 * the planner's model has something to fit, and cheap enough to run hundreds of
 * times in a unit test.
 */
const FIXED_STEPS = 100_000;
const STEPS_PER_TIC = 500;
const ROWS_BASE = 1_000;
const ROWS_PER_TIC = 1_000;

interface FakeProverOptions {
  /** Segment indices whose first `prove()` hangs past its deadline (R1-A8). */
  hangOn?: Set<number>;
  /** Segment indices whose every `prove()` fails. */
  failOn?: Set<number>;
  legacySizing?: boolean;
  rowsPerTic?: number;
  stepsPerTic?: number;
}

class FakeProver implements ProverLike {
  isDead = false;
  peakMemoryBytes = 3 * 2 ** 30;
  static executes = 0;
  static proves = 0;
  static instances = 0;
  static terminations = 0;
  private threads = 1;

  constructor(private readonly options: FakeProverOptions & { seen: Set<number> }) {
    FakeProver.instances++;
  }

  async init(opts: { threads?: number | "auto" } = {}): Promise<ProverInfo> {
    this.threads = typeof opts.threads === "number" ? opts.threads : 4;
    return {
      threads: this.threads,
      threaded: this.threads > 1,
      crossOriginIsolated: true,
      wasmUrl: "fake://prover",
      instantiateMs: 1,
      memoryBytes: 2 ** 25,
    };
  }

  async execute(
    _executable: string,
    args: Felt[] | string,
  ): Promise<{ input: Uint8Array; stats: ExecutionStats; ms: number }> {
    FakeProver.executes++;
    const felts = args as Felt[];
    const hIn = BigInt(felts[0] as string);
    const ticStart = Number(BigInt(felts[1] as string));
    const nTics = Number(BigInt(felts[2] as string));
    const stats: ExecutionStats = {
      n_steps: FIXED_STEPS + (this.options.stepsPerTic ?? STEPS_PER_TIC) * nTics,
      builtins: [],
      output: ["0xaaaa", "0xbbbb"],
      output_preimage: [
        "0xdead",
        toFelt(1),
        toFelt(hIn),
        toFelt(hIn + BigInt(nTics)),
        toFelt(ticStart),
        toFelt(ticStart + nTics),
        toFelt(0),
        toFelt(0xc0),
        toFelt(0),
        toFelt(0),
        toFelt(0),
      ],
      prover_input_bytes: 64,
    };
    // The input carries the segment length, so `resources()` can answer without
    // sharing state with this call.
    const input = new Uint8Array(8);
    new DataView(input.buffer).setUint32(0, nTics, true);
    new DataView(input.buffer).setUint32(4, ticStart, true);
    return { input, stats, ms: 1 };
  }

  async resources(input: Uint8Array): Promise<ResourceSummary> {
    const nTics = new DataView(input.buffer, input.byteOffset).getUint32(0, true);
    const rows = ROWS_BASE + (this.options.rowsPerTic ?? ROWS_PER_TIC) * nTics;
    const maxRows = nextPow2(rows);
    return {
      n_steps: FIXED_STEPS + (this.options.stepsPerTic ?? STEPS_PER_TIC) * nTics,
      opcodes: [["add_opcode", rows]],
      builtins: [],
      unique_aggregator_inputs: [],
      ...(this.options.legacySizing ? {} : { auxiliary_components: [] }),
      memory_address_to_id: 16,
      memory_id_to_big: 1,
      memory_id_to_small: 1,
      verify_instruction: 1,
      max_component_rows: maxRows,
      max_component: "add_opcode",
      log_max_component_size: Math.log2(maxRows),
      fits_leaf_registry: maxRows <= 2 ** 20,
    };
  }

  async prove(input: Uint8Array): Promise<{ proof: Uint8Array; stats: ProofStats; ms: number }> {
    FakeProver.proves++;
    const ticStart = new DataView(input.buffer, input.byteOffset).getUint32(4, true);
    const index = ticStart; // the tests use one segment per distinct tic_start
    if (this.options.failOn?.has(index)) throw new Error("prover exploded");
    // The hang is the threaded path's (R1-A8); the single-threaded retry works.
    if (this.options.hangOn?.has(index) && this.threads > 1) {
      this.options.seen.add(index);
      this.isDead = true;
      throw new ProverTimeoutError("prove", 1);
    }
    return {
      proof: Uint8Array.from({ length: 128 }, (_, i) => (i + index) & 0xff),
      stats: {
        proof_bytes: 128,
        proof_felts: 755_500,
        trace_lifting_log_size: 21,
        preprocessed_lifting_log_size: 21,
        trace_log_size: 20,
        max_trace_component_log_size: 20,
        max_log_size: 20,
        component_log_sizes: [20],
      },
      ms: 1,
    };
  }

  async verify(): Promise<boolean> {
    return true;
  }

  terminate(): void {
    FakeProver.terminations++;
    this.isDead = true;
  }
}

/** The matching program: `(h_in, tic_start, n_tics)`. */
const fakeProgram: SegmentProgram = {
  id: "fake_segment",
  hashFunction: "poseidon",
  genesis: "0x1",
  executableJson: async () => "{}",
  encodeArgs: ({ hIn, ticStart, ticCount }: SegmentRequest) => [
    toFelt(hIn),
    toFelt(ticStart),
    toFelt(ticCount),
  ],
};

let store: RunStore;
let dbName: string;
let counter = 0;

function makePipeline(
  options: FakeProverOptions = {},
  over: Partial<ConstructorParameters<typeof ProofPipeline>[0]> = {},
): { pipeline: ProofPipeline; events: PipelineEvent[] } {
  const seen = new Set<number>();
  const events: PipelineEvent[] = [];
  const pipeline = new ProofPipeline({
    store,
    program: fakeProgram,
    proverWorkerUrl: "fake://worker",
    threads: 4,
    createProver: () => new FakeProver({ ...options, seen }),
    proveTimeoutMs: 1000,
    singleThreadProveTimeoutMs: 1000,
    schedule: (fn) => queueMicrotask(fn),
    onEvent: (event) => events.push(event),
    ...over,
  });
  return { pipeline, events };
}

const words = (n: number, from = 0): number[] =>
  Array.from({ length: n }, (_, i) => (from + i + 1) >>> 0);

beforeEach(async () => {
  globalThis.indexedDB = new IDBFactory();
  dbName = `hellproof-pipeline-${counter++}`;
  store = await RunStore.open(dbName);
  FakeProver.executes = 0;
  FakeProver.proves = 0;
  FakeProver.instances = 0;
  FakeProver.terminations = 0;
});

afterEach(() => {
  store.close();
});

describe("ProofPipeline", () => {
  it("stops before prove when the loaded artifact has incomplete AIR sizing", async () => {
    const { pipeline } = makePipeline({ legacySizing: true });
    const run = await pipeline.attach();
    await pipeline.appendTics(words(4));
    await pipeline.proveAll();
    expect(FakeProver.proves).toBe(0);
    expect(FakeProver.executes).toBe(1);
    expect(pipeline.state.error).toMatch(/update the prover artifacts/i);
    expect(await store.listSegments(run.id)).toHaveLength(0);
  });

  it.each([
    ["legacy sizing", { legacySizing: true }, /update the prover artifacts/i],
    ["larger current AIR", { rowsPerTic: 225_000 }, /row|registry/i],
    ["larger current step count", { stepsPerTic: 400_000 }, /step.*ceiling/i],
  ] as const)("rechecks a persisted segment against %s and preserves it for a valid retry", async (_label, options, reason) => {
    const initial = makePipeline({ failOn: new Set([0]) });
    const run = await initial.pipeline.attach();
    await initial.pipeline.appendTics(words(4));
    await initial.pipeline.proveAll();
    const original = await store.getSegment(run.id, 0);
    expect(original?.stage).toBe("failed");
    // Persist the boundary as if the tab closed after planning, before its first proof attempt.
    await store.putSegment({ ...original!, stage: "planned", attempts: 0, retriedSingleThread: false });
    FakeProver.proves = 0;
    FakeProver.executes = 0;

    const resumed = makePipeline(options);
    await resumed.pipeline.attach(run.id);
    await resumed.pipeline.proveAll();
    expect(FakeProver.proves).toBe(0);
    expect(FakeProver.executes).toBe(1); // admission failure must not fall back to another prove mode
    const rejected = await store.getSegment(run.id, 0);
    expect(rejected?.stage).toBe("failed");
    expect(rejected?.error).toMatch(reason);
    expect(rejected?.args).toEqual(original?.args);
    expect(await store.getProof(run.id, 0)).toBeUndefined();

    const updated = makePipeline();
    await updated.pipeline.attach(run.id);
    await updated.pipeline.proveAll();
    expect(FakeProver.proves).toBe(1);
    const accepted = await store.getSegment(run.id, 0);
    expect(accepted?.stage).toBe("proved");
    expect(accepted?.verified).toBe(true);
    expect(accepted?.args).toEqual(original?.args);
  });

  it("plans, proves, verifies, chains and persists a whole run", async () => {
    const { pipeline, events } = makePipeline({}, { planner: { initialTics: 100, maxTics: 100 } });
    const run = await pipeline.attach();
    await pipeline.appendTics(words(300));
    const chain = await pipeline.proveAll();

    expect(chain?.ok).toBe(true);
    expect(chain?.tics).toBe(300);
    const segments = await store.listSegments(run.id);
    expect(segments).toHaveLength(3);
    expect(segments.map((s) => [s.ticStart, s.ticEnd])).toEqual([
      [0, 100],
      [100, 200],
      [200, 300],
    ]);
    expect(segments.every((s) => s.stage === "proved" && s.verified)).toBe(true);
    for (const segment of segments) {
      expect((await store.getProof(run.id, segment.index))?.byteLength).toBe(128);
    }
    // h_out of one is h_in of the next, and the first starts at the genesis.
    expect(segments[0]?.output?.hIn).toBe("0x1");
    expect(segments[0]?.output?.hOut).toBe(segments[1]?.output?.hIn);
    expect(events.some((e) => e.type === "chain" && e.ok)).toBe(true);
  });

  it("probes with execute() and shrinks until resources() approves", async () => {
    // 1 000 rows/tic: 800 tics is 801 000 rows (76 % of 2^20) and fits; the
    // planner's first proposal of 2 000 does not.
    const { pipeline, events } = makePipeline({}, { planner: { initialTics: 2000, maxTics: 4000 } });
    const run = await pipeline.attach();
    await pipeline.appendTics(words(2000));
    await pipeline.proveAll();

    const segments = await store.listSegments(run.id);
    expect(segments[0]?.ticEnd).toBeLessThan(2000);
    expect(segments[0]?.resources?.utilisation).toBeLessThanOrEqual(0.8);
    expect(segments[0]?.resources?.fitsLeafRegistry).toBe(true);
    // At least one probe was rejected before the accepted one.
    expect(events.some((e) => e.type === "log" && /rejected/.test(e.message))).toBe(true);
    expect(FakeProver.executes).toBeGreaterThan(FakeProver.proves);
  });

  it("respects the R1-A8 step ceiling: 1.5 M steps with threads", async () => {
    // 500 steps/tic and no row pressure -> the step ceiling is what binds.
    const { pipeline } = makePipeline(
      { rowsPerTic: 1 },
      { planner: { initialTics: 5000, maxTics: 10_000 } },
    );
    const run = await pipeline.attach();
    await pipeline.appendTics(words(5000));
    await pipeline.proveAll();
    const segments = await store.listSegments(run.id);
    for (const segment of segments) {
      expect(segment.resources?.nSteps).toBeLessThanOrEqual(1_500_000);
    }
  });

  it("kills a hung threaded prove and retries it single-threaded (R1-A8)", async () => {
    const { pipeline, events } = makePipeline(
      { hangOn: new Set([0]) },
      { planner: { initialTics: 50, maxTics: 50 } },
    );
    const run = await pipeline.attach();
    await pipeline.appendTics(words(100));
    const chain = await pipeline.proveAll();

    expect(chain?.ok).toBe(true);
    const segments = await store.listSegments(run.id);
    expect(segments[0]?.retriedSingleThread).toBe(true);
    expect(segments[0]?.threads).toBe(1);
    expect(segments[0]?.attempts).toBe(2);
    // The second one was never in trouble.
    expect(segments[1]?.retriedSingleThread).toBe(false);
    expect(events.some((e) => e.type === "log" && /R1-A8/.test(e.message))).toBe(true);
  });

  it("marks a segment failed when even the single-threaded retry fails", async () => {
    const { pipeline } = makePipeline(
      { failOn: new Set([0]) },
      { planner: { initialTics: 50, maxTics: 50 } },
    );
    const run = await pipeline.attach();
    await pipeline.appendTics(words(50));
    await pipeline.proveAll();

    const segments = await store.listSegments(run.id);
    expect(segments[0]?.stage).toBe("failed");
    expect(segments[0]?.error).toMatch(/exploded/);
    expect(pipeline.state.error).toMatch(/could not be proved/);
  });

  it("drops the prover between segments so the wasm memory is released (R1-A7)", async () => {
    const { pipeline } = makePipeline({}, { planner: { initialTics: 50, maxTics: 50 } });
    await pipeline.attach();
    await pipeline.appendTics(words(150));
    await pipeline.proveAll();
    expect(FakeProver.terminations).toBeGreaterThanOrEqual(3);
  });

  it("re-queues unfinished segments after a reload, and keeps the proved ones", async () => {
    const runId = "resume-me";
    {
      const { pipeline } = makePipeline({}, { planner: { initialTics: 50, maxTics: 50 } });
      await pipeline.attach(runId);
      await pipeline.appendTics(words(100));
      await pipeline.proveAll();
    }
    // Simulate a tab that died mid-proof: segment 1 loses its proof and its stage.
    const half = await store.getSegment(runId, 1);
    await store.putSegment({ ...half!, stage: "proving", verified: false, proofBytes: 0 });

    // …and the page comes back.
    store.close();
    store = await RunStore.open(dbName);
    const { pipeline } = makePipeline({}, { planner: { initialTics: 50, maxTics: 50 } });
    await pipeline.attach(runId);
    expect(pipeline.state.total).toBe(2);
    expect(pipeline.state.proved).toBe(1);
    FakeProver.proves = 0;
    await pipeline.proveAll();

    // Exactly one segment was re-proved, and the journal was not re-cut.
    expect(FakeProver.proves).toBe(1);
    const segments = await store.listSegments(runId);
    expect(segments).toHaveLength(2);
    expect(segments.every((s) => s.stage === "proved")).toBe(true);
    expect((await pipeline.verifyPersistedChain()).ok).toBe(true);
  });

  it("waits for enough tics rather than cutting a short segment mid-game", async () => {
    const { pipeline } = makePipeline({}, { planner: { initialTics: 100, maxTics: 100 } });
    await pipeline.attach();
    await pipeline.appendTics(words(40));
    pipeline.start();
    await new Promise((r) => setTimeout(r, 60));
    expect(pipeline.state.total).toBe(0);

    // The rest of the segment arrives; now it cuts.
    await pipeline.appendTics(words(60, 40));
    await pipeline.proveAll();
    expect(pipeline.state.total).toBe(1);
    expect((await store.listSegments(pipeline.state.runId))[0]?.ticEnd).toBe(100);
  });

  it("cuts whatever is left once the game is over", async () => {
    const { pipeline } = makePipeline({}, { planner: { initialTics: 100, maxTics: 100 } });
    await pipeline.attach();
    await pipeline.appendTics(words(130));
    await pipeline.proveAll();
    const segments = await store.listSegments(pipeline.state.runId);
    expect(segments.map((s) => s.ticEnd)).toEqual([100, 130]);
  });

  it("persists the journal as packed felts while the game runs", async () => {
    const { pipeline } = makePipeline({}, { journalFlushTics: 7 });
    const run = await pipeline.attach();
    await pipeline.appendTics(words(20));
    const inputs = await store.getInputs(run.id);
    expect(inputs.ticCount).toBeGreaterThanOrEqual(14);
    expect(inputs.packed.length).toBeGreaterThanOrEqual(2);
    await pipeline.flushJournal();
    expect((await store.getInputs(run.id)).ticCount).toBe(20);
    expect((await store.getInputs(run.id)).tail).toHaveLength(20 % 7);
  });

  it("emits a segment event per boundary and progress events per stage", async () => {
    const { pipeline, events } = makePipeline({}, { planner: { initialTics: 50, maxTics: 50 } });
    await pipeline.attach();
    await pipeline.appendTics(words(100));
    await pipeline.proveAll();
    const stages = new Set(
      events.filter((e) => e.type === "progress").map((e) => (e as { stage: string }).stage),
    );
    expect(stages).toContain("executing");
    expect(stages).toContain("proving");
    expect(stages).toContain("verifying");
    expect(events.filter((e) => e.type === "segment").length).toBeGreaterThanOrEqual(4);
  });
});

describe("concrete program identity and preparation", () => {
  it("keeps incompatible concrete runs untouched and rejects identity downgrade", async () => {
    const concrete = { ...fakeProgram, identity: "pinned-engine-v1" };
    const run = await makePipeline({}, { program: concrete }).pipeline.attach();
    const before = await store.getRun(run.id);
    await expect(makePipeline({}, { program: { ...concrete, identity: "other-engine" } }).pipeline.attach(run.id)).rejects.toThrow(/identity/);
    await expect(makePipeline().pipeline.attach(run.id)).rejects.toThrow(/identity/);
    expect(await store.getRun(run.id)).toEqual(before);
  });
  it("syncs pre-panel tics and persists exact async args and fresh AIR refusal without proving", async () => {
    let journal = words(4);
    let prepared = 0, releases = 0;
    const concrete: SegmentProgram = { ...fakeProgram, identity: "pinned-engine-v1",
      journalWords: () => journal,
      releasePreparation: () => { releases++; },
      encodeArgs: () => { throw new Error("synchronous path forbidden"); },
      prepareArgs: async request => { prepared++; return fakeProgram.encodeArgs(request); },
    };
    const { pipeline } = makePipeline({ legacySizing: true }, { program: concrete });
    const run = await pipeline.attach();
    await pipeline.syncGameJournal();
    await pipeline.syncGameJournal(); // opening/toggling the panel does not duplicate inputs
    expect(pipeline.state.ticsRecorded).toBe(4);
    await pipeline.proveAll();
    const saved = await store.getRun(run.id);
    expect(saved?.programIdentity).toBe(concrete.identity);
    expect(saved?.admissionFailure?.args).toEqual(["0x1", "0x0", "0x4"]);
    expect(saved?.admissionFailure?.outputPreimage).toHaveLength(11);
    expect(saved?.admissionFailure?.reason).toMatch(/update the prover artifacts/);
    expect((await store.getInputs(run.id)).ticCount).toBe(4);
    expect(prepared).toBe(1); expect(FakeProver.proves).toBe(0);
    expect(releases).toBe(1); expect(FakeProver.terminations).toBeGreaterThan(0);
    journal = [99, ...journal.slice(1)];
    await expect(pipeline.syncGameJournal()).rejects.toThrow(/prefix/);
  });
  it("refuses persisted argument substitution before requeue or proving", async () => {
    const concrete: SegmentProgram = { ...fakeProgram, identity: "pinned-engine-v1",
      prepareArgs: async request => fakeProgram.encodeArgs(request) };
    const first = makePipeline({ failOn: new Set([0]) }, { program: concrete });
    const run = await first.pipeline.attach();
    await first.pipeline.appendTics(words(4)); await first.pipeline.proveAll();
    const saved = await store.getSegment(run.id, 0);
    await store.putSegment({ ...saved!, args: ["0xdead", ...saved!.args.slice(1)] });
    const before = FakeProver.proves;
    await expect(makePipeline({}, { program: concrete }).pipeline.attach(run.id)).rejects.toThrow(/arguments differ/);
    expect(FakeProver.proves).toBe(before);
  });
});


describe("retry error state", () => {
  it("clears a transient failure before a successful fresh retry", async () => {
    const failOn = new Set([0]);
    const { pipeline } = makePipeline({ failOn });
    await pipeline.attach(); await pipeline.appendTics([0, 0, 0, 0]);
    await pipeline.proveAll(); expect(pipeline.state.error).toContain("prover exploded");
    const executions = FakeProver.executes;
    failOn.clear(); const retry = pipeline.proveAll();
    await retry;
    expect(pipeline.state.error).toBeUndefined(); expect(pipeline.state.proved).toBe(1);
    expect(FakeProver.executes).toBeGreaterThan(executions);
    await pipeline.stop(true); store.close();
  });
});


it("owns and terminates a prover whose init rejects", async () => {
  const { pipeline } = makePipeline({}, { createProver: () => {
    const p = new FakeProver({ seen: new Set() }); p.init = async () => { throw new Error("init failed response"); }; return p;
  } });
  await pipeline.attach(); await pipeline.appendTics([0]); await pipeline.proveAll();
  expect(pipeline.state.error).toContain("init failed response");
  expect(FakeProver.terminations).toBe(1); await pipeline.stop(true);
  expect(FakeProver.terminations).toBe(1); expect(FakeProver.proves).toBe(0);
});

it("hard stop owns an initializing prover and cannot resurrect it after a late init", async () => {
  let release!: () => void, notify!: () => void;
  const ready = new Promise<void>(resolve => { notify = resolve; });
  const held = new Promise<void>(resolve => { release = resolve; });
  const { pipeline } = makePipeline({}, { createProver: () => {
    const p = new FakeProver({ seen: new Set() }), init = p.init.bind(p);
    p.init = async opts => { notify(); await held; return init(opts); }; return p;
  } });
  await pipeline.attach(); await pipeline.appendTics([0]); const proving = pipeline.proveAll();
  await ready; const stopping = pipeline.stop(true);
  expect(FakeProver.terminations).toBe(1); release(); await Promise.all([proving, stopping]);
  expect(FakeProver.executes).toBe(0); expect(FakeProver.proves).toBe(0);
  expect(FakeProver.terminations).toBe(1);
});


it.each(["reject", "late success"])("hard stop during threaded prove prevents retry and persistence (%s)", async outcome => {
  let notify!: () => void, release!: () => void;
  const started = new Promise<void>(resolve => { notify = resolve; });
  let calls = 0;
  const { pipeline } = makePipeline({}, { createProver: () => {
    const p = new FakeProver({ seen: new Set() }), prove = p.prove.bind(p), terminate = p.terminate.bind(p);
    p.prove = input => {
      calls++; notify();
      return new Promise((resolve, reject) => {
        release = () => outcome === "reject" ? reject(new Error("intentional hard stop")) : void prove(input).then(resolve, reject);
      });
    };
    p.terminate = () => { terminate(); release?.(); }; return p;
  } });
  const run = await pipeline.attach(); await pipeline.appendTics([0]);
  const proving = pipeline.proveAll(); await started;
  await pipeline.stop(true); await proving;
  expect(FakeProver.instances).toBe(1); expect(FakeProver.terminations).toBe(1); expect(calls).toBe(1);
  expect(pipeline.segmentRecords[0]?.stage).toBe("failed");
  expect(pipeline.segmentRecords[0]?.retriedSingleThread).toBe(false);
  expect(await store.getProof(run.id, 0)).toBeUndefined(); expect(pipeline.state.proved).toBe(0);
});


it.each(["reject", "late success"])("hard stop during planning execute plans nothing and keeps the journal (%s)", async outcome => {
  let notify!: () => void, release!: () => void, resources = 0;
  const started = new Promise<void>(resolve => { notify = resolve; });
  const { pipeline } = makePipeline({}, { createProver: () => {
    const p = new FakeProver({ seen: new Set() }), execute = p.execute.bind(p), summary = p.resources.bind(p), terminate = p.terminate.bind(p);
    p.execute = (executable, args) => {
      notify();
      return new Promise((resolve, reject) => {
        release = () => outcome === "reject" ? reject(new Error("prover worker terminated by hard stop")) : void execute(executable, args).then(resolve, reject);
      });
    };
    p.resources = input => { resources++; return summary(input); };
    p.terminate = () => { terminate(); release?.(); }; return p;
  } });
  const run = await pipeline.attach(); await pipeline.appendTics([7]);
  const proving = pipeline.proveAll(); await started;
  const stopping = pipeline.stop(true);
  await expect(Promise.all([proving, stopping])).resolves.toBeDefined();
  expect(FakeProver.instances).toBe(1); expect(FakeProver.terminations).toBe(1);
  expect(FakeProver.executes).toBe(outcome === "reject" ? 0 : 1); expect(resources).toBe(0); expect(FakeProver.proves).toBe(0);
  expect(pipeline.segmentRecords).toHaveLength(0); expect(await store.listSegments(run.id)).toHaveLength(0);
  expect(pipeline.state.running).toBe(false); expect(pipeline.state.error).toMatch(/hard stop/);
  const persisted = (await store.getRun(run.id))!;
  expect(persisted.ticsPlanned).toBe(0); expect(persisted.segments ?? 0).toBe(0); expect(persisted.admissionFailure).toBeUndefined();
  expect(await store.getInputs(run.id)).toMatchObject({ ticCount: 1, tail: [7] });
});


it("soft stop finishes and persists the segment already in flight", async () => {
  let notify!: () => void, release!: () => void;
  const started = new Promise<void>(resolve => { notify = resolve; });
  const { pipeline } = makePipeline({}, { createProver: () => {
    const p = new FakeProver({ seen: new Set() }), prove = p.prove.bind(p);
    p.prove = input => { notify(); return new Promise((resolve, reject) => { release = () => { void prove(input).then(resolve, reject); }; }); };
    return p;
  } });
  const run = await pipeline.attach(); await pipeline.appendTics([0]); const proving = pipeline.proveAll();
  await started; const stopped = pipeline.stop(false); expect(FakeProver.terminations).toBe(0);
  release(); await Promise.all([proving, stopped]);
  expect(pipeline.segmentRecords[0]?.stage).toBe("proved"); expect(await store.getProof(run.id, 0)).toBeDefined();
  expect(FakeProver.instances).toBe(1); expect(FakeProver.proves).toBe(1);
});

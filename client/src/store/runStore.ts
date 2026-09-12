/**
 * The client's local database of runs (roadmap **P2.5**, risks **R1-A7** and
 * **R6-A2**).
 *
 * Everything a game produces lives here and nowhere else until the player says
 * otherwise (criterion **C6**): the packed ticcmd journal, the segment
 * boundaries the planner chose, each segment's proof, its ten-felt output and
 * output preimage, its status, and how far it got towards the wrapper. A proof
 * is written *the moment it is produced* — R1-A7's requirement, and what makes
 * "close the tab at 50 %, reopen, finish" work.
 *
 * Layout note: the ~4.2 MB proof blobs live in their own object store so that
 * listing a run's segments (which the UI does on every event) never pulls
 * hundreds of megabytes through the structured clone.
 */
import {
  DEFAULT_DB_NAME,
  STORES,
  deleteDatabase,
  get,
  getAll,
  getAllFromIndex,
  openDatabase,
  put,
  remove,
  runKeyRange,
  withTransaction,
} from "./db.js";
import type { Felt, RunRecord, RunSubmissionState, SegmentRecord } from "../prove/types.js";

/** The packed journal of a run: complete 7-tic groups plus the group in flight. */
export interface InputRecord {
  runId: string;
  /** Tics recorded. */
  ticCount: number;
  /** Frozen transport felts (7 tics each). */
  packed: Felt[];
  /** The 0..6 words that have not filled a felt yet. */
  tail: number[];
}

export interface ProofRecord {
  runId: string;
  index: number;
  bytes: ArrayBuffer;
}

export interface CreateRunInit {
  id?: string;
  program: string;
  programHashFunction: "blake" | "poseidon";
  genesis: Felt;
  keepOffline?: boolean;
  notes?: string;
}

function newRunId(): string {
  const bytes = new Uint8Array(16);
  (globalThis.crypto ?? { getRandomValues: (b: Uint8Array): Uint8Array => b }).getRandomValues?.(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export class RunStore {
  private constructor(private readonly db: IDBDatabase, readonly name: string) {}

  static async open(name = DEFAULT_DB_NAME, factory = globalThis.indexedDB): Promise<RunStore> {
    return new RunStore(await openDatabase(name, factory), name);
  }

  close(): void {
    this.db.close();
  }

  // -- runs -----------------------------------------------------------------

  async createRun(init: CreateRunInit): Promise<RunRecord> {
    const now = Date.now();
    const run: RunRecord = {
      id: init.id ?? newRunId(),
      createdAt: now,
      updatedAt: now,
      program: init.program,
      programHashFunction: init.programHashFunction,
      genesis: init.genesis,
      stage: "recording",
      ticCount: 0,
      ticsPlanned: 0,
      segments: 0,
      keepOffline: init.keepOffline ?? false,
      finished: false,
      submission: {},
      ...(init.notes === undefined ? {} : { notes: init.notes }),
    };
    await withTransaction(this.db, [STORES.runs, STORES.inputs], "readwrite", async (tx) => {
      await put(tx, STORES.runs, run);
      const inputs: InputRecord = { runId: run.id, ticCount: 0, packed: [], tail: [] };
      await put(tx, STORES.inputs, inputs);
    });
    return run;
  }

  getRun(id: string): Promise<RunRecord | undefined> {
    return withTransaction(this.db, STORES.runs, "readonly", (tx) => get<RunRecord>(tx, STORES.runs, id));
  }

  async listRuns(): Promise<RunRecord[]> {
    const runs = await withTransaction(this.db, STORES.runs, "readonly", (tx) =>
      getAll<RunRecord>(tx, STORES.runs),
    );
    return runs.sort((a, b) => b.createdAt - a.createdAt);
  }

  async updateRun(id: string, patch: Partial<Omit<RunRecord, "id">>): Promise<RunRecord> {
    return withTransaction(this.db, STORES.runs, "readwrite", async (tx) => {
      const current = await get<RunRecord>(tx, STORES.runs, id);
      if (!current) throw new Error(`no such run: ${id}`);
      const next: RunRecord = { ...current, ...patch, id, updatedAt: Date.now() };
      await put(tx, STORES.runs, next);
      return next;
    });
  }

  /** Merges into `run.submission` rather than replacing it. */
  updateSubmission(id: string, patch: Partial<RunSubmissionState>): Promise<RunRecord> {
    return withTransaction(this.db, STORES.runs, "readwrite", async (tx) => {
      const current = await get<RunRecord>(tx, STORES.runs, id);
      if (!current) throw new Error(`no such run: ${id}`);
      const next: RunRecord = {
        ...current,
        submission: { ...current.submission, ...patch, updatedAt: Date.now() },
        updatedAt: Date.now(),
      };
      await put(tx, STORES.runs, next);
      return next;
    });
  }

  /** The explicit reset C6 demands: the run and everything it produced, gone. */
  async deleteRun(id: string): Promise<void> {
    await withTransaction(
      this.db,
      [STORES.runs, STORES.segments, STORES.inputs, STORES.proofs],
      "readwrite",
      async (tx) => {
        await remove(tx, STORES.runs, id);
        await remove(tx, STORES.inputs, id);
        await remove(tx, STORES.segments, runKeyRange(id));
        await remove(tx, STORES.proofs, runKeyRange(id));
      },
    );
  }

  // -- inputs ---------------------------------------------------------------

  async getInputs(runId: string): Promise<InputRecord> {
    const record = await withTransaction(this.db, STORES.inputs, "readonly", (tx) =>
      get<InputRecord>(tx, STORES.inputs, runId),
    );
    return record ?? { runId, ticCount: 0, packed: [], tail: [] };
  }

  /**
   * Overwrites the journal of a run. The caller (the pipeline) keeps the log in
   * memory and flushes here about once a second — one IndexedDB write per tic at
   * 35 Hz would be both pointless and visible in the frame budget.
   */
  async putInputs(record: InputRecord): Promise<void> {
    await withTransaction(this.db, [STORES.inputs, STORES.runs], "readwrite", async (tx) => {
      await put(tx, STORES.inputs, record);
      const run = await get<RunRecord>(tx, STORES.runs, record.runId);
      if (run) await put(tx, STORES.runs, { ...run, ticCount: record.ticCount, updatedAt: Date.now() });
    });
  }

  // -- segments -------------------------------------------------------------

  async listSegments(runId: string): Promise<SegmentRecord[]> {
    const segments = await withTransaction(this.db, STORES.segments, "readonly", (tx) =>
      getAllFromIndex<SegmentRecord>(tx, STORES.segments, "byRun", runId),
    );
    return segments.sort((a, b) => a.index - b.index);
  }

  getSegment(runId: string, index: number): Promise<SegmentRecord | undefined> {
    return withTransaction(this.db, STORES.segments, "readonly", (tx) =>
      get<SegmentRecord>(tx, STORES.segments, [runId, index]),
    );
  }

  /**
   * Writes a segment and, when there is one, its proof — in **one** transaction,
   * so a crash can never leave a segment marked `proved` with no proof behind it
   * (R1-A7).
   */
  async putSegment(segment: SegmentRecord, proof?: Uint8Array): Promise<void> {
    const stores = proof ? [STORES.segments, STORES.proofs, STORES.runs] : [STORES.segments, STORES.runs];
    await withTransaction(this.db, stores, "readwrite", async (tx) => {
      await put(tx, STORES.segments, { ...segment, updatedAt: Date.now() });
      if (proof) {
        const bytes = proof.buffer.slice(
          proof.byteOffset,
          proof.byteOffset + proof.byteLength,
        ) as ArrayBuffer;
        const record: ProofRecord = { runId: segment.runId, index: segment.index, bytes };
        await put(tx, STORES.proofs, record);
      }
      const run = await get<RunRecord>(tx, STORES.runs, segment.runId);
      if (run && segment.index + 1 > run.segments) {
        await put(tx, STORES.runs, { ...run, segments: segment.index + 1, updatedAt: Date.now() });
      }
    });
  }

  async getProof(runId: string, index: number): Promise<Uint8Array | undefined> {
    const record = await withTransaction(this.db, STORES.proofs, "readonly", (tx) =>
      get<ProofRecord>(tx, STORES.proofs, [runId, index]),
    );
    return record ? new Uint8Array(record.bytes) : undefined;
  }

  /** Bytes of proofs held for a run — what an export would carry. */
  async proofBytesHeld(runId: string): Promise<number> {
    const segments = await this.listSegments(runId);
    return segments.reduce((sum, s) => sum + (s.proofBytes || 0), 0);
  }

  /**
   * Bulk write of a whole run — what `.hellproof` import needs, in one
   * transaction so a half-imported run cannot exist.
   */
  async importRun(
    run: RunRecord,
    inputs: InputRecord,
    segments: SegmentRecord[],
    proofs: Map<number, Uint8Array>,
  ): Promise<void> {
    await withTransaction(
      this.db,
      [STORES.runs, STORES.inputs, STORES.segments, STORES.proofs],
      "readwrite",
      async (tx) => {
        await put(tx, STORES.runs, run);
        await put(tx, STORES.inputs, inputs);
        for (const segment of segments) await put(tx, STORES.segments, segment);
        for (const [index, bytes] of proofs) {
          const copy = bytes.buffer.slice(
            bytes.byteOffset,
            bytes.byteOffset + bytes.byteLength,
          ) as ArrayBuffer;
          const record: ProofRecord = { runId: run.id, index, bytes: copy };
          await put(tx, STORES.proofs, record);
        }
      },
    );
  }

  // -- meta -----------------------------------------------------------------

  async getMeta<T>(key: string): Promise<T | undefined> {
    const record = await withTransaction(this.db, STORES.meta, "readonly", (tx) =>
      get<{ key: string; value: T }>(tx, STORES.meta, key),
    );
    return record?.value;
  }

  async setMeta<T>(key: string, value: T): Promise<void> {
    await withTransaction(this.db, STORES.meta, "readwrite", (tx) => put(tx, STORES.meta, { key, value }));
  }

  /** Wipes the whole database. Closes this handle first. */
  async reset(factory = globalThis.indexedDB): Promise<void> {
    this.db.close();
    await deleteDatabase(this.name, factory);
  }
}

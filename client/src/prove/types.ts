/**
 * Domain types of the client-side proving pipeline (roadmap **P3.2**).
 *
 * The pipeline turns a ticcmd journal into a chain of segment proofs while the
 * game is being played. Nothing here knows about Doom: a segment is *K tics of
 * somebody's game*, described by the ten-felt public output of `cairo/crates/segment`
 * (decision **D14**) and proved by `@hellproof/prover-wasm`.
 */

/** A field element as `0x…` hex. Same convention as the wrapper's wire format. */
export type Felt = string;

/** `segment::Status` — the sixth felt of the public output (D14). */
export const SegmentStatus = {
  RUNNING: 0,
  DEAD: 1,
  EXIT: 2,
  ABORT: 3,
} as const;
export type SegmentStatusCode = (typeof SegmentStatus)[keyof typeof SegmentStatus];

/** The layout version `segment::VERSION` refuses to read anything else than. */
export const SEGMENT_OUTPUT_VERSION = 1;

/** Number of felts in a segment's public output (D14). */
export const SEGMENT_OUTPUT_FELTS = 10;

/**
 * The ten public felts of one segment, decoded.
 *
 * `[version, h_in, h_out, tic_start, tic_end, status, inputs_commitment, kills,
 * items, secrets]` — `cairo/crates/segment/README.md` "Public output layout".
 */
export interface SegmentOutput {
  version: number;
  hIn: Felt;
  hOut: Felt;
  ticStart: number;
  ticEnd: number;
  status: number;
  inputsCommitment: Felt;
  kills: number;
  items: number;
  secrets: number;
}

/** Where a segment is in the pipeline. Persisted, so a reload can re-queue it. */
export type SegmentStage =
  | "planned"
  | "executing"
  | "proving"
  | "verifying"
  | "proved"
  | "failed";

/** Per-stage wall-clock, in ms. `undefined` until the stage has run. */
export interface SegmentTimings {
  executeMs?: number;
  resourcesMs?: number;
  proveMs?: number;
  verifyMs?: number;
  totalMs?: number;
}

/** What `resources()` told the planner about the segment that was accepted. */
export interface SegmentResources {
  nSteps: number;
  maxComponent: string;
  /** `next_pow2` of the largest component's count, as the prover reports it. */
  maxComponentRows: number;
  logMaxComponentSize: number;
  /**
   * The *un-rounded* largest component count over the 2^20 limit — the planner's
   * control signal (see `planner.ts`). 1.0 means "exactly at the ceiling".
   */
  utilisation: number;
  fitsLeafRegistry: boolean;
}

/** How far a segment got towards the wrapper. */
export type SubmissionState = "local" | "uploading" | "submitted" | "accepted" | "rejected";

/** One segment of a run, as persisted (the proof bytes live in their own store). */
export interface SegmentRecord {
  runId: string;
  index: number;
  ticStart: number;
  ticEnd: number;
  /** Program arguments, exactly as handed to `execute()`. */
  args: Felt[];
  /** `[program_hash, out_0 … out_9]` — what the wrapper takes as `output_preimage`. */
  outputPreimage: Felt[];
  /** The two bootloader output cells (the 128-bit halves of the Blake2s digest). */
  publicOutputs: Felt[];
  /** The decoded ten felts, `null` while the segment has not been executed yet. */
  output: SegmentOutput | null;
  stage: SegmentStage;
  /** Size of the bincode proof; the bytes themselves are in the `proofs` store. */
  proofBytes: number;
  /** `verify()` said yes, in this browser. */
  verified: boolean;
  /** Number of `prove()` attempts, retries included (R1-A8). */
  attempts: number;
  /** Threads the *successful* attempt used; 1 after a single-thread retry. */
  threads: number;
  /** True once a threaded attempt timed out and the retry went single-threaded. */
  retriedSingleThread: boolean;
  timings: SegmentTimings;
  /** Peak `WebAssembly.Memory.buffer.byteLength` seen while this segment ran. */
  memoryBytes: number;
  resources: SegmentResources | null;
  error?: string;
  submission: SubmissionState;
  updatedAt: number;
}

/** Lifecycle of a whole run (one game). */
export type RunStage = "recording" | "proving" | "proved" | "failed";

export interface RunSubmissionState {
  /** Idempotency key used with `POST /v1/runs`; stable across retries. */
  runId?: string;
  batchId?: string;
  /** Last status the wrapper reported. */
  status?: string;
  batchStatus?: string;
  rootProofFeltCount?: number;
  /** Segments the server has acknowledged (see `wrapper/submitter.ts`). */
  uploadedSegments?: number;
  error?: string;
  updatedAt?: number;
}

export interface RunRecord {
  id: string;
  createdAt: number;
  updatedAt: number;
  /** The wrapper's program id (`segment_stub10`, later `doom_run`). */
  program: string;
  programHashFunction: "blake" | "poseidon";
  programIdentity?: string;
  /** Last rejected preparation remains exportable even if no segment fits. */
  admissionFailure?: { ticStart: number; ticCount: number; args: Felt[]; outputPreimage: Felt[];
    reason: string; resources: unknown; updatedAt: number };
  /** `h_in` of the first segment. */
  genesis: Felt;
  stage: RunStage;
  /** Tics recorded so far. */
  ticCount: number;
  /** Tics already covered by a planned segment. */
  ticsPlanned: number;
  segments: number;
  /** C6: never leaves this machine until the player says so. */
  keepOffline: boolean;
  /** Set when the player has played to the exit switch (`status = EXIT`). */
  finished: boolean;
  submission: RunSubmissionState;
  /** Free-form, for the diagnostics panel. */
  notes?: string;
}

/** Progress events the pipeline emits; the UI renders nothing else. */
export type PipelineEvent =
  | { type: "run"; run: RunRecord }
  | {
      type: "segment";
      segment: SegmentRecord;
      /** Total segments *known* so far — a run is not cut up front, so this grows. */
      total: number;
    }
  | {
      type: "progress";
      index: number;
      total: number;
      stage: SegmentStage;
      /** ms since this segment entered the pipeline. */
      elapsedMs: number;
      memoryBytes: number;
      /** Span name from the prover (`Prove STARKs`, …) when there is one. */
      detail?: string;
    }
  | { type: "prover"; threads: number; threaded: boolean; wasmUrl: string; instantiateMs: number }
  | { type: "chain"; ok: boolean; reason?: string; segments: number }
  | { type: "quota"; usageBytes: number; quotaBytes: number; persisted: boolean; warning: boolean }
  | { type: "log"; level: "error" | "warn" | "info" | "debug"; message: string };

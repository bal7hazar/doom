// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * Wire types of the Hellproof wrapper service. These mirror `prover/wrapper/src/model.rs`
 * one-for-one; the JSON schema is documented in `prover/wrapper/README.md`.
 */

/** A field element, as `0x…` hex (preferred) or a decimal string. */
export type Felt = string;

/**
 * How a segment proof is encoded.
 *
 * - `bincode_b64` — base64 of the bincode-serialized extended `CairoProof`, which is what
 *   `prover/wasm`'s `prove()` returns. **This is the only form the server can verify**, so it is
 *   the one to send.
 * - `cairo_serde_felts` — the cairo-serde felt stream (`proofToFelts()`), the format the on-chain
 *   Cairo verifier consumes. It is a one-way encoding at the pinned monorepo commit (`CairoProof`
 *   implements `CairoSerialize` but not `CairoDeserialize`), so a server configured with
 *   `require_verifiable_proof = true` (the default) rejects submissions that only carry it.
 */
export type ProofFormat = "bincode_b64" | "cairo_serde_felts";

export interface ProofBlob {
  format: ProofFormat;
  /** Base64 string, for `bincode_b64`. */
  data?: string;
  /** Felt array, for `cairo_serde_felts`. */
  felts?: Felt[];
}

export interface SegmentSubmission {
  /** 0-based position in the game. Indices must be contiguous and in order. */
  index: number;
  /**
   * The segment program's user arguments (what `run_segment` was called with).
   *
   * Required only against a server configured with `leaf_mode = "rerun"`, which replays the
   * segment from them. With the default `"from_proof"` the submitted proof is what gets folded
   * and they are optional.
   */
  args?: Felt[];
  /**
   * `[task_program_hash, task_output…]` — the preimage the leaf simple bootloader dumps
   * (`output_preimage_dump_path`, returned by the wasm prover as `output_preimage`). The wrapper
   * hashes it and checks the result against the proof's own output cells.
   */
  output_preimage: Felt[];
  /**
   * Optional: the two bootloader output cells. The server recomputes them from
   * `output_preimage`; sending them makes the client's view explicit and catches a mismatch at
   * submission time.
   */
  public_outputs?: Felt[];
  proof: ProofBlob;
}

/**
 * Which hash the leaf simple bootloader computes the task's program hash with — the value that
 * becomes `output_preimage[0]`. `poseidon` is the production choice (G0 D4); the server rejects a
 * submission whose hash function is not the one its program entry is configured for.
 */
export type HashFunction = "blake" | "poseidon";

export interface RunSubmission {
  /** Client-chosen id; resubmitting the same id with the same content is a no-op. */
  run_id?: string;
  /** The player's Starknet account address. */
  player?: Felt;
  /** A program id the server has pinned (clients never upload code). */
  program: string;
  /** Omitted = the program's configured default. */
  program_hash_function?: HashFunction;
  /** Wrap this run alone, immediately, instead of waiting for the batch. */
  solo?: boolean;
  /**
   * An empty array creates a `collecting` run with no segments yet — the resumable per-segment
   * upload protocol (`PUT .../segments/{index}`, then `POST .../complete`). A run can also come
   * into existence directly from a first `PUT`, without this call at all. Required (rather than
   * optional) here so existing callers that always pass a segment array keep the same type;
   * the wire format itself also accepts the field being omitted entirely.
   */
  segments: SegmentSubmission[];
  /**
   * Optional, resumable uploads only: how many segments this game will have. Used to reject an
   * out-of-range `PUT` index early and to check the count at `/complete`.
   */
  expected_segments?: number;
}

/** `POST /v1/runs/{id}/complete` body: supplies whatever a `collecting` run does not know yet. */
export interface CompleteRunRequest {
  /** Required unless the run already has a program (from an explicit `POST /v1/runs`). */
  program?: string;
  program_hash_function?: HashFunction;
  player?: Felt;
  /** Omitted = keep whatever the run was created with. */
  solo?: boolean;
}

/** `GET /v1/runs/{id}/segments` — what the server currently holds for a resumable upload. */
export interface SegmentsListResponse {
  run_id: string;
  status: RunStatus | string;
  /** Indices present, for a quick "what is left to upload" check. */
  held: number[];
  segments: HeldSegment[];
  expected_segments?: number;
}

export interface HeldSegment {
  index: number;
  size_bytes: number;
  sha256: string;
  verified: boolean;
  verify_ms?: number;
}

/** `PUT /v1/runs/{id}/segments/{index}` response: the immediate verification verdict (R8-A1). */
export interface SegmentUploadResponse {
  run_id: string;
  index: number;
  verified: boolean;
  verify_ms?: number;
  sha256: string;
  size_bytes: number;
  /** True when this index was already held with the same content (idempotent no-op). */
  duplicate?: boolean;
  error?: string;
}

export type RunStatus =
  | "collecting"
  | "verifying"
  | "rejected"
  | "queued"
  | "wrapping"
  | "done"
  | "failed";

export interface SubmitResponse {
  run_id: string;
  status: RunStatus | string;
  segments: number;
  batch_id?: string;
  duplicate?: boolean;
}

export interface SegmentStatus {
  index: number;
  leaf_key: string;
  verified: boolean;
  verify_ms?: number;
  /** `pending` | `queued` | `running` | `done` | `failed` */
  leaf_state: string;
  leaf_ms?: number;
  leaf_max_rss_bytes?: number;
}

export interface Progress {
  segments: number;
  verified: number;
  leaves_done: number;
  leaves_cached: number;
}

export interface Timings {
  verify_ms_total: number;
  leaf_ms_total: number;
  fold_ms?: number;
  /** How long the run waited in its batch before the batch closed. */
  queued_ms?: number;
  total_ms?: number;
}

export interface RunStatusResponse {
  run_id: string;
  status: RunStatus | string;
  /** Empty while `collecting` a run that has not been given a program yet. */
  program: string;
  player?: Felt;
  solo: boolean;
  expected_segments?: number;
  batch_id?: string;
  batch_status?: string;
  created_at_ms: number;
  updated_at_ms: number;
  error?: string;
  progress: Progress;
  segments: SegmentStatus[];
  timings: Timings;
}

export interface BatchLeafRef {
  /** Position in the fold order, left to right. */
  position: number;
  run_id: string;
  segment_index: number;
  leaf_key: string;
}

export interface BatchResponse {
  batch_id: string;
  status: "open" | "closed" | "folding" | "done" | "failed" | string;
  runs: string[];
  leaves: BatchLeafRef[];
  created_at_ms: number;
  closed_at_ms?: number;
  finished_at_ms?: number;
  fold_ms?: number;
  fold_max_rss_bytes?: number;
  error?: string;
  /** The root proof as the felt stream the Cairo circuit verifier consumes (~94 k felts). */
  root_proof_felts?: Felt[];
  root_proof_felt_count?: number;
  /** The root node's eight raw output words. */
  program_output?: number[];
  /** The digest tree the consumer recomposes on-chain. */
  packed_output?: unknown;
}

export interface ApiError {
  error: string;
  detail?: string;
}

// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

import type {
  BatchResponse,
  CompleteRunRequest,
  RunStatusResponse,
  RunSubmission,
  SegmentsListResponse,
  SegmentSubmission,
  SegmentUploadResponse,
  SubmitResponse,
} from "./types.js";

export class WrapperError extends Error {
  constructor(
    readonly status: number,
    readonly body: { error?: string; detail?: string },
  ) {
    super(body.error ?? `HTTP ${status}`);
    this.name = "WrapperError";
  }
  /** The submission was refused for good: retrying the same bytes will not help. */
  get permanent(): boolean {
    return this.status >= 400 && this.status < 500 && this.status !== 429;
  }
}

export interface ClientOptions {
  baseUrl: string;
  /** Bearer token. Replaced by a Controller session signature when that lands (see README). */
  apiKey?: string;
  fetch?: typeof globalThis.fetch;
  /** Applied to every request. */
  signal?: AbortSignal;
}

/**
 * Thin client for the wrapper service. No dependencies: it is `fetch` plus the wire types.
 *
 * ```ts
 * const client = new WrapperClient({ baseUrl, apiKey });
 * const { run_id } = await client.submitRun({
 *   program: "doom_run",
 *   segments: segments.map(toSegmentSubmission),
 * });
 * const run = await client.waitForRun(run_id);
 * const batch = await client.getBatch(run.batch_id!, { include: ["proof"] });
 * ```
 */
export class WrapperClient {
  private readonly baseUrl: string;
  private readonly apiKey: string | undefined;
  private readonly doFetch: typeof globalThis.fetch;
  private readonly signal: AbortSignal | null;

  constructor(options: ClientOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, "");
    this.apiKey = options.apiKey;
    this.doFetch = options.fetch ?? globalThis.fetch.bind(globalThis);
    this.signal = options.signal ?? null;
  }

  /**
   * Submits one game. Set `waitVerifyMs` to block until the server has verified the segment
   * proofs (it answers 422 with `status: "rejected"` if one of them is invalid); otherwise the
   * call returns as soon as the run is persisted and the verdict shows up in `getRun`.
   */
  async submitRun(run: RunSubmission, waitVerifyMs = 0): Promise<SubmitResponse> {
    const query = waitVerifyMs > 0 ? `?wait_verify_ms=${waitVerifyMs}` : "";
    return this.request<SubmitResponse>("POST", `/v1/runs${query}`, run);
  }

  async getRun(runId: string): Promise<RunStatusResponse> {
    return this.request<RunStatusResponse>("GET", `/v1/runs/${encodeURIComponent(runId)}`);
  }

  /**
   * Resumable per-segment uploads (see the README's "Resumable per-segment uploads" section):
   * `PUT` each segment on its own — a dropped connection costs one proof, not the whole run —
   * then `POST .../complete`. A run comes into existence from either the first `PUT` (its
   * program is fixed at `/complete`) or this call (fixed immediately); `getHeldSegments` is what
   * a resumed client probes to find out what is already uploaded.
   *
   * ```ts
   * await client.putSegment(runId, 0, toSegmentSubmission(segment0));
   * await client.putSegment(runId, 1, toSegmentSubmission(segment1));
   * const { run_id } = await client.completeRun(runId, { program: "doom_run" });
   * ```
   */
  async putSegment(
    runId: string,
    index: number,
    segment: SegmentSubmission,
  ): Promise<SegmentUploadResponse> {
    return this.request<SegmentUploadResponse>(
      "PUT",
      `/v1/runs/${encodeURIComponent(runId)}/segments/${index}`,
      segment,
    );
  }

  /** What the server currently holds for a run being assembled by `putSegment`. */
  async getHeldSegments(runId: string): Promise<SegmentsListResponse> {
    return this.request<SegmentsListResponse>(
      "GET",
      `/v1/runs/${encodeURIComponent(runId)}/segments`,
    );
  }

  /**
   * Finishes a resumable upload: binds every uploaded segment to `req.program` (unless the run
   * already has one), checks the chain across all of them, and queues the run exactly like
   * `submitRun` would have. Same response shape and the same `wait_verify_ms` semantics.
   */
  async completeRun(
    runId: string,
    req: CompleteRunRequest = {},
    waitVerifyMs = 0,
  ): Promise<SubmitResponse> {
    const query = waitVerifyMs > 0 ? `?wait_verify_ms=${waitVerifyMs}` : "";
    return this.request<SubmitResponse>(
      "POST",
      `/v1/runs/${encodeURIComponent(runId)}/complete${query}`,
      req,
    );
  }

  /** An unfinished (`collecting`) run only: nothing has been queued for it yet. */
  async deleteRun(runId: string): Promise<void> {
    const res = await this.doFetch(`${this.baseUrl}/v1/runs/${encodeURIComponent(runId)}`, {
      method: "DELETE",
      headers: this.apiKey ? { authorization: `Bearer ${this.apiKey}` } : {},
      signal: this.signal,
    });
    if (!res.ok) {
      const text = await res.text();
      throw new WrapperError(res.status, text ? JSON.parse(text) : {});
    }
  }

  async getBatch(
    batchId: string,
    options: { include?: ("proof" | "packed")[] } = {},
  ): Promise<BatchResponse> {
    const include = options.include?.length ? `?include=${options.include.join(",")}` : "";
    return this.request<BatchResponse>(
      "GET",
      `/v1/batches/${encodeURIComponent(batchId)}${include}`,
    );
  }

  /** Admin key only: closes the open batch now instead of waiting for M runs or T minutes. */
  async closeOpenBatch(): Promise<{ closed: string[] }> {
    return this.request<{ closed: string[] }>("POST", "/v1/batches/close");
  }

  /** Prometheus text. */
  async metrics(): Promise<string> {
    const res = await this.doFetch(`${this.baseUrl}/metrics`, { signal: this.signal });
    return res.text();
  }

  /**
   * Polls until the run reaches a terminal state. `onProgress` is called after every poll, which
   * is what a UI should render: the wait is bounded and visible (D6).
   */
  async waitForRun(
    runId: string,
    options: {
      pollMs?: number;
      timeoutMs?: number;
      onProgress?: (run: RunStatusResponse) => void;
    } = {},
  ): Promise<RunStatusResponse> {
    const pollMs = options.pollMs ?? 2000;
    const deadline = Date.now() + (options.timeoutMs ?? 3_600_000);
    for (;;) {
      const run = await this.getRun(runId);
      options.onProgress?.(run);
      if (run.status === "done" || run.status === "failed" || run.status === "rejected") {
        return run;
      }
      if (Date.now() > deadline) {
        throw new Error(`timed out waiting for run ${runId} (status ${run.status})`);
      }
      await new Promise((r) => setTimeout(r, pollMs));
    }
  }

  private async request<T>(method: string, path: string, body?: unknown): Promise<T> {
    const headers: Record<string, string> = {};
    if (this.apiKey) headers.authorization = `Bearer ${this.apiKey}`;
    if (body !== undefined) headers["content-type"] = "application/json";
    const init: RequestInit = { method, headers, signal: this.signal };
    if (body !== undefined) init.body = JSON.stringify(body);
    const res = await this.doFetch(`${this.baseUrl}${path}`, init);
    const text = await res.text();
    const parsed = text ? JSON.parse(text) : {};
    if (!res.ok) throw new WrapperError(res.status, parsed);
    return parsed as T;
  }
}

/**
 * Builds a segment submission from what the browser prover returns.
 *
 * `proofBytes` is the bincode extended `CairoProof` (`prove()`), `outputPreimage` the felts the
 * bootloader dumped (`output_preimage`).
 */
export function toSegmentSubmission(segment: {
  index: number;
  /** Optional: only a `leaf_mode = "rerun"` server replays the segment from them. */
  args?: string[];
  outputPreimage: string[];
  proofBytes: Uint8Array;
  publicOutputs?: string[];
}): SegmentSubmission {
  return {
    index: segment.index,
    ...(segment.args ? { args: segment.args } : {}),
    output_preimage: segment.outputPreimage,
    ...(segment.publicOutputs ? { public_outputs: segment.publicOutputs } : {}),
    proof: { format: "bincode_b64", data: toBase64(segment.proofBytes) },
  };
}

/** Base64 of a byte array, in browsers and in Node. */
export function toBase64(bytes: Uint8Array): string {
  const maybeBuffer = (globalThis as { Buffer?: { from(b: Uint8Array): { toString(e: string): string } } })
    .Buffer;
  if (maybeBuffer) return maybeBuffer.from(bytes).toString("base64");
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

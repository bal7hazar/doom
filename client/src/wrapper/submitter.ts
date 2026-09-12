/**
 * Uploading a proved run to the wrapper service (`prover/wrapper`).
 *
 * The wire types are the service's own (`@hellproof/wrapper-client`, which
 * mirrors `prover/wrapper/src/model.rs`); what is here is the part that package
 * deliberately does not do — getting tens of megabytes of proof out of a browser
 * without building one giant string and without starting from scratch after a
 * dropped connection.
 *
 * ## What the wrapper API offers today, and what it lacks
 *
 * `POST /v1/runs` takes a **whole run** in one JSON body: every segment, every
 * proof, base64'd. For a 3-minute game that is 25–75 proofs of ~4.2 MB, i.e.
 * 140–420 MB of base64 in a single request. The README itself says "keep the
 * body streaming rather than building one giant string where you can" — but
 * there is no endpoint that accepts less than a whole run, and `run_id` is the
 * unit of idempotency, so a partial submission followed by a fuller one is a
 * `409`, not a resume.
 *
 * So this client implements **two** strategies:
 *
 * - `per-segment` — `PUT /v1/runs/{run_id}/segments/{index}` then
 *   `POST /v1/runs/{run_id}/complete`, with `GET /v1/runs/{run_id}/segments`
 *   listing what the server already holds. **The wrapper does not implement
 *   these yet**; this is the shape it should add (see the README note this file
 *   is cited from). When the endpoints are absent the probe gets a 404/405 and
 *   the client falls back to:
 * - `whole-run` — one `POST /v1/runs`, with the body built as a
 *   `ReadableStream` when the browser can upload one (Chrome, over HTTPS or
 *   HTTP/2), so only one proof is base64'd at a time. Retries reuse the same
 *   `run_id`, which the server dedupes, so a retry is at least not a double
 *   proof — it is simply a full re-upload.
 *
 * Either way, per-segment progress is persisted (`RunSubmissionState.uploadedSegments`),
 * so the UI can say what is left and a reload picks up where it stopped.
 */
import type {
  RunStatusResponse,
  RunSubmission,
  SegmentSubmission,
  SubmitResponse,
} from "@hellproof/wrapper-client";
import type { RunStore } from "../store/runStore.js";
import type { RunRecord, SegmentRecord } from "../prove/types.js";

export type UploadMode = "auto" | "per-segment" | "whole-run";

export interface SubmitterOptions {
  baseUrl: string;
  apiKey?: string;
  store: RunStore;
  fetchImpl?: typeof globalThis.fetch;
  uploadMode?: UploadMode;
  /** Refuse to build a non-streamed body larger than this (default 64 MiB). */
  maxInlineBodyBytes?: number;
  /** Retries per request, with exponential backoff. */
  maxAttempts?: number;
  onProgress?: (progress: UploadProgress) => void;
}

export interface UploadProgress {
  runId: string;
  /** Segments the server is known to hold. */
  uploaded: number;
  total: number;
  bytesSent: number;
  mode: Exclude<UploadMode, "auto">;
  stage: "probing" | "uploading" | "completing" | "polling" | "done" | "failed";
  message?: string;
}

export class WrapperHttpError extends Error {
  constructor(
    readonly status: number,
    readonly body: { error?: string; detail?: string },
  ) {
    super(body.error ?? `HTTP ${status}`);
    this.name = "WrapperHttpError";
  }
  /** 4xx other than 429: retrying the same bytes cannot help. */
  get permanent(): boolean {
    return this.status >= 400 && this.status < 500 && this.status !== 429;
  }
}

/** Base64 of a byte array, chunked so a 4 MB proof does not blow the arg list. */
export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

/** True when this engine can send a `ReadableStream` as a request body. */
export function supportsStreamingUpload(): boolean {
  if (typeof ReadableStream === "undefined" || typeof Request === "undefined") return false;
  let used = false;
  try {
    const request = new Request("https://example.invalid/", {
      method: "POST",
      body: new ReadableStream(),
      // @ts-expect-error `duplex` is required for a stream body and is not in lib.dom yet.
      duplex: "half",
      get headers() {
        used = true;
        return new Headers();
      },
    });
    void request;
  } catch {
    return false;
  }
  return used;
}

export class WrapperSubmitter {
  private readonly baseUrl: string;
  private readonly doFetch: typeof globalThis.fetch;
  private readonly store: RunStore;
  private readonly maxAttempts: number;
  private readonly maxInlineBodyBytes: number;
  private readonly requestedMode: UploadMode;
  private readonly apiKey: string | undefined;
  private readonly onProgress: (p: UploadProgress) => void;

  constructor(options: SubmitterOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, "");
    this.doFetch = options.fetchImpl ?? ((...a: Parameters<typeof fetch>) => globalThis.fetch(...a));
    this.store = options.store;
    this.maxAttempts = options.maxAttempts ?? 4;
    this.maxInlineBodyBytes = options.maxInlineBodyBytes ?? 64 * 1024 * 1024;
    this.requestedMode = options.uploadMode ?? "auto";
    this.apiKey = options.apiKey;
    this.onProgress = options.onProgress ?? ((): void => {});
  }

  private headers(json: boolean): Record<string, string> {
    const headers: Record<string, string> = {};
    if (this.apiKey) headers.authorization = `Bearer ${this.apiKey}`;
    if (json) headers["content-type"] = "application/json";
    return headers;
  }

  private async request<T>(method: string, path: string, body?: unknown): Promise<T> {
    let lastError: unknown;
    for (let attempt = 0; attempt < this.maxAttempts; attempt++) {
      try {
        const init: RequestInit = { method, headers: this.headers(body !== undefined) };
        if (body !== undefined) init.body = JSON.stringify(body);
        const res = await this.doFetch(`${this.baseUrl}${path}`, init);
        const text = await res.text();
        const parsed = (text ? JSON.parse(text) : {}) as T & { error?: string; detail?: string };
        if (!res.ok) {
          const error = new WrapperHttpError(res.status, parsed);
          if (error.permanent) throw error;
          lastError = error;
        } else {
          return parsed;
        }
      } catch (error) {
        if (error instanceof WrapperHttpError && error.permanent) throw error;
        lastError = error;
      }
      await sleep(250 * 2 ** attempt);
    }
    throw lastError instanceof Error ? lastError : new Error(String(lastError));
  }

  /**
   * Submits a whole proved run. Idempotent: call it again after a failure and it
   * reuses the same `run_id`, so the server either dedupes or resumes.
   */
  async submit(
    localRunId: string,
    options: { player?: string; solo?: boolean; waitVerifyMs?: number } = {},
  ): Promise<SubmitResponse> {
    const run = await this.store.getRun(localRunId);
    if (!run) throw new Error(`no such run: ${localRunId}`);
    if (run.keepOffline) {
      throw new Error(`run ${localRunId} is marked "keep offline" (C6); clear the flag before submitting`);
    }
    const segments = (await this.store.listSegments(localRunId)).filter((s) => s.stage === "proved");
    if (segments.length === 0) throw new Error(`run ${localRunId} has no proved segment`);
    if (segments.some((s, i) => s.index !== i)) {
      throw new Error("the proved segments are not contiguous from 0; the wrapper would refuse the run");
    }

    // The wrapper's run id, kept across retries — this is the resume key.
    const runId = run.submission.runId ?? `${run.program}-${run.id.slice(0, 24)}`;
    await this.store.updateSubmission(run.id, { runId, status: "uploading" });

    const mode = await this.resolveMode(runId);
    try {
      const response =
        mode === "per-segment"
          ? await this.submitPerSegment(run, runId, segments, options)
          : await this.submitWholeRun(run, runId, segments, options);
      await this.store.updateSubmission(run.id, {
        runId: response.run_id ?? runId,
        status: response.status,
        ...(response.batch_id ? { batchId: response.batch_id } : {}),
        uploadedSegments: segments.length,
      });
      for (const segment of segments) {
        if (segment.submission !== "submitted") {
          await this.store.putSegment({ ...segment, submission: "submitted" });
        }
      }
      this.onProgress({
        runId,
        uploaded: segments.length,
        total: segments.length,
        bytesSent: segments.reduce((s, x) => s + x.proofBytes, 0),
        mode,
        stage: "done",
      });
      return response;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await this.store.updateSubmission(run.id, { status: "failed", error: message });
      this.onProgress({ runId, uploaded: 0, total: segments.length, bytesSent: 0, mode, stage: "failed", message });
      throw error;
    }
  }

  /** Probes the per-segment endpoints once; falls back to the whole-run POST. */
  private async resolveMode(runId: string): Promise<Exclude<UploadMode, "auto">> {
    if (this.requestedMode !== "auto") return this.requestedMode;
    this.onProgress({ runId, uploaded: 0, total: 0, bytesSent: 0, mode: "whole-run", stage: "probing" });
    try {
      const res = await this.doFetch(
        `${this.baseUrl}/v1/runs/${encodeURIComponent(runId)}/segments`,
        { method: "GET", headers: this.headers(false) },
      );
      // 404 on a run that does not exist yet is ambiguous; 405 / 501 is not.
      if (res.status === 200 || res.status === 404) {
        const body = res.status === 200 ? ((await res.json()) as { held?: number[] }) : null;
        if (body && Array.isArray(body.held)) return "per-segment";
      }
    } catch {
      /* the wrapper is old, or offline; the fallback covers both */
    }
    return "whole-run";
  }

  /**
   * The shape the wrapper *should* grow: one request per segment, resumable, so
   * a dropped connection costs one proof and not a whole game.
   */
  private async submitPerSegment(
    run: RunRecord,
    runId: string,
    segments: SegmentRecord[],
    options: { player?: string; solo?: boolean },
  ): Promise<SubmitResponse> {
    let held: number[] = [];
    try {
      held = (
        await this.request<{ held: number[] }>("GET", `/v1/runs/${encodeURIComponent(runId)}/segments`)
      ).held;
    } catch {
      held = [];
    }
    let bytesSent = 0;
    let uploaded = held.length;
    for (const segment of segments) {
      if (held.includes(segment.index)) continue;
      const payload = await this.segmentSubmission(run, segment);
      await this.request<unknown>(
        "PUT",
        `/v1/runs/${encodeURIComponent(runId)}/segments/${segment.index}`,
        payload,
      );
      bytesSent += segment.proofBytes;
      uploaded++;
      await this.store.putSegment({ ...segment, submission: "uploading" });
      await this.store.updateSubmission(run.id, { uploadedSegments: uploaded });
      this.onProgress({
        runId,
        uploaded,
        total: segments.length,
        bytesSent,
        mode: "per-segment",
        stage: "uploading",
      });
    }
    this.onProgress({
      runId,
      uploaded,
      total: segments.length,
      bytesSent,
      mode: "per-segment",
      stage: "completing",
    });
    return this.request<SubmitResponse>("POST", `/v1/runs/${encodeURIComponent(runId)}/complete`, {
      program: run.program,
      program_hash_function: run.programHashFunction,
      ...(options.player ? { player: options.player } : {}),
      ...(options.solo ? { solo: true } : {}),
    });
  }

  /** What the wrapper implements today: the whole run in one request. */
  private async submitWholeRun(
    run: RunRecord,
    runId: string,
    segments: SegmentRecord[],
    options: { player?: string; solo?: boolean; waitVerifyMs?: number },
  ): Promise<SubmitResponse> {
    const query = options.waitVerifyMs ? `?wait_verify_ms=${options.waitVerifyMs}` : "";
    const url = `${this.baseUrl}/v1/runs${query}`;
    const head: Omit<RunSubmission, "segments"> = {
      run_id: runId,
      program: run.program,
      program_hash_function: run.programHashFunction,
      ...(options.player ? { player: options.player } : {}),
      ...(options.solo ? { solo: true } : {}),
    };

    const streamed = supportsStreamingUpload();
    const projected = segments.reduce((sum, s) => sum + Math.ceil((s.proofBytes * 4) / 3) + 512, 0);
    if (!streamed && projected > this.maxInlineBodyBytes) {
      throw new Error(
        `this run would need a ${Math.round(projected / 1024 / 1024)} MiB request body and this browser cannot stream one. ` +
          `Export the run (.hellproof) and submit it from a client that can, or ask the wrapper for the per-segment upload endpoints.`,
      );
    }

    let bytesSent = 0;
    const notify = (stage: UploadProgress["stage"], uploaded: number): void =>
      this.onProgress({ runId, uploaded, total: segments.length, bytesSent, mode: "whole-run", stage });

    const self = this;
    const parts = async function* (): AsyncGenerator<string> {
      yield `${JSON.stringify(head).slice(0, -1)},"segments":[`;
      for (let i = 0; i < segments.length; i++) {
        const segment = segments[i] as SegmentRecord;
        const payload = await self.segmentSubmission(run, segment);
        yield (i === 0 ? "" : ",") + JSON.stringify(payload);
        bytesSent += segment.proofBytes;
        notify("uploading", i + 1);
      }
      yield "]}";
    };

    let init: RequestInit;
    if (streamed) {
      const encoder = new TextEncoder();
      const iterator = parts();
      const body = new ReadableStream<Uint8Array>({
        async pull(controller) {
          const next = await iterator.next();
          if (next.done) controller.close();
          else controller.enqueue(encoder.encode(next.value));
        },
      });
      init = {
        method: "POST",
        headers: this.headers(true),
        body,
        // Required for a streamed request body; not in lib.dom yet.
        ...({ duplex: "half" } as Record<string, unknown>),
      };
    } else {
      let text = "";
      for await (const part of parts()) text += part;
      init = { method: "POST", headers: this.headers(true), body: text };
    }

    const res = await this.doFetch(url, init);
    const responseText = await res.text();
    const parsed = (responseText ? JSON.parse(responseText) : {}) as SubmitResponse & {
      error?: string;
      detail?: string;
    };
    if (!res.ok) throw new WrapperHttpError(res.status, parsed);
    notify("polling", segments.length);
    return parsed;
  }

  private async segmentSubmission(run: RunRecord, segment: SegmentRecord): Promise<SegmentSubmission> {
    const proof = await this.store.getProof(run.id, segment.index);
    if (!proof) throw new Error(`segment ${segment.index} of run ${run.id} has no stored proof`);
    return {
      index: segment.index,
      args: segment.args,
      output_preimage: segment.outputPreimage,
      public_outputs: segment.publicOutputs,
      proof: { format: "bincode_b64", data: toBase64(proof) },
    };
  }

  /** `GET /v1/runs/{id}` — the status a progress UI renders. */
  getRun(runId: string): Promise<RunStatusResponse> {
    return this.request<RunStatusResponse>("GET", `/v1/runs/${encodeURIComponent(runId)}`);
  }

  /**
   * Polls until the run is terminal, mirroring the local record as it goes so a
   * reload knows the batch id without asking again.
   */
  async waitForRun(
    localRunId: string,
    options: { pollMs?: number; timeoutMs?: number; onStatus?: (r: RunStatusResponse) => void } = {},
  ): Promise<RunStatusResponse> {
    const local = await this.store.getRun(localRunId);
    const runId = local?.submission.runId;
    if (!runId) throw new Error(`run ${localRunId} has not been submitted`);
    const pollMs = options.pollMs ?? 2000;
    const deadline = Date.now() + (options.timeoutMs ?? 3_600_000);
    for (;;) {
      const status = await this.getRun(runId);
      options.onStatus?.(status);
      await this.store.updateSubmission(localRunId, {
        status: status.status,
        ...(status.batch_id ? { batchId: status.batch_id } : {}),
        ...(status.batch_status ? { batchStatus: status.batch_status } : {}),
        ...(status.error ? { error: status.error } : {}),
      });
      if (status.status === "done" || status.status === "failed" || status.status === "rejected") {
        return status;
      }
      if (Date.now() > deadline) throw new Error(`timed out waiting for run ${runId} (${status.status})`);
      await sleep(pollMs);
    }
  }

  /**
   * `GET /v1/batches/{id}` — the root proof's felt count and the fold order. The
   * felts themselves are P4.3's business (the on-chain submission screen); only
   * the metadata is stored locally.
   */
  async fetchBatchSummary(
    localRunId: string,
    batchId: string,
  ): Promise<{ status: string; rootProofFeltCount?: number }> {
    const batch = await this.request<{ status: string; root_proof_felt_count?: number }>(
      "GET",
      `/v1/batches/${encodeURIComponent(batchId)}`,
    );
    await this.store.updateSubmission(localRunId, {
      batchId,
      batchStatus: batch.status,
      ...(batch.root_proof_felt_count === undefined
        ? {}
        : { rootProofFeltCount: batch.root_proof_felt_count }),
    });
    return {
      status: batch.status,
      ...(batch.root_proof_felt_count === undefined
        ? {}
        : { rootProofFeltCount: batch.root_proof_felt_count }),
    };
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

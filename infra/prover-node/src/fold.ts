// SPDX-License-Identifier: Apache-2.0
/**
 * The fold: segment proofs go to the wrapper, one root proof comes back.
 *
 * Uses `@hellproof/wrapper-client`'s resumable per-segment protocol (`PUT …/segments/{i}`, then
 * `POST …/complete`) so an interrupted upload resumes from what the server already holds — the
 * run id is derived from the commitment, hence stable across relaunches. The wrapper verifies
 * every leaf proof on upload (R8-A1), folds the batch, and `GET /v1/batches/{id}?include=proof`
 * returns the root proof felts and the `packed_output` tree the submission needs.
 *
 * Before anything is paid for, the batch's leaves at this run's positions are compared with the
 * ten felts this node executed: the fold order is the wrapper's, the outputs are ours.
 */
import { WrapperClient, WrapperError, type BatchResponse, type RunStatusResponse, type SegmentSubmission } from "../../../prover/wrapper/client-ts/src/index.js";
import { parseWrapperBatch, type WrapperBatch } from "../../../client/src/chain/batch.js";
import { normalizeFelt } from "../../../client/src/prove/felt.js";
import { wrapperRunId } from "./commitments.js";
import type { ProofArtifact } from "./prover.js";
import type { PlannedSegment } from "./segmenter.js";
import type { JobRecord } from "./store.js";

export interface FoldOptions {
  client: WrapperClient;
  job: JobRecord;
  artifacts: ProofArtifact[];
  program?: string;
  hashFunction?: "blake" | "poseidon";
  pollMs?: number;
  timeoutMs?: number;
  log?: (message: string) => void;
  onStatus?: (status: string) => void;
}

export interface FoldResult {
  runId: string;
  batchId: string;
  batch: WrapperBatch;
  response: BatchResponse;
  run: RunStatusResponse;
}

const TERMINAL_RUN = new Set(["done", "failed", "rejected"]);

export function toSubmission(artifact: ProofArtifact, segment: PlannedSegment): SegmentSubmission {
  return {
    index: artifact.index,
    args: segment.args,
    output_preimage: artifact.outputPreimage,
    proof:
      artifact.format === "bincode_b64"
        ? { format: "bincode_b64", data: artifact.data ?? "" }
        : { format: "cairo_serde_felts", felts: artifact.felts ?? [] },
  };
}

export async function foldRun(options: FoldOptions): Promise<FoldResult> {
  const { client, job, artifacts } = options;
  const log = options.log ?? (() => {});
  const pollMs = options.pollMs ?? 2000;
  const deadline = Date.now() + (options.timeoutMs ?? 3_600_000);
  if (!job.segments) throw new Error("nothing to fold: the journal has not been cut");
  if (artifacts.length !== job.segments.length) {
    throw new Error(`${artifacts.length} proofs for ${job.segments.length} segments`);
  }
  const runId = wrapperRunId(job.commitment.commitmentId);
  job.wrapper = { ...(job.wrapper ?? {}), runId };

  // What the server already holds for this run id, if anything.
  let heldIndices = new Set<number>();
  let status = "collecting";
  try {
    const held = await client.getHeldSegments(runId);
    heldIndices = new Set(held.held);
    status = held.status;
  } catch (e) {
    if (!(e instanceof WrapperError && e.status === 404)) throw e;
  }

  if (status === "collecting") {
    for (const artifact of artifacts) {
      const segment = job.segments[artifact.index]!;
      if (heldIndices.has(artifact.index)) {
        log(`segment ${artifact.index}: already uploaded`);
        continue;
      }
      const res = await client.putSegment(runId, artifact.index, toSubmission(artifact, segment));
      if (!res.verified) {
        throw new Error(`the wrapper rejected segment ${artifact.index}: ${res.error ?? "proof not verified"}`);
      }
      log(`segment ${artifact.index}: uploaded (${res.size_bytes} bytes, verified in ${res.verify_ms ?? "?"} ms)`);
    }
    const completed = await client.completeRun(runId, {
      program: options.program ?? "doom_run",
      program_hash_function: options.hashFunction ?? "blake",
      player: job.commitment.player,
    });
    status = completed.status;
    log(`run ${runId}: ${status} with ${completed.segments} segments${completed.duplicate ? " (duplicate)" : ""}`);
  } else {
    log(`run ${runId}: already ${status} on the wrapper, waiting for it`);
  }

  const run = await client.waitForRun(runId, {
    pollMs,
    timeoutMs: Math.max(1, deadline - Date.now()),
    onProgress: (r) => {
      job.wrapper = { runId, status: r.status, ...(r.batch_id ? { batchId: r.batch_id } : {}) };
      options.onStatus?.(r.status);
    },
  });
  if (run.status !== "done" || !run.batch_id) {
    throw new Error(`the wrapper ${TERMINAL_RUN.has(run.status) ? run.status : "stalled at " + run.status} run ${runId}: ${run.error ?? "no detail"}`);
  }

  let response = await client.getBatch(run.batch_id);
  while (response.status !== "done") {
    if (response.status === "failed") throw new Error(`the wrapper failed batch ${run.batch_id}: ${response.error ?? "no detail"}`);
    if (Date.now() > deadline) throw new Error(`timed out waiting for batch ${run.batch_id} (status ${response.status})`);
    await new Promise((r) => setTimeout(r, pollMs));
    response = await client.getBatch(run.batch_id);
  }
  response = await client.getBatch(run.batch_id, { include: ["proof"] });
  if (!response.root_proof_felts?.length) throw new Error(`batch ${run.batch_id} came back without root_proof_felts`);

  // Our packed logs at our positions (the replay the registration publishes); nothing elsewhere.
  const logs: string[][] = response.leaves.map(() => []);
  for (const leaf of response.leaves) {
    if (leaf.run_id !== runId) continue;
    const segment = job.segments[leaf.segment_index];
    if (!segment) throw new Error(`batch ${run.batch_id} places a segment ${leaf.segment_index} this run does not have`);
    logs[leaf.position] = segment.packed;
  }
  const batch = parseWrapperBatch({
    batch_id: response.batch_id,
    leaves: response.leaves,
    packed_output: response.packed_output as never,
    root_proof_felts: response.root_proof_felts,
    logs,
  });
  checkOwnLeaves(batch, response, runId, job.segments);

  job.wrapper = { runId, batchId: run.batch_id, status: "done", rootProofFelts: response.root_proof_felts.length };
  log(`batch ${run.batch_id}: done, ${batch.leaves.length} leaves, ${response.root_proof_felts.length} root proof felts`);
  return { runId, batchId: run.batch_id, batch, response, run };
}

/** The wrapper's leaves at this run's positions are exactly the ten felts this node executed. */
export function checkOwnLeaves(batch: WrapperBatch, response: BatchResponse, runId: string, segments: PlannedSegment[]): void {
  const own = response.leaves.filter((l) => l.run_id === runId).sort((a, b) => a.segment_index - b.segment_index);
  if (own.length !== segments.length) {
    throw new Error(`the batch holds ${own.length} leaves for this run, ${segments.length} were proved`);
  }
  for (const [i, leaf] of own.entries()) {
    if (leaf.segment_index !== i) throw new Error(`the batch orders segment ${leaf.segment_index} at rank ${i}`);
    const got = batch.leaves[leaf.position]!;
    const felts = [got.version, got.h_in, got.h_out, got.tic_start, got.tic_end, got.status, got.inputs_commitment, got.kills, got.items, got.secrets]
      .map((v) => normalizeFelt("0x" + v.toString(16)));
    const want = segments[i]!.outputFelts.map(normalizeFelt);
    if (felts.some((f, k) => f !== want[k])) {
      throw new Error(`leaf ${leaf.position} (segment ${i}) differs from the executed ten felts — refusing to pay for it`);
    }
  }
}

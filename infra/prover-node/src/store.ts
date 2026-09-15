// SPDX-License-Identifier: Apache-2.0
/**
 * File-backed persistence of the node's jobs — one directory per commitment under the work
 * directory, the job record in `job.json`, each proof in its own `proofs/<index>.json` so a
 * segment proved before an interruption is never proved again (same split as `infra/submit`'s
 * stores: small JSON files, no database).
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import type { RunCommitment } from "./commitments.js";
import type { PlannedSegment } from "./segmenter.js";
import type { ProofArtifact } from "./prover.js";

export type JobStage =
  | "discovered"
  | "reconstructed"
  | "cut"
  | "proving"
  | "proved"
  | "folding"
  | "folded"
  | "registering"
  | "registered"
  | "refused"
  | "failed";

export const STAGES: JobStage[] = [
  "discovered", "reconstructed", "cut", "proving", "proved", "folding", "folded", "registering", "registered",
];

export interface JobRecord {
  commitment: RunCommitment;
  stage: JobStage;
  segments: PlannedSegment[] | null;
  /** Indices whose proof is on disk. */
  proved: number[];
  wrapper: { runId: string; batchId?: string; status?: string; rootProofFelts?: number } | null;
  chain: {
    proofId: string;
    fact?: string;
    transactions: { label: string; hash: string }[];
    /** A `CommitmentProved` event followed the member submission. */
    settled?: boolean;
  } | null;
  error?: string;
  attempts: number;
  /** Wall-clock per stage, in ms. */
  timings: Partial<Record<JobStage, number>>;
  createdAt: number;
  updatedAt: number;
}

export function newJob(commitment: RunCommitment): JobRecord {
  const now = Date.now();
  return {
    commitment,
    stage: "discovered",
    segments: null,
    proved: [],
    wrapper: null,
    chain: null,
    attempts: 0,
    timings: {},
    createdAt: now,
    updatedAt: now,
  };
}

const replacer = (_k: string, v: unknown): unknown => (typeof v === "bigint" ? { $bigint: v.toString() } : v);
const reviver = (_k: string, v: unknown): unknown =>
  v && typeof v === "object" && "$bigint" in (v as object) ? BigInt((v as { $bigint: string }).$bigint) : v;

export class FileJobStore {
  constructor(readonly root: string) {
    mkdirSync(join(root, "jobs"), { recursive: true });
  }

  dirOf(commitmentId: string): string {
    return join(this.root, "jobs", commitmentId);
  }

  get(commitmentId: string): JobRecord | null {
    const path = join(this.dirOf(commitmentId), "job.json");
    if (!existsSync(path)) return null;
    return JSON.parse(readFileSync(path, "utf8"), reviver) as JobRecord;
  }

  put(job: JobRecord): JobRecord {
    job.updatedAt = Date.now();
    const dir = this.dirOf(job.commitment.commitmentId);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "job.json"), JSON.stringify(job, replacer, 1));
    return job;
  }

  list(): JobRecord[] {
    const dir = join(this.root, "jobs");
    return readdirSync(dir)
      .map((id) => this.get(id))
      .filter((j): j is JobRecord => j !== null)
      .sort((a, b) => a.createdAt - b.createdAt);
  }

  proofPath(commitmentId: string, index: number): string {
    return join(this.dirOf(commitmentId), "proofs", `${index}.json`);
  }

  putProof(commitmentId: string, artifact: ProofArtifact): void {
    mkdirSync(join(this.dirOf(commitmentId), "proofs"), { recursive: true });
    writeFileSync(this.proofPath(commitmentId, artifact.index), JSON.stringify(artifact));
  }

  getProof(commitmentId: string, index: number): ProofArtifact | null {
    const path = this.proofPath(commitmentId, index);
    return existsSync(path) ? (JSON.parse(readFileSync(path, "utf8")) as ProofArtifact) : null;
  }

  /** The wrapper's batch response, kept so a relaunch after the fold needs no new upload. */
  putBatch(commitmentId: string, doc: unknown): void {
    mkdirSync(this.dirOf(commitmentId), { recursive: true });
    writeFileSync(join(this.dirOf(commitmentId), "batch.json"), JSON.stringify(doc));
  }

  getBatch<T>(commitmentId: string): T | null {
    const path = join(this.dirOf(commitmentId), "batch.json");
    return existsSync(path) ? (JSON.parse(readFileSync(path, "utf8")) as T) : null;
  }

  /** Indices with a proof on disk, ascending. */
  proofIndices(commitmentId: string): number[] {
    const dir = join(this.dirOf(commitmentId), "proofs");
    if (!existsSync(dir)) return [];
    return readdirSync(dir)
      .filter((f) => f.endsWith(".json"))
      .map((f) => Number(f.slice(0, -5)))
      .filter((n) => Number.isInteger(n))
      .sort((a, b) => a - b);
  }
}

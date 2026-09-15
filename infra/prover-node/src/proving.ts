// SPDX-License-Identifier: Apache-2.0
/**
 * The proving stage: every planned segment without a proof on disk is proved, in order, and
 * each proof is persisted as soon as it exists. An interruption — a crash, a timeout, a lost
 * lock — costs at most the segment in flight; the next run starts from the first unproved index.
 *
 * A proof is accepted only if its bootloader preimage reproduces the ten felts the execution
 * produced (`[program_hash, out_0 … out_9]`, D14) — the same check `doomProgram.ts` makes in the
 * browser (`validateOutput`), and the reason a lying prover cannot make this node upload garbage.
 */
import { normalizeFelt } from "../../../client/src/prove/felt.js";
import type { Felt } from "../../../client/src/prove/types.js";
import type { ProofArtifact, ProveOptions, Prover } from "./prover.js";
import type { FileJobStore, JobRecord } from "./store.js";

export interface ProvingOptions extends ProveOptions {
  /** The program hash every proof must carry; unchecked when absent (the wrapper pins it anyway). */
  programHash?: Felt;
  log?: (message: string) => void;
  onProved?: (artifact: ProofArtifact, done: number, total: number) => void;
}

/** Throws with the segment index on the first failure; already persisted proofs are kept. */
export async function proveSegments(
  job: JobRecord,
  store: FileJobStore,
  prover: Prover,
  options: ProvingOptions = {},
): Promise<ProofArtifact[]> {
  if (!job.segments) throw new Error("nothing to prove: the journal has not been cut");
  const id = job.commitment.commitmentId;
  const log = options.log ?? (() => {});
  const have = new Set(store.proofIndices(id));
  job.proved = [...have];
  job.stage = "proving";
  store.put(job);

  const artifacts: ProofArtifact[] = [];
  for (const segment of job.segments) {
    const existing = have.has(segment.index) ? store.getProof(id, segment.index) : null;
    if (existing) {
      checkArtifact(existing, segment.outputFelts, options.programHash);
      artifacts.push(existing);
      log(`segment ${segment.index}: proof already on disk, kept`);
      continue;
    }
    log(`segment ${segment.index}: proving tics [${segment.ticStart}, ${segment.ticEnd}) with ${prover.id}`);
    const artifact = await prover.prove(
      { index: segment.index, args: segment.args, expectedOutput: segment.outputFelts, workDir: store.dirOf(id) },
      options,
    );
    checkArtifact(artifact, segment.outputFelts, options.programHash);
    store.putProof(id, artifact);
    job.proved.push(segment.index);
    store.put(job);
    artifacts.push(artifact);
    log(`segment ${segment.index}: proved in ${(artifact.proveMs / 1000).toFixed(1)} s`);
    options.onProved?.(artifact, artifacts.length, job.segments.length);
  }
  job.stage = "proved";
  store.put(job);
  return artifacts;
}

export function checkArtifact(artifact: ProofArtifact, expectedOutput: readonly Felt[], programHash?: Felt): void {
  const preimage = artifact.outputPreimage.map(normalizeFelt);
  if (preimage.length !== 11) {
    throw new Error(`segment ${artifact.index}: the proof preimage has ${preimage.length} felts, expected 11 (D14)`);
  }
  const tail = preimage.slice(1);
  const expected = expectedOutput.map(normalizeFelt);
  if (tail.some((f, i) => f !== expected[i])) {
    throw new Error(`segment ${artifact.index}: the proof's public output differs from the executed segment (D14/D13)`);
  }
  if (programHash !== undefined && preimage[0] !== normalizeFelt(programHash)) {
    throw new Error(`segment ${artifact.index}: proved with program ${preimage[0]}, this node expects ${programHash}`);
  }
  if (artifact.format === "bincode_b64" ? !artifact.data : !artifact.felts?.length) {
    throw new Error(`segment ${artifact.index}: the artifact carries no proof bytes`);
  }
}

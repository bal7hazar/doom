// SPDX-License-Identifier: Apache-2.0
/**
 * Reconstruction of the tic words from a commitment's packed journal (7 tics per felt) and the
 * per-segment logs the registration publishes (R10-A3): a segment's log is its own slice of the
 * words, re-packed from its first tic — which is why `inputs_commitment` differs from segment to
 * segment even on an all-idle journal, and why the fixture's leaf 1 does not share leaf 0's felts.
 */
import { packLog, unpackLog } from "../../../client/src/prove/ticcmd.js";
import { checkCommitment, type RunCommitment } from "./commitments.js";
import { commitLog } from "./commitment.js";

export interface ReconstructedJournal {
  words: number[];
  /** The packed journal as bigints, exactly as committed. */
  packed: bigint[];
  inputsCommitment: bigint;
}

/** Unpacks and verifies; throws with every problem `checkCommitment` found. */
export function reconstructJournal(c: RunCommitment, expected: { genesis?: string } = {}): ReconstructedJournal {
  const problems = checkCommitment(c, expected);
  if (problems.length) throw new Error(`commitment ${c.commitmentId} refused: ${problems.join("; ")}`);
  const words = unpackLog(c.journal, c.tics);
  if (words.length !== c.tics) throw new Error(`unpacked ${words.length} words for ${c.tics} tics`);
  const packed = c.journal.map((f) => BigInt(f));
  return { words, packed, inputsCommitment: commitLog(packed) };
}

/** The packed log and commitment of one segment's slice `[ticStart, ticEnd)`. */
export function segmentLog(words: readonly number[], ticStart: number, ticEnd: number): {
  packed: bigint[];
  commitment: bigint;
} {
  if (ticStart < 0 || ticEnd > words.length || ticEnd < ticStart) {
    throw new RangeError(`segment [${ticStart}, ${ticEnd}) is outside the ${words.length}-tic journal`);
  }
  const packed = packLog(words.slice(ticStart, ticEnd)).map((f) => BigInt(f));
  return { packed, commitment: commitLog(packed) };
}

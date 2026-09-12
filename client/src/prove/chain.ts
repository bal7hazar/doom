/**
 * Local verification of the **chain** between segment proofs (roadmap P3.3, and
 * the third check `prover/wrapper` runs before it spends anything).
 *
 * Verifying each proof says "these ten felts came out of the pinned program".
 * It says nothing about whether the ten felts of segment *i* and those of
 * segment *i+1* describe the same game — that is this file, and it is the rule
 * `cairo/crates/segment`'s `continues` writes once for the contract and the
 * tests: `h_in[0] = genesis`, `h_out[i] = h_in[i+1]`, `tic_end[i] =
 * tic_start[i+1]`, `status = EXIT` on the last segment and `RUNNING` on every
 * other one (D14, D21: `ABORT` is refused outright, `DEAD` is an attempt).
 */
import { feltEquals } from "./felt.js";
import { SEGMENT_OUTPUT_VERSION, SegmentStatus, type Felt, type SegmentOutput } from "./types.js";

export interface ChainOptions {
  /** `h_in` the first segment must start from. */
  genesis: Felt;
  /**
   * Demand a terminal status on the last segment. False while a run is still
   * being played: every segment is then `RUNNING`, which is correct so far.
   */
  requireFinished?: boolean;
}

export interface ChainResult {
  ok: boolean;
  /** Index of the offending segment, when there is one. */
  index?: number;
  reason?: string;
  /** Tics the chain covers, when it is sound. */
  tics?: number;
  /** Terminal status of the run, when the last segment has one. */
  finalStatus?: number;
}

const STATUS_NAME: Record<number, string> = {
  [SegmentStatus.RUNNING]: "RUNNING",
  [SegmentStatus.DEAD]: "DEAD",
  [SegmentStatus.EXIT]: "EXIT",
  [SegmentStatus.ABORT]: "ABORT",
};

export function statusName(status: number): string {
  return STATUS_NAME[status] ?? `status ${status}`;
}

/** Checks a whole run's segment outputs, in fold order. */
export function verifyChain(outputs: readonly SegmentOutput[], options: ChainOptions): ChainResult {
  if (outputs.length === 0) {
    return { ok: false, reason: "no segments" };
  }
  const fail = (index: number, reason: string): ChainResult => ({ ok: false, index, reason });

  for (let i = 0; i < outputs.length; i++) {
    const out = outputs[i] as SegmentOutput;
    if (out.version !== SEGMENT_OUTPUT_VERSION) {
      return fail(i, `output layout version ${out.version}, expected ${SEGMENT_OUTPUT_VERSION}`);
    }
    if (out.status === SegmentStatus.ABORT) {
      return fail(i, "ABORT: the segment proves an invalid execution (R4-A2); the run is refused");
    }
    if (out.ticEnd < out.ticStart) {
      return fail(i, `tic_end ${out.ticEnd} is before tic_start ${out.ticStart}`);
    }
    if (out.ticEnd === out.ticStart) {
      return fail(i, "empty segment: tic_end == tic_start covers no tic of the run");
    }
    const last = i === outputs.length - 1;
    if (!last && out.status !== SegmentStatus.RUNNING) {
      return fail(i, `${statusName(out.status)} on a segment that is not the last one`);
    }
    if (i === 0) {
      if (!feltEquals(out.hIn, options.genesis)) {
        return fail(0, `h_in ${out.hIn} is not the genesis state hash ${options.genesis}`);
      }
    } else {
      const previous = outputs[i - 1] as SegmentOutput;
      if (!feltEquals(previous.hOut, out.hIn)) {
        return fail(i, `h_in ${out.hIn} does not continue h_out ${previous.hOut} of segment ${i - 1}`);
      }
      if (previous.ticEnd !== out.ticStart) {
        return fail(i, `tic_start ${out.ticStart} does not continue tic_end ${previous.ticEnd} of segment ${i - 1}`);
      }
      if (out.kills < previous.kills || out.items < previous.items || out.secrets < previous.secrets) {
        return fail(i, "the score counters went backwards");
      }
    }
  }

  const lastOut = outputs[outputs.length - 1] as SegmentOutput;
  if (options.requireFinished && lastOut.status === SegmentStatus.RUNNING) {
    return {
      ok: false,
      index: outputs.length - 1,
      reason: "the run has no terminal segment: it is still RUNNING",
    };
  }
  return {
    ok: true,
    tics: lastOut.ticEnd - (outputs[0] as SegmentOutput).ticStart,
    finalStatus: lastOut.status,
  };
}

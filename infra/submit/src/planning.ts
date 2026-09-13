// SPDX-License-Identifier: Apache-2.0
/** Candidate plans for the CLI's simulate-before-send loop. */
import {
  prepareSubmission,
  type PrepareArgs,
  type PreparedSubmission,
} from "../../../client/src/chain/submission.js";

/**
 * Replan only a fresh, automatic sequence. Keep every consumer option (notably singleMember
 * and replay) while refining FRI. Each yielded candidate must be simulated before it is sent.
 * These are the existing gas-cap fallbacks; calldata fallback is handled by planPhasesAuto.
 */
export function* submissionPlans(
  args: PrepareArgs,
  initial: PreparedSubmission,
  nextPhase: number,
): Generator<PreparedSubmission> {
  yield initial;
  if (args.plan?.friSplit !== undefined || nextPhase > 0) return;
  for (const friSplit of [[1, 2, 4], [1, 2, 3, 4]]) {
    yield prepareSubmission({ ...args, plan: { ...args.plan, friSplit } });
  }
}

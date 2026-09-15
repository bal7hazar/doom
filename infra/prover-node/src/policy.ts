// SPDX-License-Identifier: Apache-2.0
/**
 * Selection policy: which open commitments this node works on, and in which order.
 *
 * D35 makes proving a race anyone can enter; a node's policy is its own business. This one is
 * deliberately simple and explicit — a floor on the bounty, the versions the node's executable
 * matches (a segment proved with another program hash recomposes to a fact `DoomRuns` will not
 * accept), a ceiling on the journal length, optional player lists, and a bounded queue ordered
 * by bounty per tic so the most rewarding work per second of proving goes first.
 */
import type { RunCommitment } from "./commitments.js";

export interface SelectionPolicy {
  /** Commitments below this bounty (FRI) are skipped. */
  minBounty: bigint;
  /** Version ids this node can prove; empty = any. */
  versions: number[];
  /** Longest journal, in tics, this node accepts; `undefined` = any. */
  maxTics?: number;
  /** Only these players (lower-case `0x…`); empty = any. */
  allowPlayers?: string[];
  /** Never these players. */
  denyPlayers?: string[];
  /** How many commitments one poll may hand to the pipeline. */
  maxQueue: number;
}

export const DEFAULT_POLICY: SelectionPolicy = {
  minBounty: 0n,
  versions: [],
  maxQueue: 4,
};

export interface Selection {
  selected: RunCommitment[];
  skipped: { commitmentId: string; reason: string }[];
}

export interface SelectionContext {
  /** Already registered, refused, or in flight here — never re-queued. */
  done: Set<string>;
  inFlight: Set<string>;
}

const norm = (a: string): string => "0x" + BigInt(a).toString(16);

export function selectCommitments(
  open: readonly RunCommitment[],
  policy: SelectionPolicy,
  ctx: SelectionContext,
): Selection {
  const allow = new Set((policy.allowPlayers ?? []).map(norm));
  const deny = new Set((policy.denyPlayers ?? []).map(norm));
  const skipped: Selection["skipped"] = [];
  const candidates: RunCommitment[] = [];

  for (const c of open) {
    const id = c.commitmentId;
    const reason = ctx.done.has(id)
      ? "already handled"
      : ctx.inFlight.has(id)
        ? "in flight"
        : c.bounty < policy.minBounty
          ? `bounty ${c.bounty} below the ${policy.minBounty} floor`
          : policy.versions.length && !policy.versions.includes(c.versionId)
            ? `version ${c.versionId} not supported (${policy.versions.join(",")})`
            : policy.maxTics !== undefined && c.tics > policy.maxTics
              ? `${c.tics} tics over the ${policy.maxTics} ceiling`
              : deny.has(norm(c.player))
                ? "player denied"
                : allow.size && !allow.has(norm(c.player))
                  ? "player not on the allow list"
                  : null;
    if (reason) skipped.push({ commitmentId: id, reason });
    else candidates.push(c);
  }

  // Bounty per tic, highest first; ties by age so the queue is stable across polls.
  const perTic = (c: RunCommitment): bigint => (c.bounty * 1_000_000n) / BigInt(Math.max(1, c.tics));
  candidates.sort((a, b) => {
    const d = perTic(b) - perTic(a);
    return d > 0n ? 1 : d < 0n ? -1 : a.blockNumber - b.blockNumber || a.commitmentId.localeCompare(b.commitmentId);
  });
  const room = Math.max(0, policy.maxQueue - ctx.inFlight.size);
  for (const c of candidates.slice(room)) skipped.push({ commitmentId: c.commitmentId, reason: "queue full (waiting)" });
  return { selected: candidates.slice(0, room), skipped };
}

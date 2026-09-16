// SPDX-License-Identifier: Apache-2.0
/**
 * Committing a run to the open prover (D35, P4.7) — the glue between the run record, the
 * wallet and the commit screen, in the shape `onchain.ts` gives the submission leg.
 *
 * * **the journal** is read from the store (`InputRecord`: complete transport felts plus the
 *   short tail), packed exactly as `TicLog.toFelts()` does, and its `commit_log` and the
 *   `commitment_id` are computed *before* the wallet is asked for anything — the run record
 *   carries both, so a reload knows what to look up;
 * * **the guards** (C6 and the contract's own rule): a run kept offline is refused before any
 *   network call; a record that already carries a live commitment is refused; and the chain is
 *   asked (`get_commitment`) whether this player already committed this very journal —
 *   `PENDING` and `PROVED` ids are never committed twice;
 * * **the follow-up**: `refresh()` reads the commitment back and maps it onto the record
 *   (`pending` / `expired` / `proved` by whom / `reclaimed`); `reclaim()` sends `reclaim` once
 *   the expiry block is reached.
 *
 * Nothing here holds a key: the `Signer` signs, the RPC estimates, and the Controller session
 * (`controllerConnect.ts`, `commitPolicies`) covers exactly `approve`, `commit_run`, `reclaim`.
 */

import {
  COMMIT_STATUS,
  commitLog,
  commitmentIdOf,
  packedLen,
  readBlockNumber,
  readCommitment,
  readFeeToken,
  reclaimCall,
  simulateCalls,
  type Commitment,
} from "../chain/commit.js";
import { withPrices } from "../chain/estimate.js";
import type { PriceSource } from "../chain/prices.js";
import { RpcClient, toHex } from "../chain/rpc.js";
import type { Signer } from "../chain/signer.js";
import type { RunStore } from "../store/runStore.js";
import { CommitScreen, type CommitChoice } from "../ui/commitScreen.js";
import type { OnChainConfig } from "./onchain.js";
import { pack7 } from "./ticcmd.js";
import type { CommitStatus, RunRecord, RunSubmissionState } from "./types.js";

export interface CommitDeps {
  config: OnChainConfig;
  store: RunStore;
  host: HTMLElement;
  log: (message: string) => void;
  /** The Controller with the commit policies; a devnet key in tests. */
  connectSigner: (config: OnChainConfig, feeToken?: string) => Promise<Signer>;
  /** C6: the player asked for the run to stay on this device. */
  onKeepOffline: () => Promise<void>;
  rpc?: RpcClient;
  priceSource?: PriceSource;
  document?: Document;
}

export interface CommitOutcome {
  choice: CommitChoice | "none";
  commitmentId?: string;
  transactionHash?: string;
  error?: string;
}

/** The statuses under which a record's commitment is still live — no second commitment then. */
const LIVE: CommitStatus[] = ["committing", "pending", "proved"];

/** The whole journal as `commit_run` takes it: the frozen felts, then the short tail as one more. */
export function packedJournal(inputs: { packed: readonly string[]; tail: readonly number[]; ticCount: number }): string[] {
  const packed = inputs.tail.length > 0 ? [...inputs.packed, pack7(inputs.tail)] : [...inputs.packed];
  if (packed.length !== packedLen(inputs.ticCount)) {
    throw new Error(`journal: ${packed.length} felt(s) for ${inputs.ticCount} tics, expected ${packedLen(inputs.ticCount)}`);
  }
  return packed;
}

/** What a `Commitment` read from the chain means for the record, given the current block. */
export function commitStatusOf(c: Commitment, block: number): CommitStatus | undefined {
  switch (c.status) {
    case COMMIT_STATUS.PENDING:
      return block >= c.expiresAt ? "expired" : "pending";
    case COMMIT_STATUS.PROVED:
      return "proved";
    case COMMIT_STATUS.RECLAIMED:
      return "reclaimed";
    default:
      return undefined;
  }
}

function patchFromCommitment(c: Commitment, status: CommitStatus): Partial<RunSubmissionState> {
  return {
    commitStatus: status,
    commitExpiresAt: c.expiresAt,
    commitBounty: c.bounty.toString(),
    ...(c.status === COMMIT_STATUS.PROVED ? { commitProver: c.prover, commitRunId: c.runId } : {}),
  };
}

export class RunCommitter {
  private readonly deps: CommitDeps;

  constructor(deps: CommitDeps) {
    this.deps = deps;
  }

  private get rpc(): RpcClient {
    return this.deps.rpc ?? new RpcClient(this.deps.config.rpcUrl);
  }

  /**
   * Shows the commit screen for a run and resolves once the player's choice has run its course:
   * "cancel" and "keep offline" at once, "commit" once the receipt is in (or the send failed).
   */
  async open(run: RunRecord): Promise<CommitOutcome> {
    const { config, store, log } = this.deps;
    if (run.keepOffline) {
      log("run kept offline (C6): untick \"Keep offline\" before committing");
      return { choice: "none" };
    }
    const live = run.submission.commitStatus;
    if (run.submission.commitmentId && live && LIVE.includes(live)) {
      log(`run already committed (${live}, id ${run.submission.commitmentId.slice(0, 14)}…): refresh its status instead`);
      return { choice: "none", commitmentId: run.submission.commitmentId };
    }
    const inputs = await store.getInputs(run.id);
    if (inputs.ticCount === 0) {
      log("nothing to commit: the journal is empty");
      return { choice: "none" };
    }
    const packed = packedJournal(inputs);
    const inputsCommitment = toHex(commitLog(packed));

    // The address is the one thing the id needs that only the wallet knows.
    const rpc = this.rpc;
    const feeToken = config.feeToken ?? (await readFeeToken(rpc, config.doomRuns));
    const signer = await this.deps.connectSigner(config, feeToken);
    const commitmentId = toHex(commitmentIdOf(config.versionId, config.levelId, signer.address, inputsCommitment));
    await store.updateSubmission(run.id, { commitmentId, inputsCommitment });

    const existing = await readCommitment(rpc, config.doomRuns, commitmentId);
    if (existing.status === COMMIT_STATUS.PENDING || existing.status === COMMIT_STATUS.PROVED) {
      const block = await readBlockNumber(rpc);
      const status = commitStatusOf(existing, block)!;
      await store.updateSubmission(run.id, patchFromCommitment(existing, status));
      log(
        `this journal is already committed by ${signer.address.slice(0, 10)}… (${status}` +
          `${existing.status === COMMIT_STATUS.PROVED ? `, proved by ${existing.prover.slice(0, 10)}…` : ""}): nothing to send`,
      );
      return { choice: "none", commitmentId };
    }
    log(
      `commit: ${inputs.ticCount} tics in ${packed.length} felt(s), commitment ${commitmentId.slice(0, 14)}… ` +
        `for ${signer.kind} ${signer.address.slice(0, 10)}…${existing.status === COMMIT_STATUS.RECLAIMED ? " (a reclaimed commitment: new escrow, new expiry)" : ""}`,
    );

    const doc = this.deps.document ?? this.deps.host.ownerDocument;
    const overlay = doc.createElement("section");
    overlay.className = "panel onchain-overlay commit-overlay";
    overlay.setAttribute("aria-label", "Commit the game");
    const screenEl = doc.createElement("div");
    const close = doc.createElement("button");
    close.type = "button";
    close.dataset["act"] = "close";
    close.textContent = "Close";
    overlay.append(screenEl, close);
    this.deps.host.append(overlay);

    return new Promise<CommitOutcome>((resolve) => {
      let settled = false;
      let chosen: CommitChoice | null = null;
      const finish = (outcome: CommitOutcome, remove: boolean): void => {
        if (remove) overlay.remove();
        if (settled) return;
        settled = true;
        resolve({ commitmentId, ...outcome });
      };
      const screen = new CommitScreen(screenEl, {
        rpc,
        signer,
        doomRuns: config.doomRuns,
        feeToken,
        args: { versionId: config.versionId, levelId: config.levelId, packed, tics: inputs.ticCount },
        bounty: config.defaultBounty,
        commitmentId,
        ...(this.deps.priceSource ? { priceSource: this.deps.priceSource } : {}),
        ...(config.chainId ? { chainId: config.chainId } : {}),
        onChoice: (choice, bounty) => {
          chosen = choice;
          if (choice === "cancel") {
            log("commit cancelled: nothing sent");
            finish({ choice }, true);
          } else if (choice === "offline") {
            void this.deps.onKeepOffline().then(() => finish({ choice }, true));
          } else {
            log(`committing from ${signer.address.slice(0, 10)}… with a ${bounty} bounty`);
            void store.updateSubmission(run.id, { commitStatus: "committing", commitBounty: bounty.toString() });
          }
        },
        onDone: ({ transactionHash, event }) => {
          const patch: Partial<RunSubmissionState> = { commitStatus: "pending", commitTx: transactionHash };
          if (!event) {
            log(`committed in ${transactionHash} (no RunCommitted event in the receipt: status read back on refresh)`);
          } else {
            const problems: string[] = [];
            if (BigInt(event.commitmentId) !== BigInt(commitmentId)) problems.push(`id ${event.commitmentId} ≠ ${commitmentId}`);
            if (BigInt(event.inputsCommitment) !== BigInt(inputsCommitment)) problems.push(`inputs_commitment ${event.inputsCommitment} ≠ ${inputsCommitment}`);
            if (event.tics !== inputs.ticCount) problems.push(`tics ${event.tics} ≠ ${inputs.ticCount}`);
            if (BigInt(event.player) !== BigInt(signer.address)) problems.push(`player ${event.player} ≠ ${signer.address}`);
            patch.commitExpiresAt = event.expiresAt;
            patch.commitBounty = event.bounty.toString();
            if (problems.length) {
              patch.error = `RunCommitted disagrees with the local computation: ${problems.join("; ")}`;
              log(`WARNING: ${patch.error}`);
            } else {
              log(`committed: ${commitmentId.slice(0, 14)}… in ${transactionHash}, reclaimable from block ${event.expiresAt}`);
            }
          }
          void store.updateSubmission(run.id, patch).then(() => finish({ choice: "commit", transactionHash }, false));
        },
        onFailed: (error) => {
          log(`commit stopped: ${error}`);
          void store
            .updateSubmission(run.id, { commitStatus: "failed", error })
            .then(() => finish({ choice: chosen ?? "none", error }, false));
        },
      });
      close.addEventListener("click", () => {
        if (chosen === null) log("commit cancelled: nothing sent");
        finish({ choice: chosen ?? "cancel" }, true);
      });
      void screen.open();
    });
  }

  /** Reads the commitment back and updates the record; returns the new status, if any. */
  async refresh(run: RunRecord): Promise<CommitStatus | undefined> {
    const { config, store, log } = this.deps;
    const id = run.submission.commitmentId;
    if (!id) {
      log("this run has not been committed");
      return undefined;
    }
    const rpc = this.rpc;
    const [c, block] = await Promise.all([readCommitment(rpc, config.doomRuns, id), readBlockNumber(rpc)]);
    const status = commitStatusOf(c, block);
    if (!status) {
      log(`commitment ${id.slice(0, 14)}… is unknown to the contract${run.submission.commitTx ? ` (transaction ${run.submission.commitTx} not included?)` : ""}`);
      return undefined;
    }
    await store.updateSubmission(run.id, patchFromCommitment(c, status));
    log(
      status === "proved"
        ? `commitment proved by ${c.prover.slice(0, 10)}… as run ${c.runId.slice(0, 14)}… (bounty paid)`
        : status === "expired"
          ? `commitment expired at block ${c.expiresAt} (now ${block}) and still unproved: the bounty can be reclaimed`
          : status === "reclaimed"
            ? "commitment reclaimed: the bounty was refunded"
            : `commitment pending: waiting for a prover, reclaimable from block ${c.expiresAt} (now ${block})`,
    );
    return status;
  }

  /** `reclaim(commitment_id)` once the expiry block is reached. */
  async reclaim(run: RunRecord): Promise<CommitOutcome> {
    const { config, store, log } = this.deps;
    const id = run.submission.commitmentId;
    if (!id) {
      log("this run has not been committed");
      return { choice: "none" };
    }
    const rpc = this.rpc;
    const [c, block] = await Promise.all([readCommitment(rpc, config.doomRuns, id), readBlockNumber(rpc)]);
    const status = commitStatusOf(c, block);
    if (status !== "expired") {
      if (status) await store.updateSubmission(run.id, patchFromCommitment(c, status));
      log(`nothing to reclaim: the commitment is ${status ?? "unknown"}${status === "pending" ? ` until block ${c.expiresAt} (now ${block})` : ""}`);
      return { choice: "none", commitmentId: id };
    }
    const signer = await this.deps.connectSigner(config, config.feeToken);
    if (BigInt(signer.address) !== BigInt(c.player)) {
      log(`only the player (${c.player.slice(0, 10)}…) can reclaim; connected as ${signer.address.slice(0, 10)}…`);
      return { choice: "none", commitmentId: id };
    }
    try {
      const call = reclaimCall(config.doomRuns, id);
      const estimate = await simulateCalls(rpc, [call], { sender: signer.address, label: "reclaim" });
      const [bound] = withPrices(estimate.bounds, estimate.prices);
      const { transactionHash } = await signer.execute([call], { bounds: bound!.bounds });
      await rpc.waitForReceipt(transactionHash);
      await store.updateSubmission(run.id, { commitStatus: "reclaimed" });
      log(`reclaimed ${c.bounty} in ${transactionHash}`);
      return { choice: "commit", commitmentId: id, transactionHash };
    } catch (e) {
      const error = (e as Error).message;
      log(`reclaim failed: ${error}`);
      return { choice: "none", commitmentId: id, error };
    }
  }
}

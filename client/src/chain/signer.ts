// SPDX-License-Identifier: Apache-2.0
/**
 * `Signer` — the one thing the orchestrator needs from a wallet.
 *
 * Everything else in `client/src/chain/` is pure: it builds calldata, simulates and prices. The
 * only privileged operation is "sign and broadcast this single invoke with *these* resource
 * bounds", and it is deliberately narrow so that the same sequence code runs under a Cartridge
 * Controller session in the browser (`controller.ts`) and under a devnet key in
 * `infra/submit` — which is what D20 asks for, the wrapper submitting whole batches with the
 * same code path as a player submitting their own.
 *
 * Bounds are an *argument*, never the signer's business: the whole point of R7-A1 is that the
 * bounds come from a simulation of the ordered sequence, and a wallet that re-estimates with its
 * own global ×1.5 puts two of the five verifier transactions over the 1.21e9 invoke cap (S5 §6).
 */

import type { Call, ResourceBounds } from "./rpc.js";

export interface ExecuteOptions {
  bounds: ResourceBounds;
  /** Tip in FRI. 0 by default: no tip market observed (S5 §6). */
  tip?: bigint;
}

export interface Signer {
  /** The address the transactions are sent from — and the address estimation must use. */
  readonly address: string;
  /** `devnet`, `controller`, … — displayed, and recorded in the receipts for the S5 §4.1 caveat. */
  readonly kind: string;
  /**
   * True when a paymaster covers the fee (R7-A4). The cost screen still shows the full cost:
   * a sponsored submission is not a free one, it is one somebody else pays for.
   */
  readonly sponsored?: boolean;
  /** Account class hash when the signer knows it — S5 §4.1 measured +19 % between classes. */
  classHash?(): Promise<string | undefined>;
  execute(calls: Call[], options: ExecuteOptions): Promise<{ transactionHash: string }>;
}

/**
 * The entrypoints a submission touches. A Controller session (or any policy-scoped wallet) must
 * be created with exactly these, or the sequence stalls mid-way asking for a manual signature —
 * which, in the middle of a 5-transaction fact, is the worst possible moment.
 */
export interface Policy {
  target: string;
  method: string;
  description: string;
}

export interface PolicyTargets {
  router: string;
  doomRuns: string;
}

export function submissionPolicies({ router, doomRuns }: PolicyTargets): Policy[] {
  return [
    { target: router, method: "begin", description: "Start verifying a proof (transcript phase)" },
    { target: router, method: "merkle", description: "Verify the Merkle decommitments" },
    { target: router, method: "answers", description: "Verify the OODS quotients" },
    { target: router, method: "fri", description: "Verify a chunk of the FRI walk" },
    { target: doomRuns, method: "submit_batch", description: "Record the games of a proved batch" },
    {
      target: doomRuns,
      method: "register_member",
      description: "Record a single game of a proved batch",
    },
  ];
}

/**
 * The entrypoints the open-prover commitment touches (D35, P4.7): `commit_run` and `reclaim`
 * on `DoomRuns`, and `approve` on the fee token so the escrow can be pulled. `feeToken` is
 * `DoomRuns.fee_token()`; without it (a page that only ever commits with a zero bounty) the
 * allowance policy is left out.
 */
export function commitPolicies({ doomRuns, feeToken }: { doomRuns: string; feeToken?: string }): Policy[] {
  const policies: Policy[] = [];
  if (feeToken) {
    policies.push({ target: feeToken, method: "approve", description: "Allow DoomRuns to escrow the bounty" });
  }
  policies.push(
    { target: doomRuns, method: "commit_run", description: "Commit a game's input log with its bounty" },
    { target: doomRuns, method: "reclaim", description: "Reclaim the bounty of an expired commitment" },
  );
  return policies;
}

/** Shape of the Cartridge Controller account object this package relies on (structural typing). */
export interface ControllerAccountLike {
  address: string;
  execute(
    calls: { contractAddress: string; entrypoint: string; calldata: string[] }[],
    details?: Record<string, unknown>,
  ): Promise<{ transaction_hash: string }>;
  getClassAt?(address: string): Promise<{ class_hash?: string } | undefined>;
}

/**
 * Wraps a Cartridge Controller account.
 *
 * The Controller is not imported here: `@cartridge/controller` is a browser SDK with its own
 * iframe/keychain plumbing, and this package must stay importable from Node (the CLI) and from
 * tests. The UI connects the Controller and hands the resulting account object over — the
 * `account.execute(calls, details)` shape starknet.js and the Controller share.
 *
 * `details` carries the bounds straight through as `resourceBounds`, so the wallet does not
 * re-estimate (see the note at the top of this file).
 */
export class ControllerSigner implements Signer {
  readonly kind = "controller";

  constructor(
    private readonly account: ControllerAccountLike,
    readonly sponsored: boolean = false,
  ) {}

  get address(): string {
    return this.account.address;
  }

  async classHash(): Promise<string | undefined> {
    const cls = await this.account.getClassAt?.(this.account.address);
    return cls?.class_hash;
  }

  async execute(calls: Call[], options: ExecuteOptions): Promise<{ transactionHash: string }> {
    const res = await this.account.execute(calls, {
      version: 3,
      resourceBounds: options.bounds,
      tip: options.tip ?? 0n,
    });
    return { transactionHash: res.transaction_hash };
  }
}

/** A signer that refuses to send: the "keep offline" path (C6) and `--dry-run`. */
export class ReadOnlySigner implements Signer {
  readonly kind = "read-only";

  constructor(readonly address: string) {}

  execute(): Promise<{ transactionHash: string }> {
    return Promise.reject(new Error("read-only signer: nothing is sent"));
  }
}

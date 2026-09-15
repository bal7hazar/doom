// SPDX-License-Identifier: Apache-2.0
/**
 * Connecting a Cartridge Controller, and the session it needs.
 *
 * The Controller is loaded **dynamically** and typed structurally: `@cartridge/controller` is a
 * browser SDK (iframe keychain, WASM) that `client/src/chain/` must not drag into Node, the CLI
 * or the tests. Everything below the `Signer` interface is therefore unaware it exists.
 *
 * **Why a session matters here and not elsewhere.** A submission is 6–8 dependent transactions
 * that must go out back to back; stopping on transaction four to ask for a manual signature is
 * the worst possible moment, because the checkpoint is half-way through a fact. A session
 * pre-approves exactly the six entrypoints of `submissionPolicies()` — four on the router, two on
 * `DoomRuns` — and nothing else: no token transfer, no approval, no other contract. The session
 * cannot spend anything beyond the fees of those calls.
 *
 * **Sponsoring (R7-A4)** is a flag here and a policy elsewhere: when the season sponsors
 * submissions the Controller's paymaster pays, `Signer.sponsored` is true, and the cost screen
 * keeps showing the full cost with the payer named. A sponsored submission is not a free one.
 */

import { commitPolicies, ControllerSigner, submissionPolicies, type Policy } from "../chain/signer.js";

/** The subset of `@cartridge/controller` this module uses. */
interface ControllerLike {
  connect(): Promise<{ address: string } | undefined>;
  account?: {
    address: string;
    execute(calls: unknown[], details?: Record<string, unknown>): Promise<{ transaction_hash: string }>;
  };
  disconnect?(): Promise<void>;
}

export interface ConnectOptions {
  router: string;
  doomRuns: string;
  /** Cartridge chain id / RPC, passed through to the SDK unchanged. */
  chains?: { rpcUrl: string }[];
  defaultChainId?: string;
  /** Season sponsoring (R7-A4): the paymaster pays, the cost is still displayed. */
  sponsored?: boolean;
  /**
   * P4.7: also pre-approve the open-prover commitment (`commit_run`, `reclaim`, and `approve`
   * on `feeToken` when given), so an end-of-game "Commit" is one signature, not three.
   */
  commit?: { feeToken?: string };
  /** Module specifier, overridable in tests. */
  moduleSpecifier?: string;
}

export interface ConnectResult {
  signer: ControllerSigner;
  policies: Policy[];
  address: string;
}

/**
 * The policies a session must carry, in the shape the Controller SDK expects
 * (`{ contracts: { <address>: { methods: [{ name, entrypoint, description }] } } }`).
 */
export function sessionPolicies(
  router: string,
  doomRuns: string,
  extra: Policy[] = [],
): {
  contracts: Record<string, { methods: { name: string; entrypoint: string; description: string }[] }>;
} {
  const contracts: Record<
    string,
    { methods: { name: string; entrypoint: string; description: string }[] }
  > = {};
  for (const p of [...submissionPolicies({ router, doomRuns }), ...extra]) {
    const entry = (contracts[p.target] ??= { methods: [] });
    entry.methods.push({ name: p.method, entrypoint: p.method, description: p.description });
  }
  return { contracts };
}

/**
 * Connects a Controller and returns it as a `Signer`.
 *
 * Throws — rather than falling back to a keyless flow — when the SDK is absent: a submission
 * that silently loses its session would stall mid-fact, which is exactly what the session is
 * there to prevent.
 */
export async function connectController(options: ConnectOptions): Promise<ConnectResult> {
  const specifier = options.moduleSpecifier ?? "@cartridge/controller";
  // The specifier is a variable on purpose: neither TypeScript nor the bundler should try to
  // resolve the Controller SDK when the app is built without it.
  const mod: any = await import(/* @vite-ignore */ specifier);
  const Controller = mod.default ?? mod.Controller;
  if (!Controller) throw new Error(`${specifier} does not export a Controller`);

  const extra = options.commit ? commitPolicies({ doomRuns: options.doomRuns, ...options.commit }) : [];
  const controller: ControllerLike = new Controller({
    policies: sessionPolicies(options.router, options.doomRuns, extra),
    ...(options.chains ? { chains: options.chains } : {}),
    ...(options.defaultChainId ? { defaultChainId: options.defaultChainId } : {}),
  });

  const connected = await controller.connect();
  const account = controller.account;
  if (!connected || !account) throw new Error("the Controller did not return an account");

  return {
    signer: new ControllerSigner(account as never, options.sponsored ?? false),
    policies: [...submissionPolicies({ router: options.router, doomRuns: options.doomRuns }), ...extra],
    address: account.address,
  };
}

// SPDX-License-Identifier: Apache-2.0
/**
 * The commit screen (D35, P4.7): what committing a game to the open prover costs, and the
 * bounty the player puts in escrow for whoever proves it.
 *
 * It is the cost screen's little sibling and shares its stylesheet, its estimator and its
 * pricing (`simulateCalls` → `priceEstimate` / `withPrices`, the same R7-A1 margins): one
 * multicall — `approve` on the fee token when the bounty is non-zero, then `commit_run` — is
 * simulated from the signing account, priced per the latest block with the fiat quote and its
 * timestamp, and the player answers one of:
 *
 * * **Commit** — sign the multicall, wait for the receipt, check the `RunCommitted` event
 *   against the id computed locally;
 * * **Keep offline** — nothing leaves the device (C6 stays the default);
 * * **Cancel** — close, nothing sent, nothing recorded beyond the locally computed id.
 *
 * The bounty is editable on the screen; changing it re-simulates, because the allowance call
 * appears or disappears with it and the fee follows.
 */

import {
  buildCommitCalls,
  findRunCommitted,
  formatTokenAmount,
  parseTokenAmount,
  simulateCalls,
  type CommitRunArgs,
  type RunCommittedEvent,
} from "../chain/commit.js";
import { priceEstimate, withPrices, type PricedEstimate, type SequenceEstimate } from "../chain/estimate.js";
import { CachedPriceSource, CoinGeckoSource, type PriceSource } from "../chain/prices.js";
import type { RpcClient } from "../chain/rpc.js";
import type { Signer } from "../chain/signer.js";
import { esc, gas, injectCostScreenStyle, strk } from "./costScreen.js";

export type CommitChoice = "commit" | "offline" | "cancel";

export interface CommitScreenOptions {
  rpc: RpcClient;
  signer: Signer;
  doomRuns: string;
  /** `fee_token()`; required as soon as the bounty is non-zero. */
  feeToken?: string;
  args: Omit<CommitRunArgs, "bounty">;
  /** Initial bounty, in the fee token's smallest unit. */
  bounty: bigint;
  /** The id the contract will assign, computed locally (`commitmentIdOf`). */
  commitmentId: string;
  priceSource?: PriceSource;
  chainId?: string;
  onChoice?: (choice: CommitChoice, bounty: bigint) => void;
  onDone?: (result: { transactionHash: string; event?: RunCommittedEvent }) => void;
  onFailed?: (error: string) => void;
}

interface ScreenState {
  phase: "estimating" | "review" | "committing" | "done" | "failed";
  bounty: bigint;
  estimate?: SequenceEstimate;
  priced?: PricedEstimate;
  error?: string;
  transactionHash?: string;
  event?: RunCommittedEvent;
}

const EXPLORERS: Record<string, string> = {
  "0x534e5f4d41494e": "https://voyager.online/tx/",
  "0x534e5f5345504f4c4941": "https://sepolia.voyager.online/tx/",
};

export class CommitScreen {
  private readonly el: HTMLElement;
  private readonly options: CommitScreenOptions;
  private state: ScreenState;
  private chainId = "";

  constructor(el: HTMLElement, options: CommitScreenOptions) {
    this.el = el;
    this.options = options;
    this.state = { phase: "estimating", bounty: options.bounty };
    this.el.classList.add("cost-screen", "commit-screen");
    injectCostScreenStyle(el.ownerDocument);
  }

  /** The current bounty, as edited on the screen. */
  get bounty(): bigint {
    return this.state.bounty;
  }

  private calls() {
    return buildCommitCalls({
      ...this.options.args,
      bounty: this.state.bounty,
      doomRuns: this.options.doomRuns,
      ...(this.options.feeToken ? { feeToken: this.options.feeToken } : {}),
    });
  }

  /** Simulates the multicall and shows the review. Safe to call again with a new bounty. */
  async open(): Promise<void> {
    this.state = { ...this.state, phase: "estimating" };
    this.render();
    try {
      this.chainId = this.options.chainId ?? (await this.options.rpc.chainId());
      const estimate = await simulateCalls(this.options.rpc, this.calls(), {
        sender: this.options.signer.address,
        label: "commit_run",
      });
      const source = this.options.priceSource ?? new CachedPriceSource(new CoinGeckoSource());
      const quote = await source.quote().catch(() => null);
      this.state = { ...this.state, phase: "review", estimate, priced: priceEstimate(estimate, quote) };
    } catch (e) {
      this.state = { ...this.state, phase: "failed", error: (e as Error).message };
      this.options.onFailed?.((e as Error).message);
    }
    this.render();
  }

  /** The "commit" path: sign, wait for the receipt, read `RunCommitted` back. */
  async commit(): Promise<void> {
    const { estimate } = this.state;
    if (!estimate) return;
    this.state = { ...this.state, phase: "committing" };
    this.render();
    try {
      const [bound] = withPrices(estimate.bounds, estimate.prices);
      const { transactionHash } = await this.options.signer.execute(this.calls(), { bounds: bound!.bounds });
      this.state = { ...this.state, transactionHash };
      this.render();
      const receipt = await this.options.rpc.waitForReceipt(transactionHash);
      const event = findRunCommitted(receipt.events, this.options.doomRuns);
      this.state = { ...this.state, phase: "done", transactionHash, ...(event ? { event } : {}) };
      this.options.onDone?.({ transactionHash, ...(event ? { event } : {}) });
    } catch (e) {
      this.state = { ...this.state, phase: "failed", error: (e as Error).message };
      this.options.onFailed?.((e as Error).message);
    }
    this.render();
  }

  private choose(choice: CommitChoice): void {
    this.options.onChoice?.(choice, this.state.bounty);
    if (choice === "commit") void this.commit();
  }

  private explorer(txHash: string): string {
    const base = EXPLORERS[this.chainId];
    return base
      ? `<a href="${base}${esc(txHash)}" target="_blank" rel="noreferrer">${esc(txHash.slice(0, 12))}…</a>`
      : `<code>${esc(txHash)}</code>`;
  }

  private render(): void {
    const s = this.state;
    const bountyText = formatTokenAmount(s.bounty);
    if (s.phase === "estimating") {
      this.el.innerHTML =
        `<h2>Working out what committing costs</h2>` +
        `<p class="sub">Simulating the transaction from your own account — nothing is signed.</p>`;
      return;
    }
    if (s.phase === "failed") {
      this.el.innerHTML =
        `<h2>The commitment stopped</h2>` +
        `<p class="warn">${esc(s.error ?? "unknown error")}</p>` +
        `<p class="note">Nothing was recorded on chain unless a transaction hash is shown below; the game ` +
        `and its journal stay on this device and can be exported.</p>` +
        (s.transactionHash ? `<p class="note">transaction ${this.explorer(s.transactionHash)}</p>` : "") +
        `<div class="choices"><button class="primary" data-act="retry">Try again</button>` +
        `<button data-act="offline">Keep offline</button><button data-act="cancel">Close</button></div>`;
      this.bind();
      return;
    }
    if (s.phase === "committing" || s.phase === "done") {
      const done = s.phase === "done";
      this.el.innerHTML =
        `<h2>${done ? "Your game is committed" : "Committing"}</h2>` +
        `<p class="sub">${
          done
            ? `Any prover may now prove it${s.bounty > 0n ? ` and collect the ${bountyText} STRK bounty` : ""}.`
            : s.transactionHash
              ? "Waiting for the receipt…"
              : "Waiting for your wallet…"
        }</p>` +
        (s.transactionHash ? `<p class="note">transaction ${this.explorer(s.transactionHash)}</p>` : "") +
        (s.event
          ? `<p class="note">commitment <code>${esc(s.event.commitmentId.slice(0, 14))}…</code>, ` +
            `${s.event.tics} tics in ${s.event.nChunks} log chunk(s), reclaimable from block ${s.event.expiresAt}</p>`
          : "") +
        (done ? `<div class="choices"><button data-act="cancel">Close</button></div>` : "");
      this.bind();
      return;
    }

    const { priced } = s;
    if (!priced) return;
    const q = priced.quote;
    const step = priced.steps[0]!;
    const sponsored = this.options.signer.sponsored === true;
    this.el.innerHTML =
      `<h2>Commit this game to the open prover</h2>` +
      `<p class="sub">${this.options.args.tics} tics, ${this.options.args.packed.length} packed felt(s), one transaction` +
      `${s.bounty > 0n ? " (allowance + commitment)" : ""}. Nobody has to prove it in this browser.</p>` +
      `<p class="total">${strk(priced.totalStrk)} STRK <span class="fiat">fee</span>` +
      (s.bounty > 0n ? ` + ${esc(bountyText)} STRK <span class="fiat">bounty in escrow</span>` : "") +
      (q ? ` <span class="fiat">≈ $${priced.totalUsd!.toFixed(2)} fee</span>` : "") +
      `</p>` +
      (q
        ? `<p class="note">1 STRK = $${q.usd} — ${esc(q.source)}, read ${esc(new Date(q.at).toUTCString())}</p>`
        : `<p class="note warn">No fiat quote available; the STRK figure is exact, the conversion is not shown.</p>`) +
      (sponsored
        ? `<p class="ok">The fee is sponsored: you will not be charged for it. The bounty is yours to escrow.</p>`
        : "") +
      `<table><thead><tr><th>transaction</th><th>L2 gas</th><th>STRK</th><th>≈</th></tr></thead>` +
      `<tbody><tr><td>${s.bounty > 0n ? "Allow the escrow, then commit the game" : "Commit the game"}</td>` +
      `<td>${gas(step.l2Gas)}</td><td>${strk(step.strk)}</td>` +
      `<td class="fiat">${step.usd === null ? "—" : "$" + step.usd.toFixed(3)}</td></tr></tbody></table>` +
      `<p class="note"><label>Bounty (STRK, paid to whoever proves the game; refundable after expiry) ` +
      `<input type="text" data-field="bounty" value="${esc(bountyText)}" size="10" /></label> ` +
      `<button data-act="reprice">Update</button></p>` +
      `<p class="note">Anyone can prove a committed game — no prover is bound to yours. ` +
      `A zero bounty relies on a sponsor's node picking it up.</p>` +
      `<div class="choices">` +
      `<button class="primary" data-act="commit">Commit — ${strk(priced.totalStrk)} STRK` +
      `${s.bounty > 0n ? ` + ${esc(bountyText)} bounty` : ""}</button>` +
      `<button data-act="offline">Keep offline</button>` +
      `<button data-act="cancel">Cancel</button>` +
      `</div>` +
      `<p class="note">“Keep offline” stores the game on this device; it stays exportable and committable later.</p>`;
    this.bind();
  }

  private bind(): void {
    for (const button of this.el.querySelectorAll<HTMLButtonElement>("button[data-act]")) {
      button.addEventListener("click", () => {
        const act = button.dataset["act"];
        if (act === "retry") void this.open();
        else if (act === "commit") this.choose("commit");
        else if (act === "offline") this.choose("offline");
        else if (act === "cancel") this.choose("cancel");
        else if (act === "reprice") this.reprice();
      });
    }
  }

  private reprice(): void {
    const input = this.el.querySelector<HTMLInputElement>('input[data-field="bounty"]');
    if (!input) return;
    let bounty: bigint;
    try {
      bounty = parseTokenAmount(input.value);
    } catch {
      input.setCustomValidity("a decimal STRK amount, e.g. 0.5");
      input.reportValidity?.();
      return;
    }
    if (bounty > 0n && !this.options.feeToken) {
      this.state = { ...this.state, phase: "failed", error: "a bounty needs the fee token address (fee_token())" };
      this.render();
      return;
    }
    this.state = { ...this.state, bounty };
    void this.open();
  }
}

// SPDX-License-Identifier: Apache-2.0
/**
 * The cost screen (C5, R7-A2) and the submission progress that follows it.
 *
 * What the player is asked is not "sign 7 transactions?" but "is this worth it now?", so the
 * screen is built around the three answers of C6:
 *
 * * **submit now** — play the sequence;
 * * **wait** — the price is above twice the 24 h median, or simply higher than the player likes;
 *   nothing is lost, the proof and the batch stay on disk and the same `proof_id` resumes later;
 * * **keep offline** — never submit; the game stays local and provable.
 *
 * Three things the screen must be honest about, and is:
 *
 * 1. **the fiat figure is a quote, not a price** — it carries the time it was read (S5 §5: since
 *    v0.14.3 the L2 base price follows the STRK price, so the dollar figure is the steadier of
 *    the two and a stale quote misleads);
 * 2. **a sponsored submission is not a free one** (R7-A4) — the full cost is displayed with the
 *    payer named;
 * 3. **the spike warning can be unavailable** — a fresh client has no local price history, and
 *    "we cannot tell" is displayed as such rather than as "looks normal" (`median.ts`).
 *
 * The screen renders into an element the caller owns and injects its own stylesheet once, so it
 * can be dropped into the game shell without touching `index.html`.
 */

import {
  priceEstimate,
  simulateSequence,
  withPrices,
  type PricedEstimate,
  type SequenceEstimate,
  type StepBounds,
} from "../chain/estimate.js";
import { GasPriceMedian, type PriceVerdict } from "../chain/median.js";
import { CachedPriceSource, CoinGeckoSource, type PriceSource } from "../chain/prices.js";
import type { RpcClient } from "../chain/rpc.js";
import {
  resumePoint,
  runSequence,
  type ResumePoint,
  type StepProgress,
  type SubmissionSequence,
} from "../chain/sequence.js";
import type { Signer } from "../chain/signer.js";
import { LocalEchoStore, LocalSampleStore } from "./browserStores.js";

/** Explorers by chain id (`starknet_chainId`). A devnet has none: the hash is shown bare. */
const EXPLORERS: Record<string, string> = {
  "0x534e5f4d41494e": "https://voyager.online/tx/", // SN_MAIN
  "0x534e5f5345504f4c4941": "https://sepolia.voyager.online/tx/", // SN_SEPOLIA
};

export type Choice = "submit" | "wait" | "offline";

export interface CostScreenOptions {
  rpc: RpcClient;
  sequence: SubmissionSequence;
  signer: Signer;
  /** Fiat source; CoinGecko behind a 5-minute cache by default (R7-A2). */
  priceSource?: PriceSource;
  /** Called when the player picks one of the three answers of C6. */
  onChoice?: (choice: Choice) => void;
  /** Called once the sequence finishes, with the fact if one was registered. */
  onDone?: (result: { fact?: string; steps: StepProgress[] }) => void;
  /**
   * Called when the estimate or the sequence stops on an error. The screen stays up with its
   * "Resume" button; this only lets the caller log and record the stop.
   */
  onFailed?: (error: string) => void;
  /** Chain id, for the explorer links. Read from the node when omitted. */
  chainId?: string;
}

interface ScreenState {
  phase: "estimating" | "review" | "submitting" | "done" | "failed";
  estimate?: SequenceEstimate;
  priced?: PricedEstimate;
  bounds?: StepBounds[];
  verdict?: PriceVerdict;
  resume?: ResumePoint;
  progress: Map<string, StepProgress>;
  error?: string;
  fact?: string;
}

const STYLE_ID = "hellproof-cost-screen-style";
const CSS = `
.cost-screen { background: var(--panel, rgba(12,10,9,.92)); color: var(--fg, #d8d2c4);
  font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  padding: 16px 18px; max-width: 720px; }
.cost-screen h2 { margin: 0 0 4px; font-size: 15px; letter-spacing: .04em; }
.cost-screen .sub { color: var(--dim, #8d8578); margin: 0 0 12px; }
.cost-screen table { width: 100%; border-collapse: collapse; margin-bottom: 10px; }
.cost-screen th, .cost-screen td { text-align: right; padding: 2px 6px; white-space: nowrap; }
.cost-screen th:first-child, .cost-screen td:first-child { text-align: left; }
.cost-screen thead th { color: var(--dim, #8d8578); font-weight: normal;
  border-bottom: 1px solid rgba(141,133,120,.3); }
.cost-screen tfoot td { border-top: 1px solid rgba(141,133,120,.3); font-weight: bold; }
.cost-screen .total { font-size: 18px; }
.cost-screen .fiat { color: var(--dim, #8d8578); }
.cost-screen .warn { color: var(--bad, #eb4d4b); }
.cost-screen .ok { color: var(--ok, #6ab04c); }
.cost-screen .note { color: var(--dim, #8d8578); margin: 6px 0; }
.cost-screen .choices { display: flex; gap: 8px; margin-top: 14px; flex-wrap: wrap; }
.cost-screen button { font: inherit; color: var(--fg, #d8d2c4); background: transparent;
  border: 1px solid rgba(141,133,120,.5); padding: 7px 14px; cursor: pointer; }
.cost-screen button.primary { border-color: var(--accent, #c0392b); color: #fff;
  background: var(--accent, #c0392b); }
.cost-screen button:disabled { opacity: .45; cursor: default; }
.cost-screen .steps li { list-style: none; display: flex; justify-content: space-between; gap: 12px;
  padding: 2px 0; }
.cost-screen .steps { padding: 0; margin: 8px 0; }
.cost-screen a { color: var(--fg, #d8d2c4); }
`;

function injectStyle(doc: Document): void {
  if (doc.getElementById(STYLE_ID)) return;
  const style = doc.createElement("style");
  style.id = STYLE_ID;
  style.textContent = CSS;
  doc.head.append(style);
}

const esc = (s: string): string =>
  s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
const strk = (n: number): string => n.toFixed(n < 1 ? 4 : 2);
const gas = (n: bigint): string => n.toLocaleString("en-US");

/** Human labels for the entrypoints — nobody outside this repo knows what `fri2` is. */
const LABELS: Record<string, string> = {
  begin: "Proof transcript",
  merkle: "Merkle decommitments",
  answers: "Quotient answers",
  submit_batch: "Record the games",
  register_member: "Record the game",
};
const humanLabel = (label: string): string =>
  LABELS[label] ?? (label.startsWith("fri") ? `FRI walk, part ${label.slice(3)}` : label);

export class CostScreen {
  private readonly el: HTMLElement;
  private readonly options: CostScreenOptions;
  private readonly median: GasPriceMedian;
  private readonly echoes = new LocalEchoStore();
  private state: ScreenState = { phase: "estimating", progress: new Map() };
  private chainId = "";

  constructor(el: HTMLElement, options: CostScreenOptions) {
    this.el = el;
    this.options = options;
    this.median = new GasPriceMedian(new LocalSampleStore());
    this.el.classList.add("cost-screen");
    injectStyle(el.ownerDocument);
  }

  /**
   * Estimates the sequence and shows the screen.
   *
   * Resumption is resolved *first*: a sequence that already paid for three phases must be priced
   * for what is left, not for what it would have cost from scratch — showing the full price
   * again would be asking the player to approve a bill they have already partly paid.
   */
  async open(): Promise<void> {
    this.render();
    try {
      this.chainId = this.options.chainId ?? (await this.options.rpc.chainId());
      const resume = await resumePoint(
        this.options.rpc,
        this.options.sequence,
        this.options.signer.address,
        this.echoes,
      );
      const estimate = await simulateSequence(this.options.rpc, this.options.sequence, {
        sender: this.options.signer.address,
        fromPhase: resume.nextPhase,
        ...(resume.echo
          ? { echoes: [...new Array<null>(resume.nextPhase).fill(null), resume.echo] }
          : {}),
        onPrefix: () => this.render(),
      });

      this.median.record(estimate.prices.l2GasPriceFri, estimate.prices.timestamp);
      const source =
        this.options.priceSource ?? new CachedPriceSource(new CoinGeckoSource());
      const quote = await source.quote().catch(() => null);

      this.state = {
        ...this.state,
        phase: "review",
        resume,
        estimate,
        priced: priceEstimate(estimate, quote),
        bounds: withPrices(estimate.bounds, estimate.prices),
        verdict: this.median.verdict(estimate.prices.l2GasPriceFri),
      };
    } catch (e) {
      this.state = { ...this.state, phase: "failed", error: (e as Error).message };
      this.options.onFailed?.((e as Error).message);
    }
    this.render();
  }

  /** The "submit now" path. Safe to call again after a failure: it resumes. */
  async submit(): Promise<void> {
    const { bounds, resume } = this.state;
    if (!bounds || !resume) return;
    this.state = { ...this.state, phase: "submitting", progress: new Map() };
    this.render();
    try {
      const result = await runSequence(this.options.rpc, this.options.sequence, {
        signer: this.options.signer,
        // `bounds[i]` is indexed by absolute step; a resumed estimate starts at `nextPhase`.
        bounds: [
          ...new Array<StepBounds["bounds"]>(resume.nextPhase).fill(bounds[0]!.bounds),
          ...bounds.map((b) => b.bounds),
        ],
        store: this.echoes,
        onProgress: (p) => {
          this.state.progress.set(p.label, p);
          this.render();
        },
      });
      if (result.fact) this.echoes.clear(this.options.sequence.proofId);
      this.state = { ...this.state, phase: "done", ...(result.fact ? { fact: result.fact } : {}) };
      this.options.onDone?.(result);
    } catch (e) {
      // The checkpoint is wherever it stopped: re-opening the screen resumes from there, and
      // nothing that was paid for is paid for twice.
      this.state = { ...this.state, phase: "failed", error: (e as Error).message };
      this.options.onFailed?.((e as Error).message);
    }
    this.render();
  }

  private choose(choice: Choice): void {
    this.options.onChoice?.(choice);
    if (choice === "submit") void this.submit();
  }

  private explorer(txHash: string): string {
    const base = EXPLORERS[this.chainId];
    return base
      ? `<a href="${base}${esc(txHash)}" target="_blank" rel="noreferrer">${esc(txHash.slice(0, 12))}…</a>`
      : `<span class="fiat">${esc(txHash.slice(0, 12))}…</span>`;
  }

  private renderTable(priced: PricedEstimate, bounds: StepBounds[]): string {
    const rows = priced.steps
      .map((s, i) => {
        const b = bounds[i];
        const cap = b?.overCap
          ? ` <span class="warn">over the per-transaction limit</span>`
          : "";
        return (
          `<tr><td>${esc(this.stepName(s.label, s.phase))}</td>` +
          `<td>${gas(s.l2Gas)}</td>` +
          `<td>${strk(s.strk)}</td>` +
          `<td class="fiat">${s.usd === null ? "—" : "$" + s.usd.toFixed(3)}</td>${cap}</tr>`
        );
      })
      .join("");
    return (
      `<table><thead><tr><th>transaction</th><th>L2 gas</th><th>STRK</th><th>≈</th></tr></thead>` +
      `<tbody>${rows}</tbody>` +
      `<tfoot><tr><td>total</td><td></td><td>${strk(priced.totalStrk)}</td>` +
      `<td class="fiat">${priced.totalUsd === null ? "—" : "$" + priced.totalUsd.toFixed(2)}</td>` +
      `</tr></tfoot></table>`
    );
  }

  private renderVerdict(verdict: PriceVerdict): string {
    switch (verdict.kind) {
      case "high":
        return (
          `<p class="warn">The network is expensive right now — ${verdict.ratio.toFixed(1)}× the ` +
          `median of the last 24 hours. Waiting costs nothing: your game is saved and can be ` +
          `submitted later.</p>`
        );
      case "normal":
        return (
          `<p class="ok">Network price is normal (${verdict.ratio.toFixed(2)}× the 24 h median, ` +
          `${verdict.samples} samples).</p>`
        );
      default:
        return (
          `<p class="note">No price history yet on this device, so we cannot tell whether this ` +
          `is a spike (${esc(verdict.reason)}).</p>`
        );
    }
  }

  /**
   * The consumer step keeps the label `submit_batch` whatever it calls (`sequence.ts`); the
   * per-player fallback is told apart by its entrypoint, and the player must see which one they
   * are paying for.
   */
  private stepName(label: string, phase: "verifier" | "consumer"): string {
    return humanLabel(phase === "consumer" ? this.options.sequence.consumer.call.entrypoint : label);
  }

  private renderSteps(): string {
    const all: [string, "verifier" | "consumer"][] = [
      ...this.options.sequence.phases.map((p): [string, "verifier"] => [p.label, "verifier"]),
      [this.options.sequence.consumer.label, "consumer"],
    ];
    const items = all
      .map(([label, phase]) => {
        const p = this.state.progress.get(label);
        const right = !p
          ? '<span class="fiat">queued</span>'
          : p.state === "skipped"
            ? '<span class="ok">already on chain</span>'
            : p.state === "sending"
              ? "sending…"
              : p.state === "accepted"
                ? this.explorer(p.transactionHash ?? "")
                : `<span class="warn">${esc(p.error ?? "failed")}</span>`;
        return `<li><span>${esc(this.stepName(label, phase))}</span>${right}</li>`;
      })
      .join("");
    return `<ul class="steps">${items}</ul>`;
  }

  private render(): void {
    const s = this.state;
    if (s.phase === "estimating") {
      this.el.innerHTML =
        `<h2>Working out what this costs</h2>` +
        `<p class="sub">Simulating the transactions from your own account — nothing is signed.</p>`;
      return;
    }
    if (s.phase === "failed") {
      this.el.innerHTML =
        `<h2>The submission stopped</h2>` +
        `<p class="warn">${esc(s.error ?? "unknown error")}</p>` +
        `<p class="note">Nothing that was already accepted has to be paid for again: the ` +
        `verifier keeps a checkpoint for this proof, and resuming continues from there.</p>` +
        this.renderSteps() +
        `<div class="choices"><button class="primary" data-act="retry">Resume</button>` +
        `<button data-act="offline">Keep offline</button></div>`;
      this.bind();
      return;
    }
    if (s.phase === "submitting" || s.phase === "done") {
      const done = s.phase === "done";
      this.el.innerHTML =
        `<h2>${done ? "Your game is on chain" : "Submitting"}</h2>` +
        `<p class="sub">${
          done
            ? s.fact
              ? `Proof accepted — fact <code>${esc(s.fact.slice(0, 14))}…</code>`
              : "Recorded."
            : "Each step is one transaction; the next one needs the previous one's result."
        }</p>` +
        this.renderSteps() +
        (done ? "" : `<p class="note">Closing this page is safe: the submission resumes.</p>`);
      return;
    }

    const { priced, bounds, verdict, resume } = s;
    if (!priced || !bounds || !verdict) return;
    const q = priced.quote;
    const resumed = (resume?.nextPhase ?? 0) > 0;
    const sponsored = this.options.signer.sponsored === true;

    this.el.innerHTML =
      `<h2>Submit this game to Starknet</h2>` +
      `<p class="sub">${priced.steps.length} transaction${priced.steps.length > 1 ? "s" : ""}` +
      (resumed
        ? ` — ${resume!.nextPhase} already paid for and skipped`
        : "") +
      `. Proving is done; this is the on-chain part.</p>` +
      `<p class="total">${strk(priced.totalStrk)} STRK` +
      (q ? ` <span class="fiat">≈ $${priced.totalUsd!.toFixed(2)} / €${priced.totalEur!.toFixed(2)}</span>` : "") +
      `</p>` +
      (q
        ? `<p class="note">1 STRK = $${q.usd} — ${esc(q.source)}, read ${esc(
            new Date(q.at).toUTCString(),
          )}</p>`
        : `<p class="note warn">No fiat quote available; the STRK figure is exact, the ` +
          `conversion is not shown.</p>`) +
      (sponsored
        ? `<p class="ok">This submission is sponsored: you will not be charged. The cost is ` +
          `shown because somebody pays it.</p>`
        : "") +
      this.renderTable(priced, bounds) +
      this.renderVerdict(verdict) +
      `<p class="note">At the cheapest the network ever gets, the same work would cost ` +
      `${strk(priced.floorStrk)} STRK.</p>` +
      `<div class="choices">` +
      `<button class="primary" data-act="submit">Submit now — ${strk(priced.totalStrk)} STRK</button>` +
      `<button data-act="wait">${
        verdict.kind === "high" ? "Wait, the price is high" : "Wait for a better price"
      }</button>` +
      `<button data-act="offline">Keep offline</button>` +
      `</div>` +
      `<p class="note">“Keep offline” stores the game and its proof on this device. It stays ` +
      `submittable later, under the same proof id.</p>`;
    this.bind();
  }

  private bind(): void {
    for (const button of this.el.querySelectorAll<HTMLButtonElement>("button[data-act]")) {
      button.addEventListener("click", () => {
        const act = button.dataset["act"];
        if (act === "retry") void this.submit();
        else if (act === "submit") this.choose("submit");
        else if (act === "wait") this.choose("wait");
        else if (act === "offline") this.choose("offline");
      });
    }
  }
}

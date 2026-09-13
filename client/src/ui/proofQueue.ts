/**
 * The proof-queue panel and the end-of-game flow (roadmap **P2.6** / **P3.2**).
 *
 * Two things a player has to be able to see while a game is being proved in the
 * background, because both are minutes long and neither is reversible:
 *
 * - **the queue** — which segment is where, how long it took, how much memory it
 *   peaked at, and whether it had to be retried single-threaded (R1-A8);
 * - **the choice** — prove now, verify locally, keep the run offline, or submit
 *   it. The on-chain submission screen itself is **P4.3**; this leaves the hook
 *   ({@link EndGameActions.onSubmit}) and says what it will cost in words.
 *
 * Plain DOM, like the rest of `src/ui/`: no framework, and the panel is a
 * `<section>` the caller places wherever it wants.
 */
import { statusName } from "../prove/chain.js";
import type { PipelineState } from "../prove/pipeline.js";
import type { PipelineEvent, SegmentRecord } from "../prove/types.js";

export interface EndGameActions {
  /** Start (or resume) proving the run. */
  onProve?: () => void;
  /** Re-verify every stored proof and the whole chain, from the database. */
  onVerify?: () => void;
  /** C6: keep the run on this machine; no upload until the flag is cleared. */
  onKeepOffline?: (keepOffline: boolean) => void;
  /** Upload to the wrapper. The on-chain step that follows is P4.3. */
  onSubmit?: () => void;
  /** Write the run out as a `.hellproof` file. */
  onExport?: () => void;
  /** Read one back in. */
  onImport?: (file: File) => void;
  /** The explicit reset C6 demands. */
  onReset?: () => void;
}

export interface ProofQueuePanelOptions {
  actions?: EndGameActions;
  /** Shown in the header; the run id by default. */
  title?: string;
}

function fmtMs(ms: number | undefined): string {
  if (ms === undefined) return "—";
  return ms >= 1000 ? `${(ms / 1000).toFixed(1)} s` : `${Math.round(ms)} ms`;
}

function fmtBytes(bytes: number | undefined): string {
  if (!bytes) return "—";
  if (bytes >= 2 ** 30) return `${(bytes / 2 ** 30).toFixed(2)} GiB`;
  if (bytes >= 2 ** 20) return `${(bytes / 2 ** 20).toFixed(1)} MiB`;
  return `${bytes} B`;
}

const STAGE_LABEL: Record<SegmentRecord["stage"], string> = {
  planned: "queued",
  executing: "executing",
  proving: "proving",
  verifying: "verifying",
  proved: "proved",
  failed: "failed",
};

export class ProofQueuePanel {
  readonly element: HTMLElement;
  private readonly tableBody: HTMLElement;
  private readonly summary: HTMLElement;
  private readonly logEl: HTMLElement;
  private readonly keepOffline: HTMLInputElement;
  private readonly actions: EndGameActions;
  private readonly liveStage = new Map<number, { stage: string; elapsedMs: number; detail?: string }>();
  private segments: readonly SegmentRecord[] = [];
  private state: PipelineState | null = null;
  private lastQuota: string | null = null;

  constructor(options: ProofQueuePanelOptions = {}) {
    this.actions = options.actions ?? {};
    const root = document.createElement("section");
    root.className = "panel proof-queue";
    root.innerHTML = `
      <header>
        <h2>Proof queue</h2>
        <span class="proof-queue-summary"></span>
      </header>
      <div class="proof-queue-scroll">
        <table>
          <thead>
            <tr><th>#</th><th>tics</th><th>steps</th><th>rows</th><th>stage</th>
                <th>prove</th><th>verify</th><th>peak</th><th>thr</th><th>proof</th></tr>
          </thead>
          <tbody></tbody>
        </table>
      </div>
      <div class="proof-queue-actions">
        <button data-act="prove">Prove</button>
        <button data-act="verify">Verify locally</button>
        <button data-act="submit">Submit to wrapper…</button>
        <button data-act="export">Export .hellproof</button>
        <button data-act="import">Import…</button>
        <button data-act="reset" class="danger">Reset run</button>
        <label><input type="checkbox" data-act="offline" /> Keep offline</label>
        <input type="file" accept=".hellproof" hidden />
      </div>
      <pre class="proof-queue-log" aria-live="polite"></pre>
    `;
    this.element = root;
    this.tableBody = root.querySelector("tbody") as HTMLElement;
    this.summary = root.querySelector(".proof-queue-summary") as HTMLElement;
    this.logEl = root.querySelector(".proof-queue-log") as HTMLElement;
    this.keepOffline = root.querySelector('input[data-act="offline"]') as HTMLInputElement;
    const fileInput = root.querySelector('input[type="file"]') as HTMLInputElement;

    root.querySelector('[data-act="prove"]')?.addEventListener("click", () => this.actions.onProve?.());
    root.querySelector('[data-act="verify"]')?.addEventListener("click", () => this.actions.onVerify?.());
    root.querySelector('[data-act="submit"]')?.addEventListener("click", () => this.actions.onSubmit?.());
    root.querySelector('[data-act="export"]')?.addEventListener("click", () => this.actions.onExport?.());
    root.querySelector('[data-act="import"]')?.addEventListener("click", () => fileInput.click());
    root.querySelector('[data-act="reset"]')?.addEventListener("click", () => this.actions.onReset?.());
    this.keepOffline.addEventListener("change", () =>
      this.actions.onKeepOffline?.(this.keepOffline.checked),
    );
    fileInput.addEventListener("change", () => {
      const file = fileInput.files?.[0];
      if (file) this.actions.onImport?.(file);
      fileInput.value = "";
    });
    if (options.title) (root.querySelector("h2") as HTMLElement).textContent = options.title;
  }

  /** Feed every {@link PipelineEvent}; the panel decides what redraws. */
  handleEvent(event: PipelineEvent): void {
    switch (event.type) {
      case "progress":
        this.liveStage.set(event.index, {
          stage: event.stage,
          elapsedMs: event.elapsedMs,
          ...(event.detail ? { detail: event.detail } : {}),
        });
        this.renderRows();
        break;
      case "segment":
        this.liveStage.delete(event.segment.index);
        this.renderRows();
        break;
      case "run":
        this.keepOffline.checked = event.run.keepOffline;
        break;
      case "chain":
        this.log(
          event.ok
            ? `chain: ${event.segments} segment(s) link up`
            : `chain BROKEN after ${event.segments} segment(s): ${event.reason ?? "?"}`,
        );
        break;
      case "quota": {
        const line = `storage ${fmtBytes(event.usageBytes)} / ${fmtBytes(event.quotaBytes)}${event.persisted ? " (persisted)" : ""}${event.warning ? " — running out, export the run" : ""}`;
        if (line !== this.lastQuota) {
          this.lastQuota = line;
          this.log(line);
        }
        break;
      }
      case "prover":
        this.log(
          `prover: ${event.threads} thread(s)${event.threaded ? "" : " (single-threaded artifact)"}, instantiated in ${fmtMs(event.instantiateMs)}`,
        );
        break;
      case "log":
        if (event.level !== "debug") this.log(`${event.level}: ${event.message}`);
        break;
    }
  }

  /** Called after every event batch with the pipeline's own view of the world. */
  update(state: PipelineState, segments: readonly SegmentRecord[]): void {
    this.state = state;
    this.segments = segments;
    this.renderRows();
    this.renderSummary();
  }

  private renderSummary(): void {
    const state = this.state;
    if (!state) return;
    const parts = [
      `${state.proved}/${state.total} proved`,
      `${state.ticsPlanned}/${state.ticsRecorded} tics`,
      `${state.threads} thread(s)`,
      `peak ${fmtBytes(state.peakMemoryBytes)}`,
    ];
    if (state.chain) {
      parts.push(
        state.chain.ok
          ? `chain ok${state.chain.finalStatus === undefined ? "" : ` (${statusName(state.chain.finalStatus)})`}`
          : `chain broken: ${state.chain.reason ?? "?"}`,
      );
    }
    if (state.error) parts.push(`error: ${state.error}`);
    this.summary.textContent = parts.join(" · ");
  }

  private renderRows(): void {
    const rows: string[] = [];
    for (const segment of this.segments) {
      const live = this.liveStage.get(segment.index);
      const stage = live && segment.stage !== "proved" ? live.stage : segment.stage;
      const detail = live?.detail ? ` (${live.detail})` : "";
      const elapsed =
        segment.stage === "proved" ? fmtMs(segment.timings.proveMs) : live ? fmtMs(live.elapsedMs) : "—";
      const rowsPct = segment.resources
        ? `${Math.round(segment.resources.utilisation * 100)} %`
        : "—";
      rows.push(
        `<tr class="stage-${segment.stage}">` +
          `<td>${segment.index}</td>` +
          `<td>${segment.ticEnd - segment.ticStart}</td>` +
          `<td>${segment.resources ? segment.resources.nSteps.toLocaleString("en") : "—"}</td>` +
          `<td title="${segment.resources?.maxComponent ?? ""}">${rowsPct}</td>` +
          `<td>${STAGE_LABEL[stage as SegmentRecord["stage"]] ?? stage}${detail}${segment.retriedSingleThread ? " ↻1t" : ""}${segment.attempts > 1 ? ` ×${segment.attempts}` : ""}</td>` +
          `<td>${elapsed}</td>` +
          `<td>${fmtMs(segment.timings.verifyMs)}${segment.verified ? " ✓" : ""}</td>` +
          `<td>${fmtBytes(segment.memoryBytes)}</td>` +
          `<td>${segment.threads}</td>` +
          `<td>${fmtBytes(segment.proofBytes)}${segment.submission === "submitted" ? " ↑" : ""}</td>` +
          `</tr>` +
          (segment.error ? `<tr class="stage-failed"><td colspan="10">${escapeHtml(segment.error)}</td></tr>` : ""),
      );
    }
    this.tableBody.innerHTML = rows.join("");
  }

  /** Appends one line to the panel's log; the last 200 are kept. */
  log(message: string): void {
    const stamp = new Date().toLocaleTimeString("en-GB", { hour12: false });
    const lines = `${this.logEl.textContent ?? ""}${stamp} ${message}\n`.split("\n");
    this.logEl.textContent = lines.slice(Math.max(0, lines.length - 200)).join("\n");
    this.logEl.scrollTop = this.logEl.scrollHeight;
  }

  setKeepOffline(value: boolean): void {
    this.keepOffline.checked = value;
  }
}

function escapeHtml(text: string): string {
  return text.replace(/[&<>"]/g, (c) => `&#${c.charCodeAt(0)};`);
}

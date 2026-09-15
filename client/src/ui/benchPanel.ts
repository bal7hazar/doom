// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

import { describeResult, type BenchResult, type CadenceBench } from "../bench/cadence.js";

/**
 * The cadence bench's panel: a progress line while the run lasts, then the
 * summary table, the JSON to paste back and a Copy button. Plain DOM, readable
 * on a phone (it is what the sponsor reads on the device).
 */
export interface BenchPanel {
  readonly element: HTMLElement;
  /** Refresh the progress line from the bench's counters. */
  progress(bench: CadenceBench): void;
  /** Show the final result; returns the JSON text that was rendered. */
  show(result: BenchResult): string;
  fail(message: string): void;
}

export function mountBenchPanel(host: HTMLElement, label: string): BenchPanel {
  const element = document.createElement("section");
  element.className = "panel bench-panel";
  element.setAttribute("aria-label", "Cadence bench");
  const title = document.createElement("h1");
  title.textContent = "Cadence bench";
  const subtitle = document.createElement("p");
  subtitle.className = "bench-label";
  subtitle.textContent = label;
  const status = document.createElement("p");
  status.setAttribute("role", "status");
  status.textContent = "starting…";
  const table = document.createElement("table");
  table.hidden = true;
  const json = document.createElement("textarea");
  json.readOnly = true;
  json.hidden = true;
  json.setAttribute("aria-label", "Bench result JSON");
  json.rows = 6;
  const actions = document.createElement("div");
  actions.className = "bench-actions";
  actions.hidden = true;
  const copy = document.createElement("button");
  copy.type = "button";
  copy.textContent = "Copy JSON";
  copy.addEventListener("click", () => {
    const done = (): void => { copy.textContent = "Copied"; setTimeout(() => { copy.textContent = "Copy JSON"; }, 1500); };
    const fallback = (): void => { json.focus(); json.select(); try { document.execCommand("copy"); done(); } catch { copy.textContent = "Select the text above and copy it"; } };
    if (navigator.clipboard?.writeText) navigator.clipboard.writeText(json.value).then(done, fallback);
    else fallback();
  });
  const again = document.createElement("a");
  again.href = location.href;
  again.textContent = "Run again";
  const play = document.createElement("a");
  play.href = location.pathname;
  play.textContent = "Back to the game";
  actions.append(copy, again, play);
  element.append(title, subtitle, status, table, json, actions);
  host.append(element);

  return {
    element,
    progress(bench: CadenceBench): void {
      const p = bench.progress;
      status.textContent = `${p.phase}: tic ${p.tics}/${p.planned} · ${p.ticsPerSecond.toFixed(1)} tics/s`;
    },
    show(result: BenchResult): string {
      status.textContent = result.verdict.sustained35 ? "Done: 35 tics/s sustained." : result.terminal ? "Done: the game ended before the planned tics (terminal state)." : "Done: below 35 tics/s.";
      status.classList.toggle("ok", result.verdict.sustained35);
      status.classList.toggle("bad", !result.verdict.sustained35);
      table.replaceChildren(...describeResult(result).map(([k, v]) => {
        const row = document.createElement("tr");
        const key = document.createElement("td");
        key.textContent = k;
        const value = document.createElement("td");
        value.textContent = v;
        row.append(key, value);
        return row;
      }));
      table.hidden = false;
      json.value = JSON.stringify(result, null, 2);
      json.hidden = false;
      actions.hidden = false;
      return json.value;
    },
    fail(message: string): void {
      status.textContent = message;
      status.classList.add("bad");
      actions.hidden = false;
      copy.hidden = true;
    },
  };
}

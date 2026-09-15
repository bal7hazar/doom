// SPDX-License-Identifier: Apache-2.0
/**
 * Plain-DOM rendering — no framework, matching `client/`'s existing style (`src/ui/*.ts`). Every
 * function here is pure with respect to the page: given data and a mount point, it replaces the
 * mount's children. `test/leaderboard.test.ts` renders these straight from fixtures with jsdom.
 */
import { formatTokenAmount } from "../chain/commit.js";
import { contractLink, txLink } from "./links.js";
import type { BoardKind, BoardPage, ChainStats, NetworkKind, PlayerCommitment, PlayerStats, RunDetail } from "./types.js";

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: Partial<HTMLElementTagNameMap[K]> & { className?: string; text?: string } = {},
  children: (Node | string)[] = [],
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  const { text, ...rest } = props;
  Object.assign(node, rest);
  if (text !== undefined) node.textContent = text;
  for (const c of children) node.append(c);
  return node;
}

const short = (hex: string, n = 6): string => (hex.length > n * 2 + 2 ? `${hex.slice(0, n + 2)}…${hex.slice(-n)}` : hex);

/** An in-page hash route (`#/run/…`, `#/player/…`): a plain same-tab anchor, so a click updates
 * `location.hash` and the SPA router picks it up (`app.ts`'s `hashchange` listener). */
function routeLink(href: string, text: string): HTMLAnchorElement {
  return el("a", { href, text });
}

/** A genuinely external link (Voyager): opens in a new tab, never navigates the board away. */
function externalLink(href: string, text: string): HTMLAnchorElement {
  return el("a", { href, text, target: "_blank", rel: "noopener noreferrer" });
}

// --- leaderboard board -------------------------------------------------------

export interface BoardLinks {
  runHref: (runId: string) => string;
  playerHref: (address: string) => string;
}

export function renderBoard(mount: HTMLElement, page: BoardPage, links: BoardLinks): void {
  mount.replaceChildren();
  const valueLabel = page.kind === 0 ? "score" : "tics";
  const table = el("table", { className: "board" });
  table.append(
    el("thead", {}, [
      el("tr", {}, [
        el("th", { text: "#" }),
        el("th", { text: "player" }),
        el("th", { text: valueLabel }),
        el("th", { text: "run" }),
      ]),
    ]),
  );
  const tbody = el("tbody");
  if (page.rows.length === 0) {
    tbody.append(el("tr", {}, [el("td", { text: "no runs yet", colSpan: 4, className: "empty" })]));
  }
  for (const row of page.rows) {
    tbody.append(
      el("tr", {}, [
        el("td", { text: String(row.rank), className: "rank" }),
        el("td", {}, [routeLink(links.playerHref(row.player), short(row.player))]),
        el("td", { text: row.value.toLocaleString("en-US"), className: "value" }),
        el("td", {}, [routeLink(links.runHref(row.runId), short(row.runId))]),
      ]),
    );
  }
  table.append(tbody);
  mount.append(table);
}

export function renderPager(
  mount: HTMLElement,
  page: { offset: number; limit: number; total: number },
  onPage: (offset: number) => void,
): void {
  mount.replaceChildren();
  const atStart = page.offset === 0;
  const atEnd = page.offset + page.limit >= page.total;
  const prev = el("button", { text: "< prev", disabled: atStart });
  prev.addEventListener("click", () => onPage(Math.max(0, page.offset - page.limit)));
  const next = el("button", { text: "next >", disabled: atEnd });
  next.addEventListener("click", () => onPage(page.offset + page.limit));
  const from = page.total === 0 ? 0 : page.offset + 1;
  const to = Math.min(page.offset + page.limit, page.total);
  mount.append(prev, el("span", { text: ` ${from}-${to} of ${page.total} `, className: "pager-count" }), next);
}

export function boardKindTabs(mount: HTMLElement, active: BoardKind, onSelect: (kind: BoardKind) => void): void {
  mount.replaceChildren();
  const tab = (kind: BoardKind, label: string): HTMLButtonElement => {
    const b = el("button", { text: label, className: kind === active ? "tab active" : "tab" });
    b.addEventListener("click", () => onSelect(kind));
    return b;
  };
  mount.append(tab(0, "best score"), tab(1, "best time"));
}

// --- player page -------------------------------------------------------------

export function renderPlayer(mount: HTMLElement, stats: PlayerStats, links: BoardLinks): void {
  mount.replaceChildren();
  const header = el("div", { className: "player-header" }, [
    el("h2", { text: short(stats.player, 8) }),
    el("p", {
      text:
        `${stats.runCount} finished run(s)` +
        (stats.attemptCount !== undefined ? `, ${stats.attemptCount} attempt(s)` : "") +
        (stats.bestScore !== null ? ` · best score ${stats.bestScore.toLocaleString("en-US")}` : "") +
        (stats.bestTics !== null ? ` · best time ${stats.bestTics.toLocaleString("en-US")} tics` : ""),
    }),
  ]);
  const table = el("table", { className: "board" });
  table.append(
    el("thead", {}, [
      el("tr", {}, [
        el("th", { text: "run" }),
        el("th", { text: "version" }),
        el("th", { text: "level" }),
        el("th", { text: "status" }),
        el("th", { text: "score" }),
        el("th", { text: "tics" }),
      ]),
    ]),
  );
  const tbody = el("tbody");
  for (const r of stats.runs) {
    tbody.append(
      el("tr", {}, [
        el("td", {}, [routeLink(links.runHref(r.runId), short(r.runId))]),
        el("td", { text: String(r.versionId) }),
        el("td", { text: String(r.levelId) }),
        el("td", { text: r.status, className: r.status === "EXIT" ? "ok" : "dead" }),
        el("td", { text: r.score.toLocaleString("en-US") }),
        el("td", { text: r.tics.toLocaleString("en-US") }),
      ]),
    );
  }
  table.append(tbody);
  mount.append(header, table);
  if (stats.pendingCommitments?.length) mount.append(renderPendingCommitments(stats.pendingCommitments));
}

/**
 * The player's games committed to the open prover and not proved yet (D35, P4.7): listed under
 * the recorded runs, because they are not results — anyone may still prove them, and after the
 * expiry block the player may take the bounty back instead.
 */
export function renderPendingCommitments(commitments: PlayerCommitment[]): HTMLElement {
  const section = el("div", { className: "pending-commitments" });
  section.append(
    el("h3", { text: `waiting for a prover (${commitments.length})` }),
    el("p", {
      className: "hint",
      text: "Committed on chain with the whole input log; any prover may prove and record them and collect the bounty. Not ranked until then.",
    }),
  );
  const table = el("table", { className: "board" });
  table.append(
    el("thead", {}, [
      el("tr", {}, [
        el("th", { text: "commitment" }),
        el("th", { text: "version" }),
        el("th", { text: "level" }),
        el("th", { text: "tics" }),
        el("th", { text: "bounty (STRK)" }),
        el("th", { text: "status" }),
        el("th", { text: "log" }),
      ]),
    ]),
  );
  const tbody = el("tbody");
  for (const c of commitments) {
    const expired = c.status === "EXPIRED";
    tbody.append(
      el("tr", {}, [
        el("td", {}, [el("code", { text: short(c.commitmentId) })]),
        el("td", { text: String(c.versionId) }),
        el("td", { text: String(c.levelId) }),
        el("td", { text: c.tics.toLocaleString("en-US") }),
        el("td", { text: formatTokenAmount(BigInt(c.bounty)) }),
        el("td", {
          text: expired ? `expired at block ${c.expiresAt} — reclaimable` : `pending until block ${c.expiresAt}`,
          className: expired ? "dead" : "pending",
        }),
        el("td", {
          text: c.nChunks === undefined ? "—" : `${c.logChunks ?? "?"} / ${c.nChunks} chunk(s)`,
          className: "hint",
        }),
      ]),
    );
  }
  table.append(tbody);
  section.append(table);
  return section;
}

// --- run detail ----------------------------------------------------------------

export interface RunDetailOptions {
  network: NetworkKind;
  doomRunsAddress?: string;
  playerHref: (address: string) => string;
  onDownloadReplay?: () => void;
}

function factRow(label: string, value: string, network: NetworkKind, isContract: boolean): HTMLElement {
  const href = isContract ? contractLink(network, value) : undefined;
  return el("tr", {}, [
    el("th", { text: label }),
    el("td", {}, [href ? externalLink(href, value) : el("code", { text: value })]),
  ]);
}

export function renderRunDetail(mount: HTMLElement, run: RunDetail, options: RunDetailOptions): void {
  mount.replaceChildren();

  const summary = el("table", { className: "run-summary" });
  summary.append(
    el("tr", {}, [el("th", { text: "run id" }), el("td", {}, [el("code", { text: run.runId })])]),
    el("tr", {}, [el("th", { text: "player" }), el("td", {}, [routeLink(options.playerHref(run.player), run.player)])]),
    el("tr", {}, [el("th", { text: "status" }), el("td", { text: run.status, className: run.status === "EXIT" ? "ok" : "dead" })]),
    el("tr", {}, [el("th", { text: "version / level" }), el("td", { text: `${run.versionId} / ${run.levelId}` })]),
    el("tr", {}, [el("th", { text: "score" }), el("td", { text: run.score.toLocaleString("en-US") })]),
    el("tr", {}, [el("th", { text: "tics" }), el("td", { text: run.tics.toLocaleString("en-US") })]),
  );
  if (run.kills !== null) {
    summary.append(
      el("tr", {}, [
        el("th", { text: "kills / items / secrets" }),
        el("td", { text: `${run.kills} / ${run.items} / ${run.secrets}` }),
      ]),
    );
  }
  if (run.nSegments !== null) {
    summary.append(el("tr", {}, [el("th", { text: "segments" }), el("td", { text: String(run.nSegments) })]));
  }

  const proof = el("table", { className: "run-proof" }, [
    el("caption", { text: "on-chain proof of validity" }),
    factRow("fact (batch verification)", run.fact, options.network, false),
  ]);
  if (options.doomRunsAddress) {
    proof.append(factRow("DoomRuns contract", options.doomRunsAddress, options.network, true));
  }
  if (run.txHash) {
    const href = txLink(options.network, run.txHash);
    proof.append(
      el("tr", {}, [
        el("th", { text: "submit_batch transaction" }),
        el("td", {}, [href ? externalLink(href, run.txHash) : el("code", { text: run.txHash })]),
      ]),
    );
  }
  if (run.blockNumber !== undefined) {
    proof.append(el("tr", {}, [el("th", { text: "block" }), el("td", { text: String(run.blockNumber) })]));
  }
  if (options.network === "devnet") {
    proof.append(
      el("tr", {}, [
        el("th", { text: "explorer" }),
        el("td", { text: "devnet-local: no public explorer for this network", className: "hint" }),
      ]),
    );
  }

  const replay = el("div", { className: "replay" });
  if (run.replay.length > 0) {
    const btn = el("button", { text: `download replay (${run.replay.length} segment(s) of inputs)` });
    if (options.onDownloadReplay) btn.addEventListener("click", options.onDownloadReplay);
    replay.append(btn);
  } else {
    replay.append(el("p", { text: "no replay log was published for this run.", className: "hint" }));
  }

  mount.append(
    el("h2", { text: `run ${short(run.runId)}` }),
    summary,
    proof,
    el("h3", { text: "replay" }),
    replay,
  );
}

// --- stats ---------------------------------------------------------------------

export function renderStats(mount: HTMLElement, stats: ChainStats | undefined): void {
  mount.replaceChildren();
  if (!stats) {
    mount.append(el("p", { text: "stats require the indexer (not available over the RPC fallback).", className: "hint" }));
    return;
  }
  mount.append(
    el("p", {
      text:
        `${stats.totalRuns} finished run(s), ${stats.totalAttempts} attempt(s), ` +
        `${stats.totalPlayers} player(s) — indexed up to block ${stats.indexedBlock ?? "?"}`,
    }),
  );
}

export function renderError(mount: HTMLElement, message: string): void {
  mount.replaceChildren(el("p", { text: message, className: "error" }));
}

export function renderLoading(mount: HTMLElement): void {
  mount.replaceChildren(el("p", { text: "loading…", className: "hint" }));
}

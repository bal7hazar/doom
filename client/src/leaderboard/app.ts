// SPDX-License-Identifier: Apache-2.0
/**
 * Wires the leaderboard page together: picks a {@link LeaderboardSource} from the page's query
 * string, and routes `location.hash` between the board, a player page and a run detail view.
 *
 * Query parameters (all optional):
 *
 * | param | default | what |
 * |---|---|---|
 * | `indexer` | — | base URL of `infra/indexer`'s read API; when present, it is used |
 * | `rpc` | `http://127.0.0.1:5081/rpc` | Starknet RPC, used when `indexer` is absent |
 * | `runs` | — | `DoomRuns` contract address — required for the RPC fallback |
 * | `network` | `devnet` | `mainnet` \| `sepolia` \| anything else means devnet-local (`links.ts`) |
 * | `version` | `1` | default `version_id` the board opens on |
 *
 * Hash routes: `#/board`, `#/player/<address>`, `#/run/<run_id>`.
 */
import {
  boardKindTabs,
  renderBoard,
  renderError,
  renderLoading,
  renderPager,
  renderPlayer,
  renderRunDetail,
  renderStats,
  type BoardLinks,
} from "./render.js";
import { buildReplayFile, replayFileName } from "./replay.js";
import { IndexerSource, RpcSource } from "./source.js";
import { parseNetwork } from "./links.js";
import type { BoardKind, LeaderboardSource, NetworkKind } from "./types.js";

export interface AppConfig {
  source: LeaderboardSource;
  network: NetworkKind;
  doomRunsAddress?: string;
  defaultVersionId: number;
}

export function configFromLocation(location: { search: string }): AppConfig {
  const params = new URLSearchParams(location.search);
  const indexer = params.get("indexer");
  const rpc = params.get("rpc") ?? "http://127.0.0.1:5081/rpc";
  const doomRuns = params.get("runs") ?? undefined;
  const source: LeaderboardSource = indexer
    ? new IndexerSource(indexer)
    : new RpcSource(rpc, doomRuns ?? "0x0");
  return {
    source,
    network: parseNetwork(params.get("network")),
    ...(doomRuns ? { doomRunsAddress: doomRuns } : {}),
    defaultVersionId: Number(params.get("version") ?? "1") || 1,
  };
}

type Route =
  | { name: "board"; versionId: number; kind: BoardKind; offset: number }
  | { name: "player"; address: string }
  | { name: "run"; runId: string };

const BOARD_LIMIT = 20;
const PLAYER_LIMIT = 20;

export function parseRoute(hash: string, defaultVersionId: number): Route {
  const parts = hash.replace(/^#\/?/, "").split("/").filter(Boolean);
  if (parts[0] === "player" && parts[1]) return { name: "player", address: parts[1] };
  if (parts[0] === "run" && parts[1]) return { name: "run", runId: parts[1] };
  const params = new URLSearchParams(hash.split("?")[1] ?? "");
  return {
    name: "board",
    versionId: Number(params.get("version") ?? defaultVersionId) || defaultVersionId,
    kind: (params.get("kind") === "1" ? 1 : 0) as BoardKind,
    offset: Number(params.get("offset") ?? "0") || 0,
  };
}

function routeHash(route: Route): string {
  if (route.name === "player") return `#/player/${route.address}`;
  if (route.name === "run") return `#/run/${route.runId}`;
  return `#/board?version=${route.versionId}&kind=${route.kind}&offset=${route.offset}`;
}

export interface AppElements {
  tabs: HTMLElement;
  pager: HTMLElement;
  body: HTMLElement;
  stats: HTMLElement;
  title: HTMLElement;
}

export function mount(elements: AppElements, config: AppConfig, win: Window = window): { render: () => void } {
  const links: BoardLinks = {
    runHref: (runId) => `#/run/${runId}`,
    playerHref: (address) => `#/player/${address}`,
  };

  const goto = (route: Route): void => {
    win.location.hash = routeHash(route);
  };

  const render = async (): Promise<void> => {
    const route = parseRoute(win.location.hash, config.defaultVersionId);
    renderLoading(elements.body);
    elements.pager.replaceChildren();

    try {
      if (route.name === "board") {
        elements.title.textContent = `leaderboard — version ${route.versionId}`;
        boardKindTabs(elements.tabs, route.kind, (kind) => goto({ ...route, kind, offset: 0 }));
        const page = await config.source.leaderboard(route.versionId, route.kind, route.offset, BOARD_LIMIT);
        renderBoard(elements.body, page, links);
        renderPager(elements.pager, page, (offset) => goto({ ...route, offset }));
        const stats = await config.source.stats();
        renderStats(elements.stats, stats);
        return;
      }

      elements.tabs.replaceChildren();
      elements.stats.replaceChildren();

      if (route.name === "player") {
        elements.title.textContent = `player ${route.address}`;
        const stats = await config.source.player(route.address, 0, PLAYER_LIMIT);
        renderPlayer(elements.body, stats, links);
        return;
      }

      // route.name === "run"
      elements.title.textContent = `run ${route.runId}`;
      const run = await config.source.run(route.runId);
      if (!run) {
        renderError(elements.body, `no such run: ${route.runId}`);
        return;
      }
      renderRunDetail(elements.body, run, {
        network: config.network,
        ...(config.doomRunsAddress ? { doomRunsAddress: config.doomRunsAddress } : {}),
        playerHref: links.playerHref,
        onDownloadReplay: () => {
          const bytes = buildReplayFile(run);
          const blob = new Blob([bytes as BlobPart], { type: "application/octet-stream" });
          const url = URL.createObjectURL(blob);
          const a = document.createElement("a");
          a.href = url;
          a.download = replayFileName(run);
          a.click();
          URL.revokeObjectURL(url);
        },
      });
    } catch (e) {
      renderError(elements.body, `failed to load: ${e instanceof Error ? e.message : String(e)}`);
    }
  };

  win.addEventListener("hashchange", () => void render());
  return { render: () => void render() };
}

/**
 * `leaderboard.html` — best score / best time boards, player pages, run detail with the on-chain
 * proof of validity and a replay download (P4.4). Reads `infra/indexer`'s API when `?indexer=` is
 * given, otherwise falls back to `DoomRuns`'s own views over `?rpc=`/`?runs=` so the page works
 * with nothing but an RPC URL. See `src/leaderboard/app.ts` for the full query string reference.
 */
import { configFromLocation, mount } from "./leaderboard/app.js";

const config = configFromLocation(location);

const sourceEl = document.getElementById("lb-source") as HTMLElement;
sourceEl.textContent =
  config.source.kind === "indexer" ? "reading the indexer" : "reading DoomRuns directly over RPC";

const app = mount(
  {
    tabs: document.getElementById("lb-tabs") as HTMLElement,
    pager: document.getElementById("lb-pager") as HTMLElement,
    body: document.getElementById("lb-body") as HTMLElement,
    stats: document.getElementById("lb-stats") as HTMLElement,
    title: document.getElementById("lb-title") as HTMLElement,
  },
  config,
);

app.render();

(globalThis as unknown as { hellproofLeaderboard: unknown }).hellproofLeaderboard = { config, app };

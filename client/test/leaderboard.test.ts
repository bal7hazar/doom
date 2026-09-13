// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";

import { configFromLocation, parseRoute } from "../src/leaderboard/app.js";
import { contractLink, parseNetwork, txLink } from "../src/leaderboard/links.js";
import {
  boardKindTabs,
  renderBoard,
  renderError,
  renderPager,
  renderPlayer,
  renderRunDetail,
  renderStats,
} from "../src/leaderboard/render.js";
import { buildReplayFile, reconstructJournal, replayFileName } from "../src/leaderboard/replay.js";
import { pack7 } from "../src/prove/ticcmd.js";
import type { BoardPage, ChainStats, PlayerStats, RunDetail } from "../src/leaderboard/types.js";

const links = { runHref: (id: string) => `#/run/${id}`, playerHref: (a: string) => `#/player/${a}` };

const board: BoardPage = {
  versionId: 1,
  kind: 0,
  offset: 0,
  limit: 20,
  total: 2,
  rows: [
    { rank: 1, runId: "0xaaa", player: "0xa11ce", value: 900 },
    { rank: 2, runId: "0xbbb", player: "0xb0b", value: 600 },
  ],
};

const finishedRun: RunDetail = {
  runId: "0xaaa",
  player: "0xa11ce",
  versionId: 1,
  levelId: 1,
  tics: 320,
  kills: 6,
  items: 2,
  secrets: 1,
  score: 1150,
  status: "EXIT",
  nSegments: 2,
  fact: "0xfac7",
  blockNumber: 42,
  txHash: "0xtx1",
  replay: [
    { leafIndex: 0, ticStart: 0, ticEnd: 160, packed: [] },
    { leafIndex: 1, ticStart: 160, ticEnd: 320, packed: [] },
  ],
};

describe("render: board", () => {
  it("renders rows ranked, linked, and orders score descending semantics from the source", () => {
    const mount = document.createElement("div");
    renderBoard(mount, board, links);
    const rows = mount.querySelectorAll("tbody tr");
    expect(rows).toHaveLength(2);
    expect(rows[0]?.querySelector("td.rank")?.textContent).toBe("1");
    expect(rows[0]?.querySelector("a[href='#/player/0xa11ce']")).toBeTruthy();
    expect(rows[0]?.querySelector("a[href='#/run/0xaaa']")).toBeTruthy();
  });

  it("renders an empty state with no rows", () => {
    const mount = document.createElement("div");
    renderBoard(mount, { ...board, rows: [], total: 0 }, links);
    expect(mount.querySelector("td.empty")?.textContent).toBe("no runs yet");
  });

  it("pager disables prev at offset 0 and next at the last page", () => {
    const mount = document.createElement("div");
    const onPage = vi.fn();
    renderPager(mount, { offset: 0, limit: 20, total: 2 }, onPage);
    const [prev, next] = mount.querySelectorAll("button");
    expect(prev?.disabled).toBe(true);
    expect(next?.disabled).toBe(true); // total(2) <= limit(20): both ends
  });

  it("pager wires the click handlers to the given offsets", () => {
    const mount = document.createElement("div");
    const onPage = vi.fn();
    renderPager(mount, { offset: 20, limit: 20, total: 60 }, onPage);
    const [prev, next] = mount.querySelectorAll("button");
    prev!.dispatchEvent(new Event("click"));
    next!.dispatchEvent(new Event("click"));
    expect(onPage).toHaveBeenNthCalledWith(1, 0);
    expect(onPage).toHaveBeenNthCalledWith(2, 40);
  });

  it("board kind tabs mark the active one and call back on selection", () => {
    const mount = document.createElement("div");
    const onSelect = vi.fn();
    boardKindTabs(mount, 0, onSelect);
    const [scoreTab, timeTab] = mount.querySelectorAll("button");
    expect(scoreTab?.className).toContain("active");
    expect(timeTab?.className).not.toContain("active");
    timeTab!.dispatchEvent(new Event("click"));
    expect(onSelect).toHaveBeenCalledWith(1);
  });
});

describe("render: player", () => {
  const stats: PlayerStats = {
    player: "0xa11ce",
    runCount: 2,
    attemptCount: 1,
    bestScore: 900,
    bestTics: 200,
    runs: [
      { runId: "0xaaa", versionId: 1, levelId: 1, tics: 320, score: 1150, status: "EXIT" },
      { runId: "0xbbb", versionId: 1, levelId: 2, tics: 90, score: 0, status: "DEAD" },
    ],
  };

  it("shows the summary line and a row per run, dead runs flagged", () => {
    const mount = document.createElement("div");
    renderPlayer(mount, stats, links);
    expect(mount.querySelector("h2")?.textContent).toContain("0xa11ce".slice(0, 8));
    expect(mount.textContent).toContain("2 finished run(s)");
    expect(mount.textContent).toContain("1 attempt(s)");
    const statuses = [...mount.querySelectorAll("td.ok, td.dead")].map((td) => td.textContent);
    expect(statuses).toEqual(["EXIT", "DEAD"]);
  });
});

describe("render: run detail", () => {
  it("links the fact/tx through Voyager on sepolia", () => {
    const mount = document.createElement("div");
    renderRunDetail(mount, finishedRun, {
      network: "sepolia",
      doomRunsAddress: "0xruns",
      playerHref: links.playerHref,
    });
    const txAnchor = mount.querySelector("a[href*='sepolia.voyager.online/tx/0xtx1']");
    expect(txAnchor).toBeTruthy();
    expect(mount.querySelector("button")?.textContent).toContain("2 segment(s)");
  });

  it("shows no explorer link on devnet, and a hint instead", () => {
    const mount = document.createElement("div");
    renderRunDetail(mount, finishedRun, { network: "devnet", playerHref: links.playerHref });
    expect(mount.querySelector("a[href*='voyager']")).toBeNull();
    expect(mount.textContent).toContain("devnet-local");
  });

  it("shows an attempt (DEAD) without kills/items/secrets and with no replay", () => {
    const attempt: RunDetail = { ...finishedRun, status: "DEAD", kills: null, items: null, secrets: null, nSegments: null, replay: [] };
    const mount = document.createElement("div");
    renderRunDetail(mount, attempt, { network: "devnet", playerHref: links.playerHref });
    expect(mount.querySelector("td.dead")?.textContent).toBe("DEAD");
    expect(mount.querySelector("button")).toBeNull();
    expect(mount.textContent).toContain("no replay log was published");
  });

  it("wires the download button when a handler is given", () => {
    const mount = document.createElement("div");
    const onDownloadReplay = vi.fn();
    renderRunDetail(mount, finishedRun, { network: "devnet", playerHref: links.playerHref, onDownloadReplay });
    mount.querySelector("button")!.dispatchEvent(new Event("click"));
    expect(onDownloadReplay).toHaveBeenCalledOnce();
  });
});

describe("render: stats and errors", () => {
  it("renders totals when stats are available", () => {
    const stats: ChainStats = {
      indexedBlock: 100,
      totalRuns: 5,
      totalAttempts: 1,
      totalPlayers: 3,
      versions: [{ versionId: 1, runCount: 5, attemptCount: 1 }],
    };
    const mount = document.createElement("div");
    renderStats(mount, stats);
    expect(mount.textContent).toContain("5 finished run(s)");
    expect(mount.textContent).toContain("block 100");
  });

  it("explains that stats need the indexer when undefined (RPC fallback)", () => {
    const mount = document.createElement("div");
    renderStats(mount, undefined);
    expect(mount.textContent).toContain("require the indexer");
  });

  it("renders an error message", () => {
    const mount = document.createElement("div");
    renderError(mount, "boom");
    expect(mount.querySelector(".error")?.textContent).toBe("boom");
  });
});

describe("links", () => {
  it("parseNetwork treats anything but mainnet/sepolia as devnet", () => {
    expect(parseNetwork("mainnet")).toBe("mainnet");
    expect(parseNetwork("sepolia")).toBe("sepolia");
    expect(parseNetwork(null)).toBe("devnet");
    expect(parseNetwork("localhost")).toBe("devnet");
  });

  it("txLink/contractLink are undefined on devnet", () => {
    expect(txLink("devnet", "0x1")).toBeUndefined();
    expect(contractLink("devnet", "0x1")).toBeUndefined();
    expect(txLink("mainnet", "0x1")).toBe("https://voyager.online/tx/0x1");
    expect(contractLink("sepolia", "0x1")).toBe("https://sepolia.voyager.online/contract/0x1");
  });
});

describe("app: routing", () => {
  it("parses the board route with query params, falling back to the default version", () => {
    expect(parseRoute("#/board?version=2&kind=1&offset=20", 1)).toEqual({
      name: "board",
      versionId: 2,
      kind: 1,
      offset: 20,
    });
    expect(parseRoute("", 7)).toEqual({ name: "board", versionId: 7, kind: 0, offset: 0 });
  });

  it("parses player and run routes", () => {
    expect(parseRoute("#/player/0xa11ce", 1)).toEqual({ name: "player", address: "0xa11ce" });
    expect(parseRoute("#/run/0xaaa", 1)).toEqual({ name: "run", runId: "0xaaa" });
  });

  it("configFromLocation picks the RPC fallback with no ?indexer=", () => {
    const cfg = configFromLocation({ search: "?rpc=http://x&runs=0xruns&network=sepolia&version=3" });
    expect(cfg.source.kind).toBe("rpc");
    expect(cfg.network).toBe("sepolia");
    expect(cfg.doomRunsAddress).toBe("0xruns");
    expect(cfg.defaultVersionId).toBe(3);
  });

  it("configFromLocation picks the indexer when ?indexer= is given", () => {
    const cfg = configFromLocation({ search: "?indexer=http://localhost:8788" });
    expect(cfg.source.kind).toBe("indexer");
    expect(cfg.network).toBe("devnet");
    expect(cfg.defaultVersionId).toBe(1);
  });
});

describe("replay: journal reconstruction", () => {
  it("throws when the run published no replay logs", () => {
    expect(() => buildReplayFile({ ...finishedRun, replay: [] })).toThrow(/no replay logs/);
  });

  it("re-packs per-segment logs into one continuous journal", () => {
    // A 7-tic segment and a 3-tic segment, each restarting its own 7-per-felt grouping (D13).
    // Concatenated raw words: 7 + 3 = 10, which continuously re-packs as one complete felt (the
    // first 7 words) plus a 3-word tail — a different split than either segment's own packing.
    const words1 = [1, 2, 3, 4, 5, 6, 7];
    const words2 = [8, 9, 10];
    const run: RunDetail = {
      ...finishedRun,
      tics: 10,
      replay: [
        { leafIndex: 0, ticStart: 0, ticEnd: 7, packed: [pack7(words1)] },
        { leafIndex: 1, ticStart: 7, ticEnd: 10, packed: [pack7(words2)] },
      ],
    };
    const { words, packed, tail } = reconstructJournal(run);
    expect(words).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    expect(packed).toHaveLength(1);
    expect(tail).toEqual([8, 9, 10]);
  });

  it("builds a valid .hellproof container: magic, manifest, no proof bytes", () => {
    const bytes = buildReplayFile(finishedRun);
    const magic = new TextDecoder().decode(bytes.subarray(0, 9));
    expect(magic).toBe("HELLPROOF");
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const manifestLength = view.getUint32(12, true);
    const manifest = JSON.parse(new TextDecoder().decode(bytes.subarray(16, 16 + manifestLength)));
    expect(manifest.format).toBe("hellproof");
    expect(manifest.run.id).toBe(finishedRun.runId);
    expect(manifest.inputs.runId).toBe(finishedRun.runId);
    expect(manifest.segments).toHaveLength(2);
    expect(manifest.proofs).toEqual([]);
    expect(bytes.byteLength).toBe(16 + manifestLength); // no payload region at all
    expect(replayFileName(finishedRun)).toMatch(/^doomruns-v1-.*\.hellproof$/);
  });
});

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

// -- D35 / P4.7: a player's games waiting for a prover ---------------------------------------

import { RpcClient } from "../src/chain/rpc.js";
import { IndexerSource, RpcSource } from "../src/leaderboard/source.js";
import { renderPendingCommitments } from "../src/leaderboard/render.js";
import type { PlayerCommitment } from "../src/leaderboard/types.js";

const pendingOne: PlayerCommitment = {
  commitmentId: "0x41d40fa574f040b0e2274eabd600adba330a3352c0fa10aee49a2da0c427060",
  versionId: 1,
  levelId: 1,
  tics: 900,
  bounty: "500000000000000000",
  expiresAt: 150,
  status: "PENDING",
  logChunks: 4,
  nChunks: 4,
  blockNumber: 100,
  txHash: "0xc00",
};

describe("render: pending commitments on the player page", () => {
  it("lists them under the runs, with the bounty in STRK and the expiry", () => {
    const mount = document.createElement("div");
    renderPlayer(
      mount,
      {
        player: "0xa11ce",
        runCount: 1,
        bestScore: 900,
        bestTics: 200,
        runs: [{ runId: "0xaaa", versionId: 1, levelId: 1, tics: 320, score: 1150, status: "EXIT" }],
        pendingCommitments: [pendingOne, { ...pendingOne, commitmentId: "0xbeef", status: "EXPIRED", bounty: "0", expiresAt: 90 }],
      },
      links,
    );
    // The runs table first, the commitments after it: not results, not ranked.
    const tables = mount.querySelectorAll("table");
    expect(tables).toHaveLength(2);
    expect(mount.querySelector(".pending-commitments h3")?.textContent).toBe("waiting for a prover (2)");
    const rows = [...tables[1]!.querySelectorAll("tbody tr")].map((tr) => [...tr.querySelectorAll("td")].map((td) => td.textContent));
    expect(rows[0]).toEqual(["0x41d40f…427060", "1", "1", "900", "0.5", "pending until block 150", "4 / 4 chunk(s)"]);
    expect(rows[1]![5]).toBe("expired at block 90 — reclaimable");
    expect(tables[1]!.querySelector("td.dead")?.textContent).toMatch(/reclaimable/);
    expect(tables[1]!.querySelector("td.pending")?.textContent).toMatch(/pending until/);
  });

  it("is absent without commitments, and shows a dash when the RPC fallback knows no chunk count", () => {
    const mount = document.createElement("div");
    renderPlayer(mount, { player: "0xa11ce", runCount: 0, bestScore: null, bestTics: null, runs: [] }, links);
    expect(mount.querySelector(".pending-commitments")).toBeNull();
    const section = renderPendingCommitments([{ ...pendingOne, logChunks: undefined, nChunks: undefined }]);
    expect([...section.querySelectorAll("tbody td")].at(-1)?.textContent).toBe("—");
  });
});

describe("sources: pending commitments", () => {
  it("the indexer source maps pending_commitments and judges expiry against the indexed block", async () => {
    const calls: string[] = [];
    const fetchImpl = (async (input: RequestInfo | URL) => {
      const url = String(input);
      calls.push(url);
      const body = url.endsWith("/stats")
        ? { indexed_block: 120, total_runs: 1, total_attempts: 0, total_players: 1, versions: [] }
        : {
            player: "0xa11ce",
            run_count: 1,
            attempt_count: 0,
            best_score: 900,
            best_tics: 200,
            runs: [{ run_id: "0xaaa", version_id: 1, level_id: 1, tics: 320, score: 1150, status: "EXIT", block_number: 5 }],
            pending_commitments: [
              { commitment_id: "0xc2", version_id: 1, level_id: 2, tics: 400, bounty: "0", expires_at: 160, n_chunks: 2, log_chunks: 2, block_number: 110, tx_hash: "0xc110" },
              { commitment_id: "0xc1", version_id: 1, level_id: 1, tics: 900, bounty: "5", expires_at: 120, n_chunks: 4, log_chunks: 3, block_number: 70, tx_hash: "0xc70" },
            ],
          };
      return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
    }) as typeof fetch;
    const stats = await new IndexerSource("http://indexer.invalid", fetchImpl).player("0xa11ce", 0, 20);
    expect(calls[0]).toBe("http://indexer.invalid/players/0xa11ce?offset=0&limit=20");
    expect(stats.runs).toHaveLength(1);
    expect(stats.pendingCommitments).toEqual([
      { commitmentId: "0xc2", versionId: 1, levelId: 2, tics: 400, bounty: "0", expiresAt: 160, status: "PENDING", logChunks: 2, nChunks: 2, blockNumber: 110, txHash: "0xc110" },
      { commitmentId: "0xc1", versionId: 1, levelId: 1, tics: 900, bounty: "5", expiresAt: 120, status: "EXPIRED", logChunks: 3, nChunks: 4, blockNumber: 70, txHash: "0xc70" },
    ]);
  });

  it("the RPC fallback walks pending_commitments and keeps the player's own, newest first", async () => {
    const u256 = (v: bigint): [string, string] => ["0x" + (v & ((1n << 128n) - 1n)).toString(16), "0x" + (v >> 128n).toString(16)];
    const commitment = (player: string, tics: number, status: number, expiresAt: number) => [
      player, "0x1", "0x1", "0xdead", "0x1c0", "0x" + tics.toString(16), ...u256(5n), "0x64", "0x" + expiresAt.toString(16), "0x" + status.toString(16), "0x0", "0x0",
    ];
    const views: Record<string, string[]> = {
      player_run_count: ["0x0"],
      player_runs: ["0x0"],
      commitment_count: ["0x3"],
      pending_commitments: ["0x2", "0xc1", "0xc3", "0x3"], // (Array<felt252>, next cursor): 0xc2 is settled
      "get_commitment:0xc1": commitment("0xa11ce", 900, 1, 150),
      "get_commitment:0xc3": commitment("0xb0b", 40, 1, 150),
    };
    const rpc = {
      call: vi.fn(async (c: { entrypoint: string; calldata: string[] }) => {
        const out = views[c.entrypoint === "get_commitment" ? `get_commitment:${c.calldata[0]}` : c.entrypoint];
        if (!out) throw new Error(`unexpected view ${c.entrypoint}`);
        return out;
      }),
      request: vi.fn(async (method: string) => {
        expect(method).toBe("starknet_blockNumber");
        return 200;
      }),
    } as unknown as RpcClient;
    const stats = await new RpcSource("http://rpc.invalid", "0x2e10", rpc).player("0xa11ce", 0, 20);
    expect(stats.runCount).toBe(0);
    expect(stats.pendingCommitments).toEqual([
      { commitmentId: "0xc1", versionId: 1, levelId: 1, tics: 900, bounty: "5", expiresAt: 150, status: "EXPIRED" },
    ]);
    expect((rpc.call as ReturnType<typeof vi.fn>).mock.calls.map(([c]) => (c as { entrypoint: string }).entrypoint)).toEqual([
      "player_run_count", "player_runs", "commitment_count", "pending_commitments", "get_commitment", "get_commitment",
    ]);
    expect((rpc.call as ReturnType<typeof vi.fn>).mock.calls[3]![0]).toMatchObject({ calldata: ["0x0", "0x3"] });
  });

  it("the RPC fallback leaves the section out on an older DoomRuns without the D35 views", async () => {
    const rpc = {
      call: vi.fn(async (c: { entrypoint: string }) => {
        if (c.entrypoint === "player_run_count" || c.entrypoint === "player_runs") return ["0x0"];
        throw new Error("Entry point not found");
      }),
    } as unknown as RpcClient;
    const stats = await new RpcSource("http://rpc.invalid", "0x2e10", rpc).player("0xa11ce", 0, 20);
    expect(stats.pendingCommitments).toBeUndefined();
  });
});

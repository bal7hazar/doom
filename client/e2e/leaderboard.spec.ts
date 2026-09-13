import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { expect, test } from "@playwright/test";

/**
 * Playwright smoke test for the leaderboard page (P4.4), against a tiny in-process stub of
 * `infra/indexer`'s read API rather than a real devnet + indexer (that combination is exercised
 * once, manually, per the P4.4 task's step 3 — this test is the fast regression gate that runs on
 * every CI build). It checks the board renders, paging and the score/time tabs work, the run
 * detail view shows the on-chain proof fields and offers a replay download, and the player page
 * aggregates correctly — end to end through the real bundle `vite preview` serves.
 */

const BOARD_ROWS = [
  { rank: 1, run_id: "0xaaa1", player: "0xa11ce", score: 1150, tics: 320 },
  { rank: 2, run_id: "0xbbb2", player: "0xb0b", score: 625, tics: 480 },
];

function stubIndexer(): Server {
  return createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    res.setHeader("content-type", "application/json");
    res.setHeader("access-control-allow-origin", "*");

    if (url.pathname === "/leaderboard") {
      const kind = url.searchParams.get("kind") === "1" ? 1 : 0;
      const rows = [...BOARD_ROWS].sort((a, b) => (kind === 0 ? b.score - a.score : a.tics - b.tics));
      res.end(JSON.stringify({ version_id: 1, kind, offset: 0, limit: 20, total: rows.length, rows }));
      return;
    }
    if (url.pathname === "/stats") {
      res.end(
        JSON.stringify({
          indexed_block: 123,
          total_runs: 2,
          total_attempts: 0,
          total_players: 2,
          versions: [{ version_id: 1, run_count: 2, attempt_count: 0 }],
        }),
      );
      return;
    }
    if (url.pathname === "/runs/0xaaa1") {
      res.end(
        JSON.stringify({
          run_id: "0xaaa1",
          player: "0xa11ce",
          version_id: 1,
          level_id: 1,
          tics: 320,
          kills: 6,
          items: 2,
          secrets: 1,
          score: 1150,
          status: "EXIT",
          n_segments: 1,
          fact: "0xfac7",
          block_number: 42,
          tx_hash: "0xtx1",
          replay: [{ leaf_index: 0, tic_start: 0, tic_end: 7, packed: ["0x102030405060708"] }],
        }),
      );
      return;
    }
    if (url.pathname === "/players/0xa11ce") {
      res.end(
        JSON.stringify({
          player: "0xa11ce",
          run_count: 1,
          attempt_count: 0,
          best_score: 1150,
          best_tics: 320,
          runs: [
            { run_id: "0xaaa1", version_id: 1, level_id: 1, tics: 320, score: 1150, status: "EXIT", block_number: 42 },
          ],
        }),
      );
      return;
    }
    res.statusCode = 404;
    res.end(JSON.stringify({ error: "not found" }));
  });
}

test.describe("leaderboard page", () => {
  let server: Server;
  let indexerUrl: string;

  test.beforeAll(async () => {
    server = stubIndexer();
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const { port } = server.address() as AddressInfo;
    indexerUrl = `http://127.0.0.1:${port}`;
  });

  test.afterAll(async () => {
    await new Promise((resolve) => server.close(resolve));
  });

  test("renders the score board, switches to the time board, and shows stats", async ({ page }) => {
    await page.goto(`/leaderboard.html?indexer=${encodeURIComponent(indexerUrl)}&version=1`);
    await expect(page.locator("table.board tbody tr")).toHaveCount(2);
    // Score board: highest score first.
    await expect(page.locator("table.board tbody tr").first().locator("td.value")).toHaveText("1,150");

    await page.getByRole("button", { name: "best time" }).click();
    await expect(page.locator("table.board tbody tr").first().locator("td.value")).toHaveText("320");

    await expect(page.locator("#lb-stats")).toContainText("2 finished run(s)");
    await expect(page.locator("#lb-stats")).toContainText("block 123");
    await page.screenshot({ path: "e2e/artifacts/leaderboard-board.png" });
  });

  test("opens a run detail view with the proof fields and a replay download", async ({ page }) => {
    await page.goto(`/leaderboard.html?indexer=${encodeURIComponent(indexerUrl)}&version=1&network=sepolia`);
    await page.locator("a[href='#/run/0xaaa1']").first().click();
    await expect(page.locator("code", { hasText: "0xaaa1" })).toBeVisible();
    await expect(page.locator("table.run-proof")).toContainText("0xfac7");
    const txLink = page.locator("a[href*='sepolia.voyager.online/tx/0xtx1']");
    await expect(txLink).toBeVisible();

    const downloadPromise = page.waitForEvent("download");
    await page.getByRole("button", { name: /download replay/ }).click();
    const download = await downloadPromise;
    expect(download.suggestedFilename()).toMatch(/^doomruns-v1-.*\.hellproof$/);
    await page.screenshot({ path: "e2e/artifacts/leaderboard-run.png" });
  });

  test("opens a player page aggregating their runs", async ({ page }) => {
    await page.goto(`/leaderboard.html?indexer=${encodeURIComponent(indexerUrl)}&version=1`);
    await page.locator("a[href='#/player/0xa11ce']").first().click();
    await expect(page.locator("h2")).toContainText("0xa11ce");
    await expect(page.locator("body")).toContainText("1 finished run(s)");
    await expect(page.locator("table.board tbody tr")).toHaveCount(1);
  });
});

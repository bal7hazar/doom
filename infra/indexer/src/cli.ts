#!/usr/bin/env -S npx tsx
// SPDX-License-Identifier: Apache-2.0
/**
 * `doomruns-indexer` — follows `DoomRuns` events into SQLite and serves the read API (P4.4).
 *
 *   doomruns-indexer --rpc http://127.0.0.1:5081/rpc --address 0x... --start-block 0 \
 *     --db .work/indexer.sqlite --port 8788
 *
 * See `infra/indexer/README.md` for the API, the schema and the reorg story.
 */
import { IndexerDb } from "./db.js";
import { follow } from "./indexer.js";
import { StarknetRpcEventSource } from "./rpcSource.js";
import { createApiServer } from "./api.js";

const argv = process.argv.slice(2);
function arg(name: string, dflt?: string): string {
  const i = argv.indexOf(`--${name}`);
  if (i >= 0 && i + 1 < argv.length) return argv[i + 1]!;
  if (dflt !== undefined) return dflt;
  throw new Error(`missing --${name}`);
}
function flag(name: string): boolean {
  return argv.includes(`--${name}`);
}

function usage(): never {
  console.log(
    `doomruns-indexer — DoomRuns event indexer + read API (P4.4)

  --rpc <url>          Starknet JSON-RPC endpoint (default http://127.0.0.1:5081/rpc)
  --address <addr>     DoomRuns contract address
  --start-block <n>    first block to index (default 0)
  --db <path>          SQLite file (default .work/indexer.sqlite)
  --port <n>           read API port (default 8788)
  --reorg-depth <n>    blocks re-scanned on every poll (default 10)
  --interval-ms <n>    poll interval (default 5000)
  --once               poll once and exit (for scripts / tests), API not started`,
  );
  process.exit(0);
}

async function main(): Promise<void> {
  if (flag("help") || flag("h")) usage();

  const rpcUrl = arg("rpc", "http://127.0.0.1:5081/rpc");
  const address = arg("address");
  const startBlock = Number(arg("start-block", "0"));
  const dbPath = arg("db", ".work/indexer.sqlite");
  const port = Number(arg("port", "8788"));
  const reorgDepth = Number(arg("reorg-depth", "10"));
  const intervalMs = Number(arg("interval-ms", "5000"));

  const db = new IndexerDb(dbPath);
  const source = new StarknetRpcEventSource(rpcUrl);

  if (flag("once")) {
    const { pollOnce } = await import("./indexer.js");
    const result = await pollOnce(db, source, { address, startBlock, reorgDepth });
    console.log(`indexed up to block ${result.head}: ${result.eventsApplied} event(s) applied`);
    db.close();
    return;
  }

  const controller = new AbortController();
  process.on("SIGINT", () => controller.abort());
  process.on("SIGTERM", () => controller.abort());

  const server = createApiServer(db);
  server.listen(port, () => console.log(`doomruns-indexer: read API on http://127.0.0.1:${port}`));

  await follow(db, source, {
    address,
    startBlock,
    reorgDepth,
    intervalMs,
    signal: controller.signal,
    onPoll: (r) => {
      if (r.eventsApplied > 0) console.log(`block ${r.fromBlock}..${r.head}: ${r.eventsApplied} event(s) applied`);
    },
    onError: (e) => console.error(`poll failed: ${e instanceof Error ? e.message : String(e)}`),
  });

  server.close();
  db.close();
}

main().catch((e: Error) => {
  console.error(e.stack ?? e.message);
  process.exit(1);
});

// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * Submits the fixtures produced by `prover/wrapper/scripts/e2e_fixtures.sh` to a running wrapper,
 * and follows the run to its root proof. Doubles as the driver of the real load test:
 *
 * ```bash
 * npm run build
 * node dist-examples/submit.js \
 *   --url http://127.0.0.1:8787 --key "$WRAPPER_API_KEY" \
 *   --fixtures "$SCRATCH/wrapper-e2e" --runs 20
 * ```
 *
 * (Compile it with `npx tsc examples/submit.ts --outDir dist-examples --module nodenext
 * --target es2022`; it is an example, not part of the package build.)
 */

import { readFile } from "node:fs/promises";
import { WrapperClient, toSegmentSubmission } from "../src/index.js";

interface Manifest {
  segments: { index: number; args: string[]; output_preimage: string[]; proof_path: string }[];
}

function arg(name: string, fallback?: string): string {
  const i = process.argv.indexOf(`--${name}`);
  const value = i >= 0 ? process.argv[i + 1] : undefined;
  if (value === undefined) {
    if (fallback === undefined) throw new Error(`missing --${name}`);
    return fallback;
  }
  return value;
}

async function main(): Promise<void> {
  const client = new WrapperClient({ baseUrl: arg("url"), apiKey: arg("key", "") });
  const fixtures = arg("fixtures");
  const runs = Number(arg("runs", "1"));
  const solo = process.argv.includes("--solo");

  const manifest: Manifest = JSON.parse(await readFile(`${fixtures}/manifest.json`, "utf8"));
  const segments = await Promise.all(
    manifest.segments.map(async (s) =>
      toSegmentSubmission({
        index: s.index,
        args: s.args,
        outputPreimage: s.output_preimage,
        proofBytes: new Uint8Array(await readFile(s.proof_path)),
      }),
    ),
  );

  const started = Date.now();
  const ids: string[] = [];
  for (let i = 0; i < runs; i++) {
    // Distinct run ids; the segments are identical, so after the first run every leaf is a cache
    // hit — which is exactly what a load test of the *scheduler* wants to avoid. Vary the
    // fixtures when measuring prover throughput.
    const res = await client.submitRun(
      { run_id: `example-${started}-${i}`, program: "segment_stub", solo, segments },
      10_000,
    );
    console.log(`submitted ${res.run_id}: ${res.status}`);
    if (res.status === "rejected") throw new Error(`run ${res.run_id} was rejected`);
    ids.push(res.run_id);
  }

  for (const id of ids) {
    const run = await client.waitForRun(id, {
      onProgress: (r) =>
        process.stdout.write(
          `\r${r.run_id} ${r.status} ${r.progress.leaves_done}/${r.progress.segments} leaves`,
        ),
    });
    process.stdout.write("\n");
    if (run.status !== "done") throw new Error(`${id} ended as ${run.status}: ${run.error}`);
    const batch = await client.getBatch(run.batch_id!, { include: ["packed"] });
    console.log(
      `${id}: batch ${batch.batch_id} with ${batch.runs.length} run(s), ` +
        `${batch.leaves.length} leaves, root ${batch.root_proof_felt_count} felts, ` +
        `fold ${(batch.fold_ms ?? 0) / 1000}s, leaf total ${run.timings.leaf_ms_total / 1000}s`,
    );
  }
  console.log(`total ${(Date.now() - started) / 1000}s`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

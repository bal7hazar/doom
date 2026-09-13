// SPDX-License-Identifier: Apache-2.0
/**
 * Loading a batch from disk: either a wrapper response (`GET /v1/batches/{id}` saved to a JSON
 * file) or a **fixture directory** — one `spikes/s4/scripts/run_pipeline10.sh` results directory
 * such as `cairo/doom_contracts/crates/recursion_outputs/fixtures/B2-1_doom`.
 *
 * The fixture directory is the shape the Cairo side already ships and the only one that exists
 * before the wrapper is wired to real games, so it is what the devnet drive uses. Its files map
 * onto the wrapper response one for one:
 *
 * | fixture file | wrapper field |
 * |---|---|
 * | `packed_output.json` | `packed_output` — the fold tree carrying each leaf's preimage |
 * | `root.proof` / `root.proof.gz` | `root_proof_felts` |
 * | `batch.json` `leaves[].packed` | the packed input logs the client holds (replay, R10-A3) |
 * | `batch.json` `members[]` | `leaves[].run_id` — a game is one run |
 *
 * `batch.json` also pins the level and the genesis of the run, which the wrapper is supposed to
 * return with the batch (`doomruns.md` §12 q3).
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { gunzipSync } from "node:zlib";

import {
  parseWrapperBatch,
  type BatchResponse,
  type WrapperBatch,
} from "../../../client/src/chain/batch.js";
import { parseFeltStream } from "../../../client/src/chain/proof.js";

export interface LoadedBatch {
  batch: WrapperBatch;
  /** `run_id` → level id, as the wrapper would return it. */
  levelIds: Record<string, number>;
  /** Pinned genesis of the level, when the source knows it (fixtures do). */
  genesis?: bigint;
  versionId: number;
  name: string;
  source: "fixture-dir" | "wrapper-json";
}

interface FixturePlan {
  shape: unknown;
  version_id: number;
  level_id: number;
  genesis: string;
  members: { game: number; level_id: number; leaf_start: number; leaf_len: number }[];
  leaves: { game: number; segment: number; packed: (string | number)[]; output: string[] }[];
}

/** The root proof felts of a results directory: `root.proof`, else the committed `.gz`. */
export function rootProofFelts(dir: string): bigint[] {
  const plain = join(dir, "root.proof");
  if (existsSync(plain)) return parseFeltStream(readFileSync(plain, "utf8"));
  const packed = join(dir, "root.proof.gz");
  if (!existsSync(packed)) {
    throw new Error(`${dir}: neither root.proof nor root.proof.gz`);
  }
  return parseFeltStream(gunzipSync(readFileSync(packed)).toString("utf8"));
}

function loadFixtureDir(dir: string, withProof: boolean): LoadedBatch {
  const plan = JSON.parse(readFileSync(join(dir, "batch.json"), "utf8")) as FixturePlan;
  const packedOutput = JSON.parse(readFileSync(join(dir, "packed_output.json"), "utf8"));

  // A fixture's "game" index is its run: leaves carry their game, members their leaf range.
  const runOf = (leafIndex: number): string => {
    const m = plan.members.find(
      (x) => leafIndex >= x.leaf_start && leafIndex < x.leaf_start + x.leaf_len,
    );
    if (!m) throw new Error(`${dir}: leaf ${leafIndex} belongs to no member`);
    return `game${m.game}`;
  };

  const doc: BatchResponse = {
    batch_id: dir.split("/").pop() ?? dir,
    packed_output: packedOutput,
    leaves: plan.leaves.map((l, i) => ({
      position: i,
      run_id: runOf(i),
      segment_index: l.segment,
    })),
    logs: plan.leaves.map((l) => l.packed),
    ...(withProof ? { root_proof_felts: rootProofFelts(dir).map((f) => "0x" + f.toString(16)) } : {}),
  };
  return {
    batch: parseWrapperBatch(doc),
    levelIds: Object.fromEntries(plan.members.map((m) => [`game${m.game}`, m.level_id])),
    genesis: BigInt(plan.genesis),
    versionId: plan.version_id,
    name: doc.batch_id!,
    source: "fixture-dir",
  };
}

/** Loads a batch from a fixture directory or from a saved wrapper JSON response. */
export function loadBatch(path: string, options: { withProof?: boolean } = {}): LoadedBatch {
  const withProof = options.withProof ?? true;
  if (existsSync(join(path, "batch.json"))) return loadFixtureDir(path, withProof);

  const doc = JSON.parse(readFileSync(path, "utf8")) as BatchResponse & {
    version_id?: number;
    level_ids?: Record<string, number>;
    genesis?: string;
  };
  if (withProof && !doc.root_proof_felts) {
    throw new Error(`${path}: no root_proof_felts — fetch the batch with '?include=proof'`);
  }
  return {
    batch: parseWrapperBatch(doc),
    levelIds: doc.level_ids ?? {},
    ...(doc.genesis ? { genesis: BigInt(doc.genesis) } : {}),
    versionId: doc.version_id ?? 1,
    name: doc.batch_id ?? path,
    source: "wrapper-json",
  };
}

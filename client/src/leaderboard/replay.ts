// SPDX-License-Identifier: Apache-2.0
/**
 * Builds a `.hellproof`-compatible file from a run's on-chain `Replay` logs, so a player can
 * download someone's leaderboard run and load its input journal back into the client
 * (`client/src/store/hellproofFile.ts`'s `parseHellproofFile`/`importRun`).
 *
 * It reuses that module's exact container format (magic, header, manifest shape) and its
 * `RunRecord`/`SegmentRecord`/`InputRecord`/`HellproofManifest` types — a leaderboard-downloaded
 * replay is not produced by `exportRun` (which reads a local `RunStore` this page does not have),
 * but it is a file `parseHellproofFile` opens without modification. `proofs: []`: the chain
 * publishes packed **inputs**, never proof bytes, so this is an input log, not a re-provable run.
 * A segment lands with `stage: "planned"` for the same reason — it is not resumable proving
 * state, it is "here are the tics; re-execute if you want to prove or watch it again".
 *
 * D13's per-segment repacking means the leaves' `packed` felts cannot just be concatenated: each
 * `Replay` log restarts its 7-tics-per-felt grouping at that segment's own tic 0
 * (`docs/DECISIONS.md` D13, `doom_runs.cairo::check_logs`). So every leaf is unpacked back to raw
 * words first, and the whole run's words are then repacked continuously — the same layout the
 * client's own `TicLog` produces while recording live.
 */
import type { HellproofManifest } from "../store/hellproofFile.js";
import type { InputRecord } from "../store/runStore.js";
import type { RunRecord, SegmentRecord } from "../prove/types.js";
import { packLog, TICS_PER_FELT, unpackLog } from "../prove/ticcmd.js";
import type { RunDetail } from "./types.js";

const HELLPROOF_MAGIC = "HELLPROOF";
const HELLPROOF_FILE_VERSION = 1;
const HEADER_BYTES = 16;

/** Concatenates every leaf's own (independently packed) input log into one continuous journal,
 * in the order the game was played. Throws if the run carries no replay data at all — callers
 * should check `run.replay.length` before offering the download. */
export function reconstructJournal(run: RunDetail): { words: number[]; packed: string[]; tail: number[] } {
  const ordered = [...run.replay].sort((a, b) => a.leafIndex - b.leafIndex);
  const words: number[] = [];
  for (const leaf of ordered) {
    const segTics = leaf.ticEnd - leaf.ticStart;
    words.push(...unpackLog(leaf.packed, segTics));
  }
  const completeCount = Math.floor(words.length / TICS_PER_FELT) * TICS_PER_FELT;
  const packed = packLog(words.slice(0, completeCount));
  const tail = words.slice(completeCount);
  return { words, packed, tail };
}

/** A `RunRecord` that describes an on-chain run well enough for the store/UI to display it —
 * `keepOffline`/`notes` make clear it is an import, not a proof this machine produced. */
function runRecordOf(run: RunDetail): RunRecord {
  return {
    id: run.runId,
    createdAt: Date.now(),
    updatedAt: Date.now(),
    program: `doomruns-onchain-v${run.versionId}`,
    programHashFunction: "poseidon",
    genesis: "0x0", // not published on chain; the client would need `genesis_of` to fill this in
    stage: "proved",
    ticCount: run.tics,
    ticsPlanned: run.tics,
    segments: run.replay.length,
    keepOffline: false,
    finished: run.status === "EXIT",
    submission: { status: run.status, runId: run.runId },
    notes:
      `imported from a leaderboard replay download (run ${run.runId}, fact ${run.fact}); ` +
      "inputs only, no local proof — re-execute to prove or watch it again",
  };
}

function segmentRecordsOf(run: RunDetail): SegmentRecord[] {
  const ordered = [...run.replay].sort((a, b) => a.leafIndex - b.leafIndex);
  return ordered.map(
    (leaf): SegmentRecord => ({
      runId: run.runId,
      index: leaf.leafIndex,
      ticStart: leaf.ticStart,
      ticEnd: leaf.ticEnd,
      args: [],
      outputPreimage: [],
      publicOutputs: [],
      output: null,
      stage: "planned",
      proofBytes: 0,
      verified: false,
      attempts: 0,
      threads: 1,
      retriedSingleThread: false,
      timings: {},
      memoryBytes: 0,
      resources: null,
      submission: "local",
      updatedAt: Date.now(),
    }),
  );
}

/** The bytes of a `.hellproof` file carrying this run's input journal and no proofs. Readable
 * by `parseHellproofFile`/`importRun` unmodified. */
export function buildReplayFile(run: RunDetail): Uint8Array {
  if (run.replay.length === 0) {
    throw new Error(`run ${run.runId} published no replay logs — nothing to download (D13/R10-A3 is optional)`);
  }
  const { packed, tail } = reconstructJournal(run);
  const inputs: InputRecord = { runId: run.runId, ticCount: run.tics, packed, tail };

  const manifest: HellproofManifest = {
    format: "hellproof",
    version: HELLPROOF_FILE_VERSION,
    exportedAt: Date.now(),
    producer: "@hellproof/client leaderboard (P4.4)",
    run: runRecordOf(run),
    inputs,
    segments: segmentRecordsOf(run),
    proofs: [],
  };
  const manifestBytes = new TextEncoder().encode(JSON.stringify(manifest));

  const out = new Uint8Array(new ArrayBuffer(HEADER_BYTES + manifestBytes.byteLength));
  const view = new DataView(out.buffer);
  for (let i = 0; i < HELLPROOF_MAGIC.length; i++) out[i] = HELLPROOF_MAGIC.charCodeAt(i);
  view.setUint8(9, HELLPROOF_FILE_VERSION);
  view.setUint16(10, 0, true);
  view.setUint32(12, manifestBytes.byteLength, true);
  out.set(manifestBytes, HEADER_BYTES);
  return out;
}

export function replayFileName(run: RunDetail): string {
  return `doomruns-v${run.versionId}-${run.runId.slice(0, 10)}.hellproof`;
}

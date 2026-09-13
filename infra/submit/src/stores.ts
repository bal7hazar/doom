// SPDX-License-Identifier: Apache-2.0
/**
 * File-backed persistence for the CLI: the checkpoint echoes that make a run resumable, and the
 * L2 gas price samples that feed the 24 h median (R7-A2).
 *
 * The browser uses the same interfaces over `localStorage` (`client/src/ui/costScreen.ts`); the
 * split exists so `client/src/chain/` stays free of both `node:fs` and `window`.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

import type { EchoStore } from "../../../client/src/chain/sequence.js";
import type { GasSample, SampleStore } from "../../../client/src/chain/median.js";

function readJson<T>(path: string, fallback: T): T {
  try {
    return existsSync(path) ? (JSON.parse(readFileSync(path, "utf8")) as T) : fallback;
  } catch {
    return fallback;
  }
}

function writeJson(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(value, null, 1));
}

/**
 * Checkpoint echoes, keyed by `proof_id` and phase index.
 *
 * Without this a resume needs `starknet_traceTransaction` to recover the state the router
 * returned; with it, the state is on disk next to the batch. Both paths are supported because
 * neither is guaranteed: a public RPC may not expose traces, and a wiped profile has no file.
 */
export class FileEchoStore implements EchoStore {
  private readonly data: Record<string, string[]>;

  constructor(private readonly path: string) {
    this.data = readJson<Record<string, string[]>>(path, {});
  }

  get(proofId: bigint, phaseIndex: number): string[] | null {
    return this.data[`${proofId}:${phaseIndex}`] ?? null;
  }

  set(proofId: bigint, phaseIndex: number, echo: string[]): void {
    this.data[`${proofId}:${phaseIndex}`] = echo;
    writeJson(this.path, this.data);
  }
}

/** The 24 h window of L2 gas price samples. */
export class FileSampleStore implements SampleStore {
  constructor(private readonly path: string) {}

  load(): GasSample[] {
    return readJson<GasSample[]>(this.path, []);
  }

  save(samples: GasSample[]): void {
    writeJson(this.path, samples);
  }
}

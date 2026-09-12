// SPDX-License-Identifier: Apache-2.0
/**
 * `localStorage` behind the two persistence interfaces of `client/src/chain/`.
 *
 * The checkpoint echoes are what make a submission survive a closed tab: the router stores only
 * `poseidon(state)`, so without the state itself a resume has to go back to the node's
 * transaction trace — which works, but needs a node that serves traces. Keeping them here costs
 * a few hundred felts per proof and removes that dependency.
 *
 * The gas samples are the 24 h window of R7-A2. Both degrade to "no history" rather than
 * throwing when storage is unavailable (private windows, quota, a browser configured to block
 * site data): a cost screen must render even when nothing can be remembered.
 */

import type { EchoStore } from "../chain/sequence.js";
import type { GasSample, SampleStore } from "../chain/median.js";

function read<T>(key: string, fallback: T): T {
  try {
    const raw = globalThis.localStorage?.getItem(key);
    return raw ? (JSON.parse(raw) as T) : fallback;
  } catch {
    return fallback;
  }
}

function write(key: string, value: unknown): void {
  try {
    globalThis.localStorage?.setItem(key, JSON.stringify(value));
  } catch {
    /* a submission is not worth failing over a full quota */
  }
}

const ECHO_KEY = "hellproof.submission.echoes";
const SAMPLE_KEY = "hellproof.gas.samples";

export class LocalEchoStore implements EchoStore {
  constructor(private readonly key: string = ECHO_KEY) {}

  get(proofId: bigint, phaseIndex: number): string[] | null {
    return read<Record<string, string[]>>(this.key, {})[`${proofId}:${phaseIndex}`] ?? null;
  }

  set(proofId: bigint, phaseIndex: number, echo: string[]): void {
    const all = read<Record<string, string[]>>(this.key, {});
    all[`${proofId}:${phaseIndex}`] = echo;
    write(this.key, all);
  }

  /** Called once a fact is registered: the echoes of that proof id are dead weight. */
  clear(proofId: bigint): void {
    const all = read<Record<string, string[]>>(this.key, {});
    for (const k of Object.keys(all)) if (k.startsWith(`${proofId}:`)) delete all[k];
    write(this.key, all);
  }
}

export class LocalSampleStore implements SampleStore {
  constructor(private readonly key: string = SAMPLE_KEY) {}

  load(): GasSample[] {
    return read<GasSample[]>(this.key, []);
  }

  save(samples: GasSample[]): void {
    write(this.key, samples);
  }
}

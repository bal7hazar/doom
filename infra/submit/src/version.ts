// SPDX-License-Identifier: Apache-2.0
/**
 * The one-off owner setup of `DoomRuns`: `add_version` and `set_genesis`.
 *
 * Not part of a submission — a version is pinned once per season, by the owner, and the table is
 * add-only then frozen (R3-A6). It lives here because a devnet drive needs it before the first
 * `submit_batch`, and because every value it pins is derivable from the batch being submitted,
 * which is exactly the auditability `doomruns.md` §3 asks P4.3 for: the triple
 * `(program_hash, genesis, registry)` displayed by the client is the triple checked here.
 */

import type { WrapperBatch } from "../../../client/src/chain/batch.js";
import type { Call } from "../../../client/src/chain/rpc.js";

/** A Cairo short string: up to 31 ASCII bytes, big-endian, as a felt. */
export function shortString(text: string): bigint {
  if (text.length > 31) throw new Error(`short string too long: ${text}`);
  let v = 0n;
  for (const ch of new TextEncoder().encode(text)) v = (v << 8n) | BigInt(ch);
  return v;
}

/** Eight u32 words as the two u128 limbs of `Digest` (`doomruns_drive.py::digest_felts`). */
export function digestFelts(words: number[]): [bigint, bigint] {
  const limb = (part: number[]) =>
    part.reduce((a, w, i) => a + (BigInt(w) << BigInt(32 * i)), 0n);
  return [limb(words.slice(0, 4)), limb(words.slice(4))];
}

export interface VersionArgs {
  doomRuns: string;
  versionId: number;
  batch: WrapperBatch;
  router: string;
  registryName: string;
  /** `'blake'` or `'poseidon'`: the same executable hashed the other way has another hash (S4b). */
  programHashFunction?: string;
}

const hex = (v: bigint | number) => "0x" + BigInt(v).toString(16);

export function addVersionCall(args: VersionArgs): Call {
  const [leafLo, leafHi] = digestFelts(args.batch.leafCircuitHash);
  const [mvLo, mvHi] = digestFelts(args.batch.multiverifierHash);
  return {
    contractAddress: args.doomRuns,
    entrypoint: "add_version",
    calldata: [
      hex(args.versionId),
      hex(args.batch.programHash),
      hex(shortString(args.programHashFunction ?? "blake")),
      hex(leafLo),
      hex(leafHi),
      hex(mvLo),
      hex(mvHi),
      hex(shortString(args.registryName)),
      args.router,
    ],
  };
}

export function setGenesisCall(
  doomRuns: string,
  versionId: number,
  levelId: number,
  genesis: bigint,
): Call {
  return {
    contractAddress: doomRuns,
    entrypoint: "set_genesis",
    calldata: [hex(versionId), hex(levelId), hex(genesis)],
  };
}

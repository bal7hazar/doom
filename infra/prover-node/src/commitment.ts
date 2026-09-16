// SPDX-License-Identifier: Apache-2.0
/**
 * The input-log commitment (D13), ported from `cairo/doom_contracts/crates/doom_runs/src/segment.cairo`
 * (`inputs_seed`, `commit_input`, `commit_log`, `packed_len`) — itself a port of
 * `cairo/crates/state_hash` pinned against `cairo/crates/segment/bench/reference.py`.
 *
 * ```text
 * inputs_seed        = poseidon_hash_span(['HP.INPUTS', 1, 0])
 * commit_input(p, w) = hades_permutation(p, w, 2)[0]      -- starknet.js `computePoseidonHash`
 * commit_log(felts)  = fold commit_input from inputs_seed over the packed felts
 * ```
 *
 * Two commitments are computed with the same fold: the **run** commitment the player publishes
 * with `RunCommitted` (over the whole packed journal) and the **segment** commitment the Cairo
 * program itself emits as `inputs_commitment` (over the segment's own slice, re-packed from its
 * first tic — D13 is per segment, never chained). `test/commitment.test.ts` pins both against
 * the contract's own vectors and against the proved `B2-1_doom` fixture.
 */
import { hash } from "starknet";

import { packLog, TICS_PER_FELT } from "../../../client/src/prove/ticcmd.js";

/** `state_hash::tag::INPUT_LOG` — the short string `'HP.INPUTS'`. */
export const TAG_INPUT_LOG = shortString("HP.INPUTS");
/** `state_hash::SCHEMA_VERSION`. */
export const SCHEMA_VERSION = 1n;

/** A Cairo short string: up to 31 ASCII bytes, big-endian, as a felt. */
export function shortString(text: string): bigint {
  if (text.length > 31) throw new Error(`short string too long: ${text}`);
  let v = 0n;
  for (const ch of new TextEncoder().encode(text)) v = (v << 8n) | BigInt(ch);
  return v;
}

/** `state_hash::inputs_seed()`: the commitment of an empty log. */
export function inputsSeed(): bigint {
  return BigInt(hash.computePoseidonHashOnElements([TAG_INPUT_LOG, SCHEMA_VERSION, 0n]));
}

/** `state_hash::commit_input`: Starknet's 2-to-1 Poseidon over `(prev, packed)`. */
export function commitInput(prev: bigint, packed: bigint): bigint {
  return BigInt(hash.computePoseidonHash(prev, packed));
}

/** `segment::commit_log`: the fold over a packed log, from the seed. */
export function commitLog(packed: readonly bigint[]): bigint {
  let commitment = inputsSeed();
  for (const felt of packed) commitment = commitInput(commitment, felt);
  return commitment;
}

/** `segment::packed_len`: transport felts for `tics` tics, seven per felt, the last one short. */
export function packedLen(tics: number): number {
  return Math.ceil(tics / TICS_PER_FELT);
}

/** The commitment of a journal given as 32-bit words: pack seven to a felt, then fold. */
export function commitWords(words: readonly number[]): bigint {
  return commitLog(packLog(words).map((f) => BigInt(f)));
}

// SPDX-License-Identifier: Apache-2.0
/**
 * Calldata/return-value codecs for the handful of `DoomRuns` view functions the RPC fallback
 * calls directly (`source.ts`): `leaderboard`, `leaderboard_len`, `get_run`, `get_attempt`,
 * `player_run_count`, `player_runs`. Field order follows the `Serde` derive in
 * `cairo/doom_contracts/crates/doom_runs/src/doom_runs.cairo` exactly — `u32`/`u8`/`u64`/
 * `felt252`/`ContractAddress` each serialise as one felt, so decoding is "read N felts off the
 * front in struct-field order", the same convention `client/src/chain/batch.ts` uses for
 * `LeafOutput`.
 */

const hex = (v: bigint | number | string): string =>
  typeof v === "string" ? (v.startsWith("0x") ? v : "0x" + BigInt(v).toString(16)) : "0x" + BigInt(v).toString(16);

const num = (felt: string): number => Number(BigInt(felt));

export function leaderboardCalldata(versionId: number, kind: number, offset: number, limit: number): string[] {
  return [hex(versionId), hex(kind), hex(offset), hex(limit)];
}

export interface RawBoardRow {
  runId: string;
  player: string;
  value: number;
}

/** `Array<BoardRow>`: `[len, (run_id, player, value) * len]`. */
export function decodeBoardRows(out: string[]): RawBoardRow[] {
  const len = Number(BigInt(out[0] ?? "0x0"));
  const rows: RawBoardRow[] = [];
  let i = 1;
  for (let r = 0; r < len; r++) {
    rows.push({ runId: out[i]!, player: out[i + 1]!, value: num(out[i + 2]!) });
    i += 3;
  }
  return rows;
}

export interface RawRun {
  player: string;
  versionId: number;
  levelId: number;
  tics: number;
  kills: number;
  items: number;
  secrets: number;
  score: number;
  status: number;
  nSegments: number;
  block: number;
  fact: string;
}

/** `Run`: 12 felts, fixed layout (`doom_runs.cairo`'s `Run` struct, `Serde` derive order). */
export function decodeRun(out: string[]): RawRun {
  return {
    player: out[0]!,
    versionId: num(out[1]!),
    levelId: num(out[2]!),
    tics: num(out[3]!),
    kills: num(out[4]!),
    items: num(out[5]!),
    secrets: num(out[6]!),
    score: num(out[7]!),
    status: num(out[8]!),
    nSegments: num(out[9]!),
    block: num(out[10]!),
    fact: out[11]!,
  };
}

/** `player_run_count(player) -> u32`. */
export function decodeU32(out: string[]): number {
  return num(out[0] ?? "0x0");
}

/** `Array<felt252>`: `[len, ...values]`. */
export function decodeFeltArray(out: string[]): string[] {
  const len = Number(BigInt(out[0] ?? "0x0"));
  return out.slice(1, 1 + len);
}

export { hex as toHex };

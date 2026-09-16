// SPDX-License-Identifier: Apache-2.0
/**
 * The open-prover commitment of D35 (`DoomRuns.commit_run`), client side.
 *
 * The player's browser does not prove any more (P4.7): it plays, then **commits** the whole
 * packed input log with a bounty in escrow, and any address may prove the game and be paid.
 * What this module holds is everything about that call that can be computed and checked
 * without a wallet:
 *
 * * `commitLog(packed)` — the contract's `inputs_commitment` (`segment.cairo::commit_log`, a
 *   port of `cairo/crates/state_hash`): `poseidon_hash_span('HP.INPUTS', 1, 0)` as the seed,
 *   then one two-to-one Poseidon per transport felt. Computed locally so the run record can
 *   carry the id the contract will assign before the transaction is even signed;
 * * `commitmentIdOf(...)` — `poseidon('HP.COMMIT', version_id, level_id, player,
 *   inputs_commitment)`, the key under which `get_commitment` answers;
 * * `buildCommitCalls(...)` — the multicall `[approve(DoomRuns, bounty), commit_run(...)]` (the
 *   `approve` only when the bounty is non-zero) with the exact calldata the ABI takes:
 *   `packed.len() == packed_len(tics) = ceil(tics / 7)` is asserted here, as the contract does;
 * * `decodeCommitment(...)` — the `Commitment` struct as `get_commitment` returns it;
 * * `simulateCalls(...)` — one multicall priced with the *same* estimator, margins and prices
 *   as the submission sequence (`estimate.ts`), returned in the `SequenceEstimate` shape so the
 *   cost screen's pricing code (`priceEstimate`, `withPrices`) applies unchanged.
 *
 * ABI: `cairo/doom_contracts/README.md` "Open prover"; events and struct layouts are read off
 * `doom_runs.cairo` directly, as `infra/indexer/src/decode.ts` does.
 */

import { boundsFor, INVOKE_L2_GAS_CAP, simulationBounds, type SequenceEstimate, type StepEstimate } from "./estimate.js";
import { poseidonHash, poseidonHashMany, shortString } from "./poseidon.js";
import { feeEstimateOf, invokeV3, toHex, type Call, type RpcClient } from "./rpc.js";
import { getSelectorFromName } from "./selector.js";

/** `ticcmd::TICS_PER_FELT` — seven 32-bit input words per transport felt. */
export const TICS_PER_FELT = 7;

/** `state_hash::tag::INPUT_LOG` and `state_hash::SCHEMA_VERSION`. */
const TAG_INPUT_LOG = shortString("HP.INPUTS");
const SCHEMA_VERSION = 1n;
/** `doom_runs::TAG_COMMIT`. */
const TAG_COMMIT = shortString("HP.COMMIT");

/** `commit_status` of `doom_runs.cairo`. */
export const COMMIT_STATUS = { NONE: 0, PENDING: 1, PROVED: 2, RECLAIMED: 3 } as const;
export type CommitStatusCode = (typeof COMMIT_STATUS)[keyof typeof COMMIT_STATUS];

const felt = (v: bigint | number | string): bigint => (typeof v === "bigint" ? v : BigInt(v));

/** `state_hash::inputs_seed()`: the commitment of an empty log. */
export function inputsSeed(): bigint {
  return poseidonHashMany([TAG_INPUT_LOG, SCHEMA_VERSION, 0n]);
}

/** `state_hash::commit_input`: one two-to-one Poseidon fold. */
export function commitInput(prev: bigint, packed: bigint): bigint {
  return poseidonHash(prev, packed);
}

/** `segment::commit_log`: the fold of a packed log from the seed — the run's `inputs_commitment`. */
export function commitLog(packed: readonly (bigint | string)[]): bigint {
  let commitment = inputsSeed();
  for (const word of packed) commitment = commitInput(commitment, felt(word));
  return commitment;
}

/** `segment::packed_len`: `ceil(tics / 7)`, the exact felt count `commit_run` accepts. */
export function packedLen(tics: number): number {
  return Math.ceil(tics / TICS_PER_FELT);
}

/** `doom_runs::commitment_id_of`. */
export function commitmentIdOf(
  versionId: number,
  levelId: number,
  player: bigint | string,
  inputsCommitment: bigint | string,
): bigint {
  return poseidonHashMany([TAG_COMMIT, BigInt(versionId), BigInt(levelId), felt(player), felt(inputsCommitment)]);
}

/** A `u256` in calldata: the low 128 bits, then the high ones. */
export function u256Calldata(value: bigint): [string, string] {
  if (value < 0n || value >= 1n << 256n) throw new RangeError(`not a u256: ${value}`);
  return [toHex(value & ((1n << 128n) - 1n)), toHex(value >> 128n)];
}

export interface CommitRunArgs {
  versionId: number;
  levelId: number;
  /** The whole run's packed log, the last felt short (`TicLog.toFelts()`). */
  packed: readonly string[];
  /** Tics the log encodes; `packed.length` must be `packedLen(tics)`. */
  tics: number;
  /** Bounty in the fee token's smallest unit; zero allowed. */
  bounty: bigint;
}

/** Refuses what the contract would refuse, before anything is simulated or signed. */
export function checkCommitArgs(args: CommitRunArgs): void {
  if (!Number.isInteger(args.tics) || args.tics <= 0) throw new Error("commit_run: the run has no tics");
  if (args.packed.length !== packedLen(args.tics)) {
    throw new Error(
      `commit_run: ${args.packed.length} packed felt(s) for ${args.tics} tics, expected ${packedLen(args.tics)}`,
    );
  }
  if (args.bounty < 0n) throw new Error("commit_run: negative bounty");
}

/** `commit_run(version_id, level_id, packed: Span<felt252>, tics, bounty: u256)`. */
export function commitRunCalldata(args: CommitRunArgs): string[] {
  checkCommitArgs(args);
  return [
    toHex(args.versionId),
    toHex(args.levelId),
    toHex(args.packed.length),
    ...args.packed.map((f) => toHex(BigInt(f))),
    toHex(args.tics),
    ...u256Calldata(args.bounty),
  ];
}

/** ERC20 `approve(spender, amount: u256)`. */
export function approveCalldata(spender: string, amount: bigint): string[] {
  return [spender, ...u256Calldata(amount)];
}

export interface CommitCallsArgs extends CommitRunArgs {
  doomRuns: string;
  /** `DoomRuns.fee_token()`; needed only when the bounty is non-zero. */
  feeToken?: string;
}

/**
 * The multicall the wallet signs: the allowance first, then the commitment, in one
 * transaction — so a stuck `approve` cannot leave a dangling allowance, and the escrow
 * (`transfer_from` inside `commit_run`) finds the allowance it needs.
 */
export function buildCommitCalls(args: CommitCallsArgs): Call[] {
  checkCommitArgs(args);
  const calls: Call[] = [];
  if (args.bounty > 0n) {
    if (!args.feeToken) throw new Error("commit_run: a bounty needs the fee token address (fee_token())");
    calls.push({ contractAddress: args.feeToken, entrypoint: "approve", calldata: approveCalldata(args.doomRuns, args.bounty) });
  }
  calls.push({ contractAddress: args.doomRuns, entrypoint: "commit_run", calldata: commitRunCalldata(args) });
  return calls;
}

/** `reclaim(commitment_id)`. */
export function reclaimCall(doomRuns: string, commitmentId: bigint | string): Call {
  return { contractAddress: doomRuns, entrypoint: "reclaim", calldata: [toHex(felt(commitmentId))] };
}

/** `Commitment` as `get_commitment` / `commitment_of` return it. */
export interface Commitment {
  player: string;
  versionId: number;
  levelId: number;
  genesis: string;
  inputsCommitment: string;
  tics: number;
  bounty: bigint;
  createdBlock: number;
  expiresAt: number;
  status: CommitStatusCode;
  runId: string;
  prover: string;
}

const norm = (v: string): string => toHex(BigInt(v));

/** 13 felts in `Serde` order: the `u256` bounty is two of them. */
export function decodeCommitment(out: readonly string[]): Commitment {
  if (out.length < 13) throw new Error(`Commitment: expected 13 felts, got ${out.length}`);
  const status = Number(BigInt(out[10]!));
  if (status < 0 || status > 3) throw new Error(`Commitment: unknown status ${status}`);
  return {
    player: norm(out[0]!),
    versionId: Number(BigInt(out[1]!)),
    levelId: Number(BigInt(out[2]!)),
    genesis: norm(out[3]!),
    inputsCommitment: norm(out[4]!),
    tics: Number(BigInt(out[5]!)),
    bounty: BigInt(out[6]!) + (BigInt(out[7]!) << 128n),
    createdBlock: Number(BigInt(out[8]!)),
    expiresAt: Number(BigInt(out[9]!)),
    status: status as CommitStatusCode,
    runId: norm(out[11]!),
    prover: norm(out[12]!),
  };
}

export async function readCommitment(rpc: RpcClient, doomRuns: string, commitmentId: bigint | string): Promise<Commitment> {
  return decodeCommitment(
    await rpc.call({ contractAddress: doomRuns, entrypoint: "get_commitment", calldata: [toHex(felt(commitmentId))] }),
  );
}

export async function readFeeToken(rpc: RpcClient, doomRuns: string): Promise<string> {
  const out = await rpc.call({ contractAddress: doomRuns, entrypoint: "fee_token", calldata: [] });
  return norm(out[0] ?? "0x0");
}

export async function readBlockNumber(rpc: RpcClient): Promise<number> {
  return Number(await rpc.request<number | string>("starknet_blockNumber", []));
}

/** The `RunCommitted` event of a receipt, decoded just enough to check it against the plan. */
export interface RunCommittedEvent {
  commitmentId: string;
  player: string;
  versionId: number;
  levelId: number;
  inputsCommitment: string;
  tics: number;
  bounty: bigint;
  expiresAt: number;
  nChunks: number;
}

/** Finds `RunCommitted` in a receipt's events; `undefined` when the transaction emitted none. */
export function findRunCommitted(
  events: readonly { from_address?: string; keys?: string[]; data?: string[] }[] | undefined,
  doomRuns: string,
): RunCommittedEvent | undefined {
  const selector = BigInt(getSelectorFromName("RunCommitted"));
  for (const ev of events ?? []) {
    if (!ev.keys?.length || BigInt(ev.keys[0]!) !== selector) continue;
    if (ev.from_address && BigInt(ev.from_address) !== BigInt(doomRuns)) continue;
    const [, commitmentId, player, versionId] = ev.keys;
    const [levelId, , inputsCommitment, tics, bountyLow, bountyHigh, expiresAt, nChunks] = ev.data ?? [];
    if (!commitmentId || !player || !versionId || !nChunks) continue;
    return {
      commitmentId: norm(commitmentId),
      player: norm(player),
      versionId: Number(BigInt(versionId)),
      levelId: Number(BigInt(levelId!)),
      inputsCommitment: norm(inputsCommitment!),
      tics: Number(BigInt(tics!)),
      bounty: BigInt(bountyLow!) + (BigInt(bountyHigh!) << 128n),
      expiresAt: Number(BigInt(expiresAt!)),
      nChunks: Number(BigInt(nChunks)),
    };
  }
  return undefined;
}

/**
 * Simulates one multicall from `sender` and returns it as a one-step `SequenceEstimate`, so
 * the R7-A1 bounds (`boundsFor`) and the cost screen's pricing apply exactly as they do to the
 * submission sequence. `SKIP_VALIDATE`, empty signature: nothing can be broadcast.
 */
export async function simulateCalls(
  rpc: RpcClient,
  calls: Call[],
  options: { sender: string; label?: string },
): Promise<SequenceEstimate> {
  const prices = await rpc.gasPrices();
  const nonce = await rpc.nonce(options.sender);
  const tx = invokeV3(options.sender, calls, nonce, simulationBounds(prices));
  let flags = ["SKIP_VALIDATE"];
  let sim: unknown[];
  try {
    sim = await rpc.simulate([tx], flags);
  } catch (e) {
    if (flags.length !== 1) throw e;
    flags = ["SKIP_VALIDATE", "SKIP_FEE_CHARGE"];
    sim = await rpc.simulate([tx], flags);
  }
  const estimate = feeEstimateOf(sim[0]);
  const step: StepEstimate = {
    index: 0,
    label: options.label ?? "commit_run",
    phase: "consumer",
    calldataFelts: calls.reduce((n, c) => n + c.calldata.length, 0),
    estimate,
    pctOfCap: (100 * Number(estimate.l2GasConsumed)) / Number(INVOKE_L2_GAS_CAP),
  };
  return {
    steps: [step],
    bounds: [boundsFor(step, prices)],
    totalL2Gas: estimate.l2GasConsumed,
    totalL1DataGas: estimate.l1DataGasConsumed,
    totalFeeFri: estimate.overallFee,
    prices,
    sender: options.sender,
    simulationFlags: flags,
    echoes: [],
    at: new Date().toISOString(),
  };
}

/** Decimals of STRK (and of every fee token this client expects). */
export const TOKEN_DECIMALS = 18;

/** `"0.5"` → `500000000000000000n`: a whole-token decimal string to the smallest unit. */
export function parseTokenAmount(text: string, decimals = TOKEN_DECIMALS): bigint {
  const m = /^\s*(\d*)(?:\.(\d*))?\s*$/.exec(text);
  if (!m || (m[1] === "" && (m[2] ?? "") === "")) throw new RangeError(`not a token amount: ${JSON.stringify(text)}`);
  const whole = m[1] || "0";
  const frac = (m[2] ?? "").padEnd(decimals, "0");
  if (frac.length > decimals) throw new RangeError(`more than ${decimals} decimals: ${JSON.stringify(text)}`);
  return BigInt(whole) * 10n ** BigInt(decimals) + BigInt(frac || "0");
}

/** The inverse, trimmed of trailing zeros: `500000000000000000n` → `"0.5"`. */
export function formatTokenAmount(amount: bigint, decimals = TOKEN_DECIMALS): string {
  const unit = 10n ** BigInt(decimals);
  const whole = amount / unit;
  const frac = (amount % unit).toString().padStart(decimals, "0").replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : whole.toString();
}

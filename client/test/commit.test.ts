// @vitest-environment jsdom
// SPDX-License-Identifier: Apache-2.0
/**
 * The open-prover commitment (D35, P4.7) against a mocked node and a mocked wallet.
 *
 * Reference values come from two independent sources: the `doom_runs` contract's own test
 * vectors (`crates/doom_runs/tests/fixtures.cairo`: `INPUTS_SEED`, `NINE_TIC_COMMITMENT`) and
 * `poseidon_py` (StarkWare's C implementation), which produced every other constant below —
 * the permutation, `poseidon_hash`, `poseidon_hash_many`, the short journal's `commit_log` and
 * its `commitment_id` — so the TypeScript port is pinned against code it shares nothing with.
 */
import "fake-indexeddb/auto";
import { IDBFactory } from "fake-indexeddb";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  approveCalldata,
  buildCommitCalls,
  COMMIT_STATUS,
  commitLog,
  commitRunCalldata,
  commitmentIdOf,
  decodeCommitment,
  findRunCommitted,
  formatTokenAmount,
  inputsSeed,
  packedLen,
  parseTokenAmount,
  reclaimCall,
  simulateCalls,
  u256Calldata,
} from "../src/chain/commit.js";
import { hadesPermutation, poseidonHash, poseidonHashMany, shortString } from "../src/chain/poseidon.js";
import { StaticPriceSource } from "../src/chain/prices.js";
import { executeCalldata, toHex, type GasPrices, type RpcClient } from "../src/chain/rpc.js";
import { getSelectorFromName } from "../src/chain/selector.js";
import { commitPolicies, type Signer } from "../src/chain/signer.js";
import { commitStatusOf, packedJournal, RunCommitter } from "../src/prove/commit.js";
import { readOnChainConfig, type OnChainConfig } from "../src/prove/onchain.js";
import { ProveSession, type ProveSessionOptions } from "../src/prove/session.js";
import { pack7 } from "../src/prove/ticcmd.js";
import type { RunRecord } from "../src/prove/types.js";
import { RunStore } from "../src/store/runStore.js";
import { sessionPolicies } from "../src/ui/controllerConnect.js";
import { ProofQueuePanel } from "../src/ui/proofQueue.js";

const hex = (v: bigint): string => "0x" + v.toString(16);

// -- reference vectors ---------------------------------------------------------------------

/** `fixtures::INPUTS_SEED` of the contract tests (decimal there). */
const INPUTS_SEED = 1282518709132710633260571458233338951152986210120734438673228939417441244734n;
/** `fixtures::nine_tic_log()` and `NINE_TIC_COMMITMENT`. */
const NINE_TIC_LOG = [52862675047884335114613364565167029614684700343999192604006711424n, 36170118631293063n];
const NINE_TIC_COMMITMENT = 0x5a1a00832b34d6773e3ac371ddb6dfa8fef9813b137df243faf9539da38cad2n;

/** A nine-word journal, `[1..7]` then `[8, 9]`, and what `poseidon_py` says about it. */
const WORDS = [1, 2, 3, 4, 5, 6, 7, 8, 9];
const SHORT_LOG = ["0x7000000060000000500000004000000030000000200000001", "0x900000008"];
const SHORT_LOG_COMMITMENT = 0x2a487e329b782528d2e78a28c85708f9140289adca336a1e3e733f37fe920d1n;
const PLAYER = "0x34ba";
const SHORT_LOG_COMMITMENT_ID = 0x41d40fa574f040b0e2274eabd600adba330a3352c0fa10aee49a2da0c427060n;

describe("Poseidon (Starknet's Hades permutation)", () => {
  it("matches poseidon_py on the permutation and both hash conventions", () => {
    expect(hadesPermutation(1n, 2n, 3n).map(hex)).toEqual([
      "0xfa8c9b6742b6176139365833d001e30e932a9bf7456d009b1b174f36d558c5",
      "0x4f04deca4cb7f9f2bd16b1d25b817ca2d16fba2151e4252a2e2111cde08bfe6",
      "0x58dde0a2a785b395ee2dc7b60b79e9472ab826e9bb5383a8018b59772964892",
    ]);
    expect(hex(poseidonHash(1n, 2n))).toBe("0x5d44a3decb2b2e0cc71071f7b802f45dd792d064f0fc7316c46514f70f9891a");
    expect(hex(poseidonHashMany([]))).toBe("0x2272be0f580fd156823304800919530eaa97430e972d7213ee13f4fbf7a5dbc");
    expect(hex(poseidonHashMany([1n]))).toBe("0x579e8877c7755365d5ec1ec7d3a94a457eff5d1f40482bbe9729c064cdead2");
    expect(hex(poseidonHashMany([1n, 2n, 3n]))).toBe("0x2f0d8840bcf3bc629598d8a6cc80cb7c0d9e52d93dab244bbf9cd0dca0ad082");
  });

  it("reads short strings as Cairo does", () => {
    expect(shortString("HP.INPUTS")).toBe(0x48502e494e50555453n);
    expect(shortString("HP.COMMIT")).toBe(BigInt("0x" + Buffer.from("HP.COMMIT").toString("hex")));
  });
});

describe("commit_log and commitment_id", () => {
  it("folds from the contract's inputs_seed", () => {
    expect(inputsSeed()).toBe(INPUTS_SEED);
    expect(commitLog([])).toBe(INPUTS_SEED);
  });

  it("reproduces the contract's nine-tic reference vector", () => {
    expect(commitLog(NINE_TIC_LOG)).toBe(NINE_TIC_COMMITMENT);
    expect(commitLog(NINE_TIC_LOG.map(hex))).toBe(NINE_TIC_COMMITMENT);
  });

  it("packing → commit_log equals poseidon_py on a short journal, and the id follows", () => {
    const packed = [pack7(WORDS.slice(0, 7)), pack7(WORDS.slice(7))];
    expect(packed).toEqual(SHORT_LOG);
    expect(packed).toHaveLength(packedLen(WORDS.length));
    expect(commitLog(packed)).toBe(SHORT_LOG_COMMITMENT);
    expect(commitmentIdOf(1, 1, PLAYER, SHORT_LOG_COMMITMENT)).toBe(SHORT_LOG_COMMITMENT_ID);
    // Order-sensitive, as the contract test `commitment_is_order_sensitive` pins.
    expect(commitLog([1n, 2n])).not.toBe(commitLog([2n, 1n]));
    // The whole journal as the flow packs it: complete felts, then the tail as one more.
    expect(packedJournal({ packed: [SHORT_LOG[0]!], tail: [8, 9], ticCount: 9 })).toEqual(SHORT_LOG);
    expect(() => packedJournal({ packed: [SHORT_LOG[0]!], tail: [], ticCount: 9 })).toThrow(/expected 2/);
  });

  it("packed_len is ceil(tics / 7)", () => {
    expect([1, 6, 7, 8, 14, 15].map(packedLen)).toEqual([1, 1, 1, 2, 2, 3]);
  });
});

describe("the calldata", () => {
  it("builds approve + commit_run with the exact ABI layout when the bounty is non-zero", () => {
    const bounty = (1n << 128n) + 5n; // both u256 limbs exercised
    const calls = buildCommitCalls({ doomRuns: "0x2e10", feeToken: "0x57", versionId: 1, levelId: 2, packed: SHORT_LOG, tics: 9, bounty });
    expect(calls).toEqual([
      { contractAddress: "0x57", entrypoint: "approve", calldata: ["0x2e10", "0x5", "0x1"] },
      {
        contractAddress: "0x2e10",
        entrypoint: "commit_run",
        calldata: ["0x1", "0x2", "0x2", SHORT_LOG[0], SHORT_LOG[1], "0x9", "0x5", "0x1"],
      },
    ]);
    expect(calls[1]!.calldata.length).toBe(3 + packedLen(9) + 1 + 2);
    // What the account's __execute__ receives, selectors included.
    const cd = executeCalldata(calls);
    expect(cd[0]).toBe("0x2");
    expect(cd[2]).toBe(getSelectorFromName("approve"));
    expect(cd[1 + 3 + 3 + 1]).toBe(getSelectorFromName("commit_run")); // after [to, selector, len, 3 felts]
    expect(u256Calldata(0n)).toEqual(["0x0", "0x0"]);
    expect(approveCalldata("0x1", 7n)).toEqual(["0x1", "0x7", "0x0"]);
  });

  it("skips the allowance for a zero bounty and needs no fee token then", () => {
    const calls = buildCommitCalls({ doomRuns: "0x2e10", versionId: 3, levelId: 1, packed: SHORT_LOG, tics: 9, bounty: 0n });
    expect(calls.map((c) => c.entrypoint)).toEqual(["commit_run"]);
    expect(calls[0]!.calldata).toEqual(["0x3", "0x1", "0x2", SHORT_LOG[0], SHORT_LOG[1], "0x9", "0x0", "0x0"]);
    expect(() => buildCommitCalls({ doomRuns: "0x2e10", versionId: 3, levelId: 1, packed: SHORT_LOG, tics: 9, bounty: 1n })).toThrow(/fee token/);
  });

  it("refuses what the contract refuses: no tics, a packed length that is not packed_len(tics)", () => {
    expect(() => commitRunCalldata({ versionId: 1, levelId: 1, packed: [], tics: 0, bounty: 0n })).toThrow(/no tics/);
    expect(() => commitRunCalldata({ versionId: 1, levelId: 1, packed: SHORT_LOG, tics: 15, bounty: 0n })).toThrow(/expected 3/);
    expect(() => commitRunCalldata({ versionId: 1, levelId: 1, packed: [SHORT_LOG[0]!], tics: 9, bounty: 0n })).toThrow(/1 packed felt\(s\) for 9 tics, expected 2/);
    expect(() => commitRunCalldata({ versionId: 1, levelId: 1, packed: [...SHORT_LOG, "0x1"], tics: 9, bounty: 0n })).toThrow(/expected 2/);
  });

  it("decodes a Commitment (13 felts, u256 bounty) and reclaim's calldata", () => {
    const out = ["0x34ba", "0x1", "0x2", "0xdead", hex(SHORT_LOG_COMMITMENT), "0x9", "0x5", "0x1", "0x64", "0x6e", "0x2", "0x51", "0xb0b"];
    expect(decodeCommitment(out)).toEqual({
      player: "0x34ba",
      versionId: 1,
      levelId: 2,
      genesis: "0xdead",
      inputsCommitment: hex(SHORT_LOG_COMMITMENT),
      tics: 9,
      bounty: (1n << 128n) + 5n,
      createdBlock: 100,
      expiresAt: 110,
      status: COMMIT_STATUS.PROVED,
      runId: "0x51",
      prover: "0xb0b",
    });
    expect(() => decodeCommitment(out.slice(0, 12))).toThrow(/13 felts/);
    expect(reclaimCall("0x2e10", SHORT_LOG_COMMITMENT_ID)).toEqual({ contractAddress: "0x2e10", entrypoint: "reclaim", calldata: [hex(SHORT_LOG_COMMITMENT_ID)] });
  });

  it("reads token amounts both ways", () => {
    expect(parseTokenAmount("0.5")).toBe(500000000000000000n);
    expect(parseTokenAmount("2")).toBe(2n * 10n ** 18n);
    expect(parseTokenAmount(".25")).toBe(250000000000000000n);
    expect(() => parseTokenAmount("abc")).toThrow(/not a token amount/);
    expect(() => parseTokenAmount("")).toThrow(/not a token amount/);
    expect(formatTokenAmount(500000000000000000n)).toBe("0.5");
    expect(formatTokenAmount(0n)).toBe("0");
    expect(formatTokenAmount(3n * 10n ** 18n)).toBe("3");
  });

  it("extends the Controller session with exactly the commit entrypoints", () => {
    expect(commitPolicies({ doomRuns: "0x2e10", feeToken: "0x57" }).map((p) => [p.target, p.method])).toEqual([
      ["0x57", "approve"],
      ["0x2e10", "commit_run"],
      ["0x2e10", "reclaim"],
    ]);
    expect(commitPolicies({ doomRuns: "0x2e10" }).map((p) => p.method)).toEqual(["commit_run", "reclaim"]);
    const { contracts } = sessionPolicies("0x4fd8", "0x2e10", commitPolicies({ doomRuns: "0x2e10", feeToken: "0x57" }));
    expect(contracts["0x2e10"]!.methods.map((m) => m.entrypoint)).toEqual(["submit_batch", "register_member", "commit_run", "reclaim"]);
    expect(contracts["0x57"]!.methods.map((m) => m.entrypoint)).toEqual(["approve"]);
  });

  it("reads the default bounty in whole tokens and the fee token from the configuration", () => {
    const base = { VITE_RPC_URL: "http://x", VITE_ROUTER_ADDRESS: "0x4fd8", VITE_DOOM_RUNS_ADDRESS: "0x2e10", VITE_VERSION_ID: "1" };
    const none = readOnChainConfig(base, "");
    expect(none.ok && none.config.defaultBounty).toBe(0n);
    const some = readOnChainConfig({ ...base, VITE_DEFAULT_BOUNTY: "0.5", VITE_FEE_TOKEN: "0x57" }, "?bounty=2");
    expect(some.ok && some.config.defaultBounty).toBe(2n * 10n ** 18n);
    expect(some.ok && some.config.feeToken).toBe("0x57");
    const bad = readOnChainConfig({ ...base, VITE_DEFAULT_BOUNTY: "lots" }, "");
    expect(!bad.ok && bad.missing).toEqual(["VITE_DEFAULT_BOUNTY (or ?bounty=)"]);
  });
});

// -- the flow --------------------------------------------------------------------------------

const RUNS = "0x2e10";
const FEE_TOKEN = "0x57";
const CHAIN_ID = "0x534e5f5345504f4c4941";
const CONFIG: OnChainConfig = {
  rpcUrl: "http://rpc.invalid/",
  router: "0x4fd8",
  doomRuns: RUNS,
  versionId: 1,
  levelId: 1,
  chainId: CHAIN_ID,
  sponsored: false,
  replay: false,
  defaultBounty: 500000000000000000n,
};
const PRICES: GasPrices = {
  l1GasPriceFri: 0n,
  l1DataGasPriceFri: 1_000_000n,
  l2GasPriceFri: 10_000_000_000n,
  blockNumber: 100,
  timestamp: 1_789_000_000,
  starknetVersion: "0.14.4",
};
const EXPIRY = 50;

/** The contract's commitment table as the mocked node sees it. */
interface NodeState {
  block: number;
  commitments: Map<string, { status: number; player: string; inputsCommitment: string; tics: number; bounty: bigint; createdBlock: number; runId: string; prover: string }>;
}

const key = (id: string): string => hex(BigInt(id));

function mockRpc(state: NodeState) {
  return {
    chainId: vi.fn(async () => CHAIN_ID),
    gasPrices: vi.fn(async () => PRICES),
    nonce: vi.fn(async () => 7n),
    simulate: vi.fn(async (txs: Record<string, any>[]) =>
      txs.map(() => ({
        fee_estimation: { l1_gas_consumed: "0x0", l2_gas_consumed: hex(16_200_000n), l1_data_gas_consumed: "0xa", overall_fee: "0x0" },
      })),
    ),
    call: vi.fn(async (c: { entrypoint: string; calldata: string[] }) => {
      if (c.entrypoint === "fee_token") return [FEE_TOKEN];
      if (c.entrypoint === "get_commitment") {
        const c0 = state.commitments.get(key(c.calldata[0]!));
        if (!c0) return new Array<string>(13).fill("0x0");
        return [
          c0.player, "0x1", "0x1", "0xdead", c0.inputsCommitment, hex(BigInt(c0.tics)),
          ...u256Calldata(c0.bounty), hex(BigInt(c0.createdBlock)), hex(BigInt(c0.createdBlock + EXPIRY)),
          hex(BigInt(c0.status)), c0.runId, c0.prover,
        ];
      }
      throw new Error(`unexpected view call ${c.entrypoint}`);
    }),
    request: vi.fn(async (method: string) => {
      if (method === "starknet_blockNumber") return state.block;
      throw new Error(`unexpected request ${method}`);
    }),
    waitForReceipt: vi.fn(async (tx: string) => {
      const [id, c] = [...state.commitments.entries()].find(([, v]) => v.runId === tx) ?? [];
      return {
        execution_status: "SUCCEEDED",
        events: id && c
          ? [
              { from_address: RUNS, keys: [getSelectorFromName("RunCommitted"), id, c.player, "0x1"],
                data: ["0x1", "0xdead", c.inputsCommitment, hex(BigInt(c.tics)), ...u256Calldata(c.bounty), hex(BigInt(c.createdBlock + EXPIRY)), "0x1"] },
              { from_address: RUNS, keys: [getSelectorFromName("RunLog"), id], data: ["0x0", "0x0", "0x2", ...SHORT_LOG] },
            ]
          : [],
      };
    }),
  };
}

/** A wallet that records what it signed and, on `commit_run`, writes the contract's table. */
function mockSigner(state: NodeState, options: { fail?: boolean } = {}): Signer & { sent: { entrypoint: string; calldata: string[] }[] } {
  const sent: { entrypoint: string; calldata: string[] }[] = [];
  let n = 0;
  return {
    address: PLAYER,
    kind: "test",
    sent,
    execute: async (calls) => {
      if (options.fail) throw new Error("wallet closed");
      sent.push(...calls.map((c) => ({ entrypoint: c.entrypoint, calldata: c.calldata })));
      const tx = "0xc0" + (n++).toString(16);
      const commit = calls.find((c) => c.entrypoint === "commit_run");
      if (commit) {
        const cd = commit.calldata;
        const len = Number(BigInt(cd[2]!));
        const packed = cd.slice(3, 3 + len);
        const tics = Number(BigInt(cd[3 + len]!));
        const bounty = BigInt(cd[4 + len]!) + (BigInt(cd[5 + len]!) << 128n);
        const inputsCommitment = hex(commitLog(packed));
        const id = hex(commitmentIdOf(Number(BigInt(cd[0]!)), Number(BigInt(cd[1]!)), PLAYER, inputsCommitment));
        state.commitments.set(id, { status: COMMIT_STATUS.PENDING, player: PLAYER, inputsCommitment, tics, bounty, createdBlock: state.block, runId: tx, prover: "0x0" });
      }
      const reclaim = calls.find((c) => c.entrypoint === "reclaim");
      if (reclaim) state.commitments.get(key(reclaim.calldata[0]!))!.status = COMMIT_STATUS.RECLAIMED;
      return { transactionHash: tx };
    },
  };
}

let store: RunStore;
let host: HTMLElement;

async function localRun(words = WORDS): Promise<RunRecord> {
  const run = await store.createRun({ program: "doom_run", programHashFunction: "blake", genesis: "0xdead" });
  const complete = [];
  for (let i = 0; i + 7 <= words.length; i += 7) complete.push(pack7(words.slice(i, i + 7)));
  await store.putInputs({ runId: run.id, ticCount: words.length, packed: complete, tail: words.slice(complete.length * 7) });
  return (await store.getRun(run.id))!;
}

function committer(state: NodeState, signer: Signer, over: Partial<ConstructorParameters<typeof RunCommitter>[0]> = {}) {
  const rpc = mockRpc(state);
  const logs: string[] = [];
  const commit = new RunCommitter({
    config: CONFIG,
    store,
    host,
    log: (m) => logs.push(m),
    connectSigner: async () => signer,
    onKeepOffline: async () => {
      await store.updateRun((await store.listRuns())[0]!.id, { keepOffline: true });
    },
    rpc: rpc as unknown as RpcClient,
    priceSource: new StaticPriceSource({ usd: 0.5, eur: 0.4, at: "2026-09-15T00:00:00Z" }, "test quote"),
    ...over,
  });
  return { commit, rpc, logs };
}

const freshState = (): NodeState => ({ block: 100, commitments: new Map() });
const button = (act: string): HTMLButtonElement | null => host.querySelector(`button[data-act="${act}"]`);
const reviewShown = () => vi.waitFor(() => expect(button("commit")).not.toBeNull());

beforeEach(async () => {
  (globalThis as { indexedDB: IDBFactory }).indexedDB = new IDBFactory();
  store = await RunStore.open("hellproof-commit-test");
  host = document.createElement("div");
  document.body.append(host);
  localStorage.clear();
});

afterEach(() => {
  store.close();
  host.remove();
});

describe("committing a run", () => {
  it("computes the id locally, prices the multicall from the signing account and records the commitment", async () => {
    const state = freshState();
    const signer = mockSigner(state);
    const { commit, rpc, logs } = committer(state, signer);
    const run = await localRun();
    const outcome = commit.open(run);
    await reviewShown();

    // Nothing signed yet; the id and the log commitment are already on the record.
    expect(signer.sent).toEqual([]);
    const before = (await store.getRun(run.id))!.submission;
    expect(before.inputsCommitment).toBe(hex(SHORT_LOG_COMMITMENT));
    expect(before.commitmentId).toBe(hex(SHORT_LOG_COMMITMENT_ID));
    expect(before.commitStatus).toBeUndefined();
    // The simulation carried approve + commit_run from the player's account.
    const [txs] = rpc.simulate.mock.calls[0]! as [Record<string, any>[]];
    expect(txs).toHaveLength(1);
    expect(txs[0]!.sender_address).toBe(PLAYER);
    expect(txs[0]!.calldata[0]).toBe("0x2");
    expect(host.textContent).toMatch(/9 tics, 2 packed felt\(s\)/);
    expect(host.textContent).toMatch(/0\.1620 STRK/); // 16.2 M L2 gas × 10 gFri
    expect(host.textContent).toMatch(/0\.5 STRK/); // the default bounty
    expect(host.querySelector<HTMLInputElement>('input[data-field="bounty"]')!.value).toBe("0.5");
    expect(host.textContent).toMatch(/test quote/);

    button("commit")!.click();
    const result = await outcome;
    expect(result.choice).toBe("commit");
    expect(result.transactionHash).toBe("0xc00");
    expect(signer.sent.map((c) => c.entrypoint)).toEqual(["approve", "commit_run"]);
    expect(signer.sent[0]!.calldata).toEqual([RUNS, hex(500000000000000000n), "0x0"]);
    expect(signer.sent[1]!.calldata).toEqual(["0x1", "0x1", "0x2", ...SHORT_LOG, "0x9", hex(500000000000000000n), "0x0"]);
    const after = (await store.getRun(run.id))!.submission;
    expect(after).toMatchObject({
      commitmentId: hex(SHORT_LOG_COMMITMENT_ID),
      commitStatus: "pending",
      commitTx: "0xc00",
      commitBounty: "500000000000000000",
      commitExpiresAt: 150,
    });
    expect(after.error).toBeUndefined();
    expect(logs.at(-1)).toMatch(/^committed: 0x41d40fa574f0… in 0xc00, reclaimable from block 150/);
    expect(host.querySelector("h2")!.textContent).toBe("Your game is committed");
    // The wallet saw the same numbers the screen showed: the estimate's bounds, priced 2×.
    expect(host.querySelectorAll(".commit-screen a")).toHaveLength(1);
  });

  it("re-prices when the bounty is changed, and sends a single commit_run for a zero bounty", async () => {
    const state = freshState();
    const signer = mockSigner(state);
    const { commit, rpc } = committer(state, signer);
    const outcome = commit.open(await localRun());
    await reviewShown();
    const input = host.querySelector<HTMLInputElement>('input[data-field="bounty"]')!;
    input.value = "0";
    button("reprice")!.click();
    await vi.waitFor(() => expect(rpc.simulate).toHaveBeenCalledTimes(2));
    await reviewShown();
    expect((rpc.simulate.mock.calls[1]![0] as Record<string, any>[])[0]!.calldata[0]).toBe("0x1");
    expect(host.textContent).not.toMatch(/bounty in escrow/);
    button("commit")!.click();
    await outcome;
    expect(signer.sent.map((c) => c.entrypoint)).toEqual(["commit_run"]);
    expect(signer.sent[0]!.calldata.slice(-2)).toEqual(["0x0", "0x0"]);
  });

  it("never commits the same journal twice: a live id on the record, or PENDING/PROVED on chain", async () => {
    const state = freshState();
    const signer = mockSigner(state);
    const run = await localRun();
    // Somebody (this player, another device) already committed this very journal.
    const id = hex(SHORT_LOG_COMMITMENT_ID);
    state.commitments.set(id, { status: COMMIT_STATUS.PENDING, player: PLAYER, inputsCommitment: hex(SHORT_LOG_COMMITMENT), tics: 9, bounty: 0n, createdBlock: 90, runId: "0x0", prover: "0x0" });
    const first = committer(state, signer);
    expect(await first.commit.open(run)).toEqual({ choice: "none", commitmentId: id });
    expect(first.rpc.simulate).not.toHaveBeenCalled();
    expect(signer.sent).toEqual([]);
    expect(first.logs.at(-1)).toMatch(/already committed by 0x34ba… \(pending\)/);
    expect((await store.getRun(run.id))!.submission).toMatchObject({ commitmentId: id, commitStatus: "pending", commitExpiresAt: 140 });

    // The record now says "pending": refused before the wallet or the node is even asked.
    const second = committer(state, signer);
    expect(await second.commit.open((await store.getRun(run.id))!)).toEqual({ choice: "none", commitmentId: id });
    expect(second.rpc.call).not.toHaveBeenCalled();
    expect(second.logs.at(-1)).toMatch(/already committed \(pending/);

    // PROVED on chain, no local knowledge: refused too, and the prover is named.
    state.commitments.get(id)!.status = COMMIT_STATUS.PROVED;
    state.commitments.get(id)!.prover = "0xb0b";
    state.commitments.get(id)!.runId = "0x51";
    const other = await localRun();
    const third = committer(state, signer);
    expect(await third.commit.open(other)).toEqual({ choice: "none", commitmentId: id });
    expect(third.logs.at(-1)).toMatch(/proved, proved by 0xb0b/);
    expect((await store.getRun(other.id))!.submission).toMatchObject({ commitStatus: "proved", commitProver: "0xb0b", commitRunId: "0x51" });

    // A RECLAIMED one may be committed again (new escrow, new expiry).
    state.commitments.get(id)!.status = COMMIT_STATUS.RECLAIMED;
    const again = committer(state, signer);
    const outcome = again.commit.open(await localRun());
    await reviewShown();
    expect(again.logs.at(-1)).toMatch(/a reclaimed commitment: new escrow, new expiry/);
    button("cancel")!.click();
    expect(await outcome).toEqual({ choice: "cancel", commitmentId: id });
  });

  it("refuses a run kept offline, an empty journal, and keeps offline on request (C6)", async () => {
    const state = freshState();
    const signer = mockSigner(state);
    const kept = await localRun();
    await store.updateRun(kept.id, { keepOffline: true });
    const one = committer(state, signer);
    expect(await one.commit.open((await store.getRun(kept.id))!)).toEqual({ choice: "none" });
    expect(one.rpc.call).not.toHaveBeenCalled();
    expect(one.logs.at(-1)).toMatch(/kept offline/);

    const empty = await store.createRun({ program: "doom_run", programHashFunction: "blake", genesis: "0xdead" });
    const two = committer(state, signer);
    expect(await two.commit.open(empty)).toEqual({ choice: "none" });
    expect(two.logs.at(-1)).toMatch(/journal is empty/);

    const run = await localRun();
    // Three runs now share a millisecond: target this one explicitly, not "the first listed".
    const three = committer(state, signer, {
      onKeepOffline: async () => {
        await store.updateRun(run.id, { keepOffline: true });
      },
    });
    const outcome = three.commit.open(run);
    await reviewShown();
    button("offline")!.click();
    expect(await outcome).toMatchObject({ choice: "offline" });
    expect(signer.sent).toEqual([]);
    expect((await store.getRun(run.id))!.keepOffline).toBe(true);
    expect(host.querySelector(".commit-overlay")).toBeNull();
    // The journal is untouched: an export is still possible.
    expect((await store.getInputs(run.id)).ticCount).toBe(9);
  });

  it("records a wallet failure and lets the player try again", async () => {
    const state = freshState();
    const signer = mockSigner(state, { fail: true });
    const { commit, logs } = committer(state, signer);
    const run = await localRun();
    const outcome = commit.open(run);
    await reviewShown();
    button("commit")!.click();
    const result = await outcome;
    expect(result).toMatchObject({ choice: "commit", error: "wallet closed" });
    expect((await store.getRun(run.id))!.submission).toMatchObject({ commitStatus: "failed", error: "wallet closed" });
    expect(host.querySelector("h2")!.textContent).toBe("The commitment stopped");
    expect(button("retry")).not.toBeNull();
    expect(logs.at(-1)).toBe("commit stopped: wallet closed");
    // A failed commitment is not a live one: the next attempt goes through.
    const again = committer(state, mockSigner(state));
    const second = again.commit.open((await store.getRun(run.id))!);
    await vi.waitFor(() => expect(host.querySelectorAll('button[data-act="commit"]').length).toBeGreaterThan(0));
    [...host.querySelectorAll<HTMLButtonElement>('button[data-act="cancel"]')].at(-1)!.click();
    expect((await second).choice).toBe("cancel");
  });

  it("flags a RunCommitted event that disagrees with the local computation", async () => {
    const state = freshState();
    const signer = mockSigner(state);
    const { commit, rpc, logs } = committer(state, signer);
    rpc.waitForReceipt.mockImplementation(async () => ({
      execution_status: "SUCCEEDED",
      events: [{ from_address: RUNS, keys: [getSelectorFromName("RunCommitted"), "0x1234", PLAYER, "0x1"], data: ["0x1", "0xdead", "0x99", "0x9", "0x0", "0x0", "0x96", "0x1"] }],
    }));
    const run = await localRun();
    const outcome = commit.open(run);
    await reviewShown();
    button("commit")!.click();
    await outcome;
    const sub = (await store.getRun(run.id))!.submission;
    expect(sub.commitStatus).toBe("pending");
    expect(sub.error).toMatch(/RunCommitted disagrees.*id 0x1234 ≠ 0x41d40/);
    expect(sub.error).toMatch(/inputs_commitment 0x99 ≠/);
    expect(logs.some((l) => l.startsWith("WARNING: RunCommitted disagrees"))).toBe(true);
  });
});

describe("following a commitment", () => {
  it("maps the chain's status and the block onto the record", () => {
    const base = { player: PLAYER, versionId: 1, levelId: 1, genesis: "0x0", inputsCommitment: "0x0", tics: 9, bounty: 0n, createdBlock: 100, expiresAt: 150, runId: "0x0", prover: "0x0" };
    expect(commitStatusOf({ ...base, status: COMMIT_STATUS.PENDING }, 149)).toBe("pending");
    expect(commitStatusOf({ ...base, status: COMMIT_STATUS.PENDING }, 150)).toBe("expired");
    expect(commitStatusOf({ ...base, status: COMMIT_STATUS.PROVED }, 1)).toBe("proved");
    expect(commitStatusOf({ ...base, status: COMMIT_STATUS.RECLAIMED }, 1)).toBe("reclaimed");
    expect(commitStatusOf({ ...base, status: COMMIT_STATUS.NONE }, 1)).toBeUndefined();
  });

  it("refresh reads pending → proved by X, then expired, and reclaim refunds after expiry", async () => {
    const state = freshState();
    const signer = mockSigner(state);
    const run = await localRun();
    const { commit, logs } = committer(state, signer);
    const outcome = commit.open(run);
    await reviewShown();
    button("commit")!.click();
    await outcome;
    const id = hex(SHORT_LOG_COMMITMENT_ID);

    expect(await commit.refresh((await store.getRun(run.id))!)).toBe("pending");
    expect(logs.at(-1)).toMatch(/pending: waiting for a prover, reclaimable from block 150 \(now 100\)/);

    // Too early to reclaim: refused without touching the wallet.
    const early = await commit.reclaim((await store.getRun(run.id))!);
    expect(early).toEqual({ choice: "none", commitmentId: id });
    expect(signer.sent.map((c) => c.entrypoint)).toEqual(["approve", "commit_run"]);
    expect(logs.at(-1)).toMatch(/nothing to reclaim: the commitment is pending until block 150/);

    // A prover settles it.
    Object.assign(state.commitments.get(id)!, { status: COMMIT_STATUS.PROVED, prover: "0xb0b", runId: "0x51" });
    expect(await commit.refresh((await store.getRun(run.id))!)).toBe("proved");
    expect((await store.getRun(run.id))!.submission).toMatchObject({ commitStatus: "proved", commitProver: "0xb0b", commitRunId: "0x51" });
    expect(logs.at(-1)).toMatch(/proved by 0xb0b… as run 0x51…/);

    // Or nobody does, and the expiry block comes.
    Object.assign(state.commitments.get(id)!, { status: COMMIT_STATUS.PENDING, prover: "0x0", runId: "0x0" });
    state.block = 150;
    expect(await commit.refresh((await store.getRun(run.id))!)).toBe("expired");
    expect(logs.at(-1)).toMatch(/expired at block 150 \(now 150\)/);
    const reclaimed = await commit.reclaim((await store.getRun(run.id))!);
    expect(reclaimed).toMatchObject({ choice: "commit", commitmentId: id, transactionHash: "0xc01" });
    expect(signer.sent.at(-1)).toEqual({ entrypoint: "reclaim", calldata: [id] });
    expect((await store.getRun(run.id))!.submission.commitStatus).toBe("reclaimed");
    expect(await commit.refresh((await store.getRun(run.id))!)).toBe("reclaimed");
  });

  it("only the player reclaims", async () => {
    const state = freshState();
    const id = hex(SHORT_LOG_COMMITMENT_ID);
    state.commitments.set(id, { status: COMMIT_STATUS.PENDING, player: "0xa11ce", inputsCommitment: "0x0", tics: 9, bounty: 1n, createdBlock: 10, runId: "0x0", prover: "0x0" });
    state.block = 999;
    const signer = mockSigner(state);
    const { commit, logs } = committer(state, signer);
    const run = await localRun();
    await store.updateSubmission(run.id, { commitmentId: id, commitStatus: "pending" });
    expect(await commit.reclaim((await store.getRun(run.id))!)).toEqual({ choice: "none", commitmentId: id });
    expect(signer.sent).toEqual([]);
    expect(logs.at(-1)).toMatch(/only the player \(0xa11ce…\) can reclaim/);
  });

  it("the panel shows the state and offers reclaim only once expired", () => {
    const panel = new ProofQueuePanel();
    const refresh = panel.element.querySelector<HTMLButtonElement>('[data-act="commit-refresh"]')!;
    const reclaim = panel.element.querySelector<HTMLButtonElement>('[data-act="reclaim"]')!;
    const commit = panel.element.querySelector<HTMLButtonElement>('[data-act="commit"]')!;
    const line = panel.element.querySelector<HTMLElement>(".proof-queue-commit")!;
    panel.setCommitment({});
    expect(line.hidden).toBe(true);
    expect(refresh.hidden).toBe(true);
    expect(commit.disabled).toBe(false);
    const id = hex(SHORT_LOG_COMMITMENT_ID);
    panel.setCommitment({ commitmentId: id, commitStatus: "pending", commitExpiresAt: 150, commitTx: "0xc00", commitBounty: "5" });
    expect(line.textContent).toBe("committed 0x41d40fa574f0…: waiting for a prover (reclaimable from block 150) · bounty 5 · tx 0xc00");
    expect(refresh.hidden).toBe(false);
    expect(reclaim.hidden).toBe(true);
    expect(commit.disabled).toBe(true);
    panel.setCommitment({ commitmentId: id, commitStatus: "proved", commitProver: "0xb0b", commitRunId: "0x51" });
    expect(line.textContent).toBe("committed 0x41d40fa574f0…: proved by 0xb0b as run 0x51");
    panel.setCommitment({ commitmentId: id, commitStatus: "expired" });
    expect(reclaim.hidden).toBe(false);
    expect(commit.disabled).toBe(false);
    expect(line.textContent).toMatch(/expired unproved — the bounty can be reclaimed/);
    panel.setCommitment({ commitmentId: id, commitStatus: "failed", error: "wallet closed" });
    expect(line.textContent).toBe("commit failed: wallet closed");
    expect(reclaim.hidden).toBe(true);
    // Nothing that looks like a key is ever rendered: only ids, hashes and addresses.
    expect(panel.element.textContent).not.toMatch(/private|secret|mnemonic/i);
  });
});

describe("ProveSession.commit", () => {
  function sessionWith(run: RunRecord, options: Partial<ProveSessionOptions>) {
    const logs: string[] = [];
    const panel = new ProofQueuePanel();
    const session = Object.assign(Object.create(ProveSession.prototype), {
      disposed: false,
      verifying: false,
      verificationEpoch: 0,
      run,
      store,
      panel: Object.assign(panel, { log: (m: string) => logs.push(m) }),
      pipeline: { flushJournal: vi.fn(async () => undefined), syncGameJournal: vi.fn(async () => undefined) },
      options: { host, wrapperUrl: null, ...options },
    }) as ProveSession;
    return { session, logs, panel };
  }

  it("explains what is missing and touches no network without a configuration", async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    try {
      const { session, logs } = sessionWith(await localRun(), { onchain: { config: readOnChainConfig({}, "") } });
      await session.commit();
      expect(logs.at(-1)).toMatch(/the open-prover commitment is not configured — set VITE_RPC_URL \(or \?rpc=\)/);
      expect(fetchSpy).not.toHaveBeenCalled();
      const bare = sessionWith(await localRun(), {});
      await bare.session.commit();
      expect(bare.logs.at(-1)).toMatch(/no on-chain configuration: export the run/);
      expect(fetchSpy).not.toHaveBeenCalled();
      expect(host.querySelector(".commit-overlay")).toBeNull();
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("flushes the journal, runs the flow with the mocked RPC and signer, and updates the panel", async () => {
    const state = freshState();
    const signer = mockSigner(state);
    const rpc = mockRpc(state);
    const run = await localRun();
    const { session, logs, panel } = sessionWith(run, {
      onchain: {
        config: { ok: true, config: CONFIG },
        connectSigner: async () => signer,
        rpc: rpc as unknown as RpcClient,
        priceSource: new StaticPriceSource({ usd: 0.5, eur: 0.4, at: "2026-09-15T00:00:00Z" }),
      },
    });
    const committed = session.commit();
    await reviewShown();
    button("commit")!.click();
    await committed;
    expect((session.pipeline as unknown as { flushJournal: ReturnType<typeof vi.fn> }).flushJournal).toHaveBeenCalled();
    expect(signer.sent.map((c) => c.entrypoint)).toEqual(["approve", "commit_run"]);
    expect(logs.at(-1)).toMatch(/is committed; export \.hellproof to keep a copy/);
    expect(panel.element.querySelector(".proof-queue-commit")!.textContent).toMatch(/waiting for a prover \(reclaimable from block 150\)/);
    expect((await store.getRun(run.id))!.submission).toMatchObject({ commitStatus: "pending", commitmentId: hex(SHORT_LOG_COMMITMENT_ID) });
    await session.refreshCommitment();
    expect(logs.at(-1)).toMatch(/commitment pending/);
  });
});

describe("findRunCommitted and simulateCalls", () => {
  it("picks the DoomRuns event out of a receipt and ignores the rest", () => {
    const events = [
      { from_address: "0x57", keys: [getSelectorFromName("Approval")], data: [] },
      { from_address: RUNS, keys: [getSelectorFromName("RunCommitted"), "0xabc", PLAYER, "0x1"], data: ["0x2", "0xdead", "0x99", "0x9", "0x5", "0x0", "0x96", "0x1"] },
    ];
    expect(findRunCommitted(events, RUNS)).toEqual({ commitmentId: "0xabc", player: PLAYER, versionId: 1, levelId: 2, inputsCommitment: "0x99", tics: 9, bounty: 5n, expiresAt: 150, nChunks: 1 });
    expect(findRunCommitted(events, "0x999")).toBeUndefined();
    expect(findRunCommitted(undefined, RUNS)).toBeUndefined();
  });

  it("returns a one-step estimate with the R7-A1 bounds, retrying with SKIP_FEE_CHARGE", async () => {
    const state = freshState();
    const rpc = mockRpc(state);
    rpc.simulate.mockRejectedValueOnce(new Error("insufficient balance"));
    const calls = buildCommitCalls({ doomRuns: RUNS, versionId: 1, levelId: 1, packed: SHORT_LOG, tics: 9, bounty: 0n });
    const est = await simulateCalls(rpc as unknown as RpcClient, calls, { sender: PLAYER });
    expect(est.simulationFlags).toEqual(["SKIP_VALIDATE", "SKIP_FEE_CHARGE"]);
    expect(est.steps).toHaveLength(1);
    expect(est.steps[0]!).toMatchObject({ label: "commit_run", phase: "consumer", calldataFelts: 8 });
    expect(est.bounds[0]!.l2GasBound).toBe(BigInt(Math.ceil(16_200_000 * 1.15)));
    expect(est.bounds[0]!.overCap).toBe(false);
    expect(toHex(est.totalL2Gas)).toBe(hex(16_200_000n));
  });
});

// @vitest-environment jsdom
/**
 * The on-chain leg of a submission (P4.3, C5/C6) against a mocked node and a mocked wallet.
 *
 * The batch is the real `B2-1_doom` fixture (two games, three leaves, the committed root
 * proof), so the plan is the real five-transaction D28 cut and the calldata is what the router
 * would receive. The node is a stateful stand-in: a checkpoint, `Step` events and one retdata
 * per transaction, plus a fee simulation that returns one STRK per transaction index so the
 * screen's rows and totals can be checked to the cent.
 */
import "fake-indexeddb/auto";
import { IDBFactory } from "fake-indexeddb";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { gunzipSync } from "node:zlib";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { parseWrapperBatch, type BatchResponse, type WrapperBatch } from "../src/chain/batch.js";
import { StaticPriceSource } from "../src/chain/prices.js";
import { parseFeltStream } from "../src/chain/proof.js";
import type { GasPrices, RpcClient } from "../src/chain/rpc.js";
import { getSelectorFromName } from "../src/chain/selector.js";
import { TAG } from "../src/chain/sequence.js";
import type { Signer } from "../src/chain/signer.js";
import { OnChainSubmitter, proofIdFor, readOnChainConfig, type OnChainConfig } from "../src/prove/onchain.js";
import { ProveSession, type ProveSessionOptions } from "../src/prove/session.js";
import type { RunRecord } from "../src/prove/types.js";
import { RunStore } from "../src/store/runStore.js";
import { WrapperSubmitter } from "../src/wrapper/submitter.js";

// vitest runs from `client/`; under jsdom `import.meta.url` is an http: URL, so cwd it is.
const FIXTURE = join(process.cwd(), "../cairo/doom_contracts/crates/recursion_outputs/fixtures/B2-1_doom");
const ROUTER = "0x4fd8";
const RUNS = "0x2e10";
const PLAYER = "0x34ba";
const BATCH_ID = "batch-1";
const CHAIN_ID = "0x534e5f5345504f4c4941"; // SN_SEPOLIA, so accepted steps get an explorer link

const CONFIG: OnChainConfig = {
  rpcUrl: "http://rpc.invalid/",
  router: ROUTER,
  doomRuns: RUNS,
  versionId: 1,
  levelId: 1,
  chainId: CHAIN_ID,
  sponsored: false,
  replay: false,
  defaultBounty: 0n,
};

/** One STRK of L2 gas per transaction index, so rows read 1.00, 2.00, … and the total 21.00. */
const PRICES: GasPrices = {
  l1GasPriceFri: 0n,
  l1DataGasPriceFri: 1_000_000n,
  l2GasPriceFri: 10_000_000_000n,
  blockNumber: 7,
  timestamp: 1_789_000_000,
  starknetVersion: "0.14.4",
};
const L2_GAS_UNIT = 100_000_000n;

interface FixtureBatch {
  doc: BatchResponse & { status: string };
  genesis: string;
}

function loadFixture(): FixtureBatch {
  const plan = JSON.parse(readFileSync(join(FIXTURE, "batch.json"), "utf8")) as {
    genesis: string;
    members: { game: number; leaf_start: number; leaf_len: number }[];
    leaves: { segment: number }[];
  };
  const felts = parseFeltStream(gunzipSync(readFileSync(join(FIXTURE, "root.proof.gz"))).toString("utf8"));
  const runOf = (i: number): string =>
    `game${plan.members.find((m) => i >= m.leaf_start && i < m.leaf_start + m.leaf_len)!.game}`;
  return {
    doc: {
      batch_id: BATCH_ID,
      status: "done",
      packed_output: JSON.parse(readFileSync(join(FIXTURE, "packed_output.json"), "utf8")),
      leaves: plan.leaves.map((l, i) => ({ position: i, run_id: runOf(i), segment_index: l.segment })),
      root_proof_felts: felts.map((f) => "0x" + f.toString(16)),
    },
    genesis: plan.genesis,
  };
}

const fixture = loadFixture();
const batch: WrapperBatch = parseWrapperBatch(fixture.doc);

/** The router's state as the mocked node sees it. */
interface NodeState {
  tag: number;
  steps: { transactionHash: string; tag: number }[];
  retdata: Record<string, string[]>;
  fact: string;
}

const echoFor = (index: number): string[] =>
  Array.from({ length: index < 2 ? 228 : 576 }, (_, j) => "0x" + (index * 1000 + j + 1).toString(16));

function mockRpc(state: NodeState) {
  return {
    chainId: vi.fn(async () => CHAIN_ID),
    gasPrices: vi.fn(async () => PRICES),
    nonce: vi.fn(async () => 7n),
    simulate: vi.fn(async (txs: Record<string, any>[]) =>
      txs.map((_, k) => ({
        transaction_trace: {
          execute_invocation: { calls: [{ result: ["0x" + echoFor(k).length.toString(16), ...echoFor(k)] }] },
        },
        fee_estimation: {
          l1_gas_consumed: "0x0",
          l2_gas_consumed: "0x" + (L2_GAS_UNIT * BigInt(k + 1)).toString(16),
          l1_data_gas_consumed: "0xa",
          overall_fee: "0x0",
        },
      })),
    ),
    call: vi.fn(async (c: { entrypoint: string }) => {
      if (c.entrypoint === "checkpoint") return ["0x" + state.tag.toString(16), "0xdead"];
      throw new Error(`unexpected view call ${c.entrypoint}`);
    }),
    request: vi.fn(async (method: string, params: any) => {
      expect(method).toBe("starknet_getEvents");
      expect(params[0].keys[0]).toEqual([getSelectorFromName("Step")]);
      expect(params[0].keys[1]).toEqual([PLAYER]);
      return {
        events: state.steps.map((s) => ({
          transaction_hash: s.transactionHash,
          data: ["0x" + s.tag.toString(16), "0xdead"],
        })),
      };
    }),
    trace: vi.fn(async (tx: string) => {
      const result = state.retdata[tx];
      return result
        ? { execute_invocation: { calls: [{ result: ["0x" + result.length.toString(16), ...result] }] } }
        : {};
    }),
    waitForReceipt: vi.fn(async (tx: string) => ({
      execution_status: "SUCCEEDED",
      execution_resources: { l2_gas: 1_000, l1_data_gas: 10 },
      actual_fee: { amount: "0x64" },
      // The router emits the fact on the last FRI transaction, `(selector, fact)` + two data words.
      events: state.tag === TAG.DONE && tx === state.steps.at(-1)?.transactionHash
        ? [{ keys: [getSelectorFromName("Verified"), state.fact], data: ["0x1", "0x2"] }]
        : [],
    })),
  };
}

/** Tags the router leaves after each verifier phase of the five-transaction plan. */
const TAG_AFTER = [TAG.MERKLE, TAG.MERKLE, TAG.FRI, TAG.FRI, TAG.DONE];

/** A wallet that records what it signed and advances the mocked router. */
function mockSigner(state: NodeState, options: { failAt?: number } = {}): Signer & { sent: string[] } {
  let calls = 0;
  let failAt = options.failAt;
  const sent: string[] = [];
  return {
    address: PLAYER,
    kind: "test",
    sent,
    execute: async (calls_) => {
      const call = calls_[0]!;
      const index = calls++;
      if (failAt === index) {
        failAt = undefined;
        throw new Error("wallet closed");
      }
      sent.push(call.entrypoint);
      if (call.contractAddress === ROUTER) {
        const phase = state.steps.length;
        const transactionHash = "0xa" + phase.toString(16);
        state.tag = TAG_AFTER[phase]!;
        state.steps.push({ transactionHash, tag: state.tag });
        state.retdata[transactionHash] = echoFor(phase);
        return { transactionHash };
      }
      return { transactionHash: "0xc0" };
    },
  };
}

let store: RunStore;
let host: HTMLElement;

async function localRun(over: Partial<RunRecord["submission"]> = {}): Promise<RunRecord> {
  const run = await store.createRun({ program: "doom_run", programHashFunction: "blake", genesis: fixture.genesis });
  return store.updateSubmission(run.id, { runId: "game0", batchId: BATCH_ID, batchStatus: "done", ...over });
}

function submitter(state: NodeState, signer: Signer, over: Partial<ConstructorParameters<typeof OnChainSubmitter>[0]> = {}) {
  const rpc = mockRpc(state);
  const logs: string[] = [];
  const onchain = new OnChainSubmitter({
    config: CONFIG,
    store,
    host,
    log: (m) => logs.push(m),
    fetchBatch: async () => batch,
    connectSigner: async () => signer,
    onKeepOffline: async () => {
      await store.updateRun((await store.listRuns())[0]!.id, { keepOffline: true });
    },
    rpc: rpc as unknown as RpcClient,
    priceSource: new StaticPriceSource({ usd: 0.5, eur: 0.4, at: "2026-09-15T00:00:00Z" }, "test quote"),
    ...over,
  });
  return { onchain, rpc, logs };
}

const freshState = (): NodeState => ({ tag: TAG.FREE, steps: [], retdata: {}, fact: "0xfac7" });

const button = (act: string): HTMLButtonElement | null => host.querySelector(`button[data-act="${act}"]`);
const reviewShown = () => vi.waitFor(() => expect(button("submit")).not.toBeNull());
const cells = (row: Element): string[] => [...row.querySelectorAll("td")].map((td) => td.textContent ?? "");

beforeEach(async () => {
  (globalThis as { indexedDB: IDBFactory }).indexedDB = new IDBFactory();
  store = await RunStore.open("hellproof-onchain-test");
  host = document.createElement("div");
  document.body.append(host);
  localStorage.clear();
});

afterEach(() => {
  store.close();
  host.remove();
});

describe("the configuration", () => {
  it("names every missing variable and its URL parameter, and refuses to guess", () => {
    const result = readOnChainConfig({}, "");
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.missing).toEqual([
      "VITE_RPC_URL (or ?rpc=)",
      "VITE_ROUTER_ADDRESS (or ?router=)",
      "VITE_DOOM_RUNS_ADDRESS (or ?runs=)",
      "VITE_VERSION_ID (or ?version=)",
    ]);
    expect(result.message).toMatch(/not configured/);
    expect(result.message).toMatch(/C6/);
  });

  it("reads Vite variables, lets a URL parameter override them, and defaults the level to 1", () => {
    const result = readOnChainConfig(
      { VITE_RPC_URL: "http://127.0.0.1:5081/rpc", VITE_ROUTER_ADDRESS: ROUTER, VITE_DOOM_RUNS_ADDRESS: RUNS, VITE_VERSION_ID: "1" },
      "?version=3&sponsored=1",
    );
    expect(result).toEqual({
      ok: true,
      config: {
        rpcUrl: "http://127.0.0.1:5081/rpc",
        router: ROUTER,
        doomRuns: RUNS,
        versionId: 3,
        levelId: 1,
        sponsored: true,
        replay: false,
        defaultBounty: 0n,
      },
    });
  });

  it("rejects an address that is not a felt and a proof id that is not a number", () => {
    const result = readOnChainConfig(
      { VITE_RPC_URL: "x", VITE_ROUTER_ADDRESS: "router", VITE_DOOM_RUNS_ADDRESS: RUNS, VITE_VERSION_ID: "1", VITE_PROOF_ID: "abc" },
      "",
    );
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.missing).toEqual(["VITE_ROUTER_ADDRESS (or ?router=)", "VITE_PROOF_ID (or ?proofId=)"]);
  });

  it("derives a stable, non-zero proof id under 2^250 from the batch id", () => {
    expect(proofIdFor("1a7e")).toBe(0x1a7en);
    expect(proofIdFor("0x0")).toBe(1n);
    expect(proofIdFor("f".repeat(64))).toBeLessThan(1n << 250n);
    expect(proofIdFor(BATCH_ID)).toBe(proofIdFor(BATCH_ID));
    expect(proofIdFor(BATCH_ID)).not.toBe(proofIdFor("batch-2"));
    expect(proofIdFor(BATCH_ID)).toBeGreaterThan(0n);
  });
});

describe("a folded batch", () => {
  it("shows the five verifier transactions then DoomRuns, priced per transaction with the totals", async () => {
    const state = freshState();
    const signer = mockSigner(state);
    const { onchain, rpc, logs } = submitter(state, signer);
    const run = await localRun();
    const outcome = onchain.open(run, BATCH_ID);
    await reviewShown();

    const rows = [...host.querySelectorAll("tbody tr")].map(cells);
    expect(rows.map((r) => r[0])).toEqual([
      "Proof transcript",
      "Merkle decommitments",
      "Quotient answers",
      "FRI walk, part 1",
      "FRI walk, part 2",
      "Record the game", // register_member: the fixture folds two games and this run is one of them
    ]);
    expect(rows.map((r) => r[2])).toEqual(["1.00", "2.00", "3.00", "4.00", "5.00", "6.00"]);
    expect(rows.map((r) => r[3])).toEqual(["$0.500", "$1.000", "$1.500", "$2.000", "$2.500", "$3.000"]);
    expect(cells(host.querySelector("tfoot tr")!)).toEqual(["total", "", "21.00", "$10.50"]);
    expect(host.querySelector(".total")!.textContent).toBe("21.00 STRK ≈ $10.50 / €8.40");
    expect(host.textContent).toMatch(/test quote/);
    expect(host.textContent).toMatch(/cannot tell whether this is a spike/);
    expect(button("submit")!.textContent).toBe("Submit now — 21.00 STRK");
    expect(button("wait")).not.toBeNull();
    expect(button("offline")).not.toBeNull();

    // The whole ordered sequence was simulated from the signing account, nothing was signed.
    expect(rpc.simulate.mock.calls.map(([txs]) => (txs as unknown[]).length)).toEqual([1, 2, 3, 4, 6]);
    expect((rpc.simulate.mock.calls.at(-1)![0] as { sender_address: string }[])[0]!.sender_address).toBe(PLAYER);
    expect(signer.sent).toEqual([]);
    expect(logs.join("\n")).toMatch(/3 leaves, 5 verifier transaction\(s\) then register_member/);
    expect((await store.getRun(run.id))!.submission).toMatchObject({
      proofId: "0x" + proofIdFor(BATCH_ID).toString(16),
      chainStatus: "waiting",
    });

    button("wait")!.click();
    expect(await outcome).toEqual({ choice: "wait" });
    expect(host.querySelector(".onchain-overlay")).toBeNull();
    expect(signer.sent).toEqual([]);
  });

  it("keeps the run offline on 'keep offline' and sends nothing (C6)", async () => {
    const state = freshState();
    const signer = mockSigner(state);
    const { onchain } = submitter(state, signer);
    const run = await localRun();
    const outcome = onchain.open(run, BATCH_ID);
    await reviewShown();
    button("offline")!.click();
    expect(await outcome).toEqual({ choice: "offline" });
    expect(signer.sent).toEqual([]);
    expect(host.querySelector(".onchain-overlay")).toBeNull();
    const kept = (await store.getRun(run.id))!;
    expect(kept.keepOffline).toBe(true);
    expect((await store.listSegments(run.id)).length).toBe(0); // nothing deleted either
    // And a second attempt is refused before any wallet or node is touched.
    const again = submitter(state, signer);
    expect(await again.onchain.open(kept, BATCH_ID)).toEqual({ choice: "none" });
    expect(again.rpc.chainId).not.toHaveBeenCalled();
    expect(again.logs.at(-1)).toMatch(/kept offline/);
  });

  it("plays the signed sequence in order on 'submit' and records the fact", async () => {
    const state = freshState();
    const signer = mockSigner(state);
    const { onchain, logs } = submitter(state, signer);
    const run = await localRun();
    const outcome = onchain.open(run, BATCH_ID);
    await reviewShown();
    button("submit")!.click();
    const result = await outcome;
    expect(signer.sent).toEqual(["begin", "merkle", "answers", "fri", "fri", "register_member"]);
    expect(result.choice).toBe("submit");
    expect(result.fact).toBe("0xfac7");
    // `runSequence` reports `sending` then `accepted` per step; every step was accepted.
    expect(result.steps!.filter((s) => s.state === "accepted").map((s) => s.label)).toEqual([
      "begin", "merkle", "answers", "fri1", "fri2", "submit_batch",
    ]);
    expect(result.steps!.some((s) => s.state === "failed" || s.state === "skipped")).toBe(false);
    expect(host.querySelector("h2")!.textContent).toBe("Your game is on chain");
    expect(host.querySelectorAll(".steps a")).toHaveLength(6); // sepolia: an explorer link per transaction
    expect((await store.getRun(run.id))!.submission).toMatchObject({ chainStatus: "done", fact: "0xfac7" });
    expect(logs.at(-1)).toBe("fact registered: 0xfac7");
    // The fact is registered: the echoes of this proof id are cleared, the run can be closed.
    expect(localStorage.getItem("hellproof.submission.echoes")).toBe("{}");
    button("close")!.click();
    expect(host.querySelector(".onchain-overlay")).toBeNull();
  });

  it("resumes after an interruption between two transactions from the saved cut and echoes", async () => {
    const state = freshState();
    const proofId = proofIdFor(BATCH_ID);
    const first = mockSigner(state, { failAt: 2 });
    const one = submitter(state, first);
    const run = await localRun();
    const stopped = one.onchain.open(run, BATCH_ID);
    await reviewShown();
    button("submit")!.click();
    const outcome = await stopped;
    expect(outcome.error).toBe("wallet closed");
    expect(first.sent).toEqual(["begin", "merkle"]);
    expect(host.querySelector("h2")!.textContent).toBe("The submission stopped");
    expect((await store.getRun(run.id))!.submission).toMatchObject({ chainStatus: "failed", error: "wallet closed" });

    // What the browser saved before the first send: the D28 cut and the two echoes.
    const saved = JSON.parse(localStorage.getItem("hellproof.submission.echoes")!) as Record<string, string[]>;
    expect(saved[`${proofId}:-1`]).toEqual(["hellproof.fri-plan.v1", ROUTER, PLAYER, "2"]);
    expect(saved[`${proofId}:0`]).toEqual(echoFor(0));
    expect(saved[`${proofId}:1`]).toEqual(echoFor(1));
    expect(one.rpc.trace).toHaveBeenCalledTimes(2);

    // A reload: a new screen, the same storage, the same batch id — hence the same proof id.
    host.remove();
    host = document.createElement("div");
    document.body.append(host);
    const second = mockSigner(state);
    const two = submitter(state, second);
    const resumed = two.onchain.open((await store.getRun(run.id))!, BATCH_ID);
    await reviewShown();
    expect(host.textContent).toMatch(/2 already paid for and skipped/);
    // Only what is left is priced: answers, fri1, fri2 and the consumer.
    expect([...host.querySelectorAll("tbody tr")].map((r) => cells(r)[0])).toEqual([
      "Quotient answers",
      "FRI walk, part 1",
      "FRI walk, part 2",
      "Record the game",
    ]);
    expect(two.rpc.simulate.mock.calls.map(([txs]) => (txs as unknown[]).length)).toEqual([1, 2, 4]);
    // The echo came from the store, not from a trace round trip.
    expect(two.rpc.trace).not.toHaveBeenCalled();

    button("submit")!.click();
    const done = await resumed;
    expect(second.sent).toEqual(["answers", "fri", "fri", "register_member"]);
    expect(done.fact).toBe("0xfac7");
    expect(done.steps!.filter((s) => s.state === "skipped").map((s) => s.label)).toEqual(["begin", "merkle"]);
    // Traces: one per verifier transaction just sent, none for the resume itself.
    expect(two.rpc.trace).toHaveBeenCalledTimes(3);
    expect((await store.getRun(run.id))!.submission).toMatchObject({ chainStatus: "done", fact: "0xfac7" });
  });

  it("refuses a batch that would be rejected on chain before anything is paid for", async () => {
    const state = freshState();
    const signer = mockSigner(state);
    // Claim all three leaves for one run: leaf 2 starts a new game, so the chain breaks.
    const broken: WrapperBatch = {
      ...batch,
      placements: batch.placements.map((p, i) => ({ ...p, runId: "game0", segmentIndex: i })),
    };
    const { onchain, rpc } = submitter(state, signer, { fetchBatch: async () => broken });
    await expect(onchain.open(await localRun(), BATCH_ID)).rejects.toThrow(/chain break/);
    expect(rpc.simulate).not.toHaveBeenCalled();
    expect(signer.sent).toEqual([]);
  });

  it("refuses a batch without its proof felts, or without this run", async () => {
    const state = freshState();
    const signer = mockSigner(state);
    const { rootProofFelts: _dropped, ...bare } = batch;
    const noProof = submitter(state, signer, { fetchBatch: async () => bare });
    await expect(noProof.onchain.open(await localRun(), BATCH_ID)).rejects.toThrow(/include=proof/);
    const other = submitter(state, signer);
    await expect(other.onchain.open(await localRun({ runId: "game9" }), BATCH_ID)).rejects.toThrow(/does not contain run game9/);
    expect(other.rpc.chainId).not.toHaveBeenCalled();
  });
});

describe("the wrapper's batch endpoint", () => {
  it("fetches the proof with ?include=proof and mirrors the felt count", async () => {
    const run = await localRun();
    const urls: string[] = [];
    const submitter = new WrapperSubmitter({
      baseUrl: "http://wrapper.invalid",
      store,
      fetchImpl: (async (input: RequestInfo | URL) => {
        urls.push(String(input));
        return new Response(JSON.stringify(fixture.doc), { status: 200, headers: { "content-type": "application/json" } });
      }) as typeof fetch,
    });
    const fetched = await submitter.fetchBatchProof(run.id, BATCH_ID);
    expect(urls).toEqual([`http://wrapper.invalid/v1/batches/${BATCH_ID}?include=proof`]);
    expect(fetched.rootProofFelts).toHaveLength(batch.rootProofFelts!.length);
    expect(fetched.placements.map((p) => p.runId)).toEqual(["game0", "game0", "game1"]);
    expect((await store.getRun(run.id))!.submission.rootProofFeltCount).toBe(batch.rootProofFelts!.length);
  });
});

describe("ProveSession.submit", () => {
  /** A session with everything the on-chain leg touches and nothing it does not. */
  function sessionWith(run: RunRecord, options: Partial<ProveSessionOptions>) {
    const logs: string[] = [];
    const session = Object.assign(Object.create(ProveSession.prototype), {
      disposed: false,
      verifying: false,
      verificationEpoch: 0,
      run,
      store,
      panel: { log: (m: string) => logs.push(m), setKeepOffline: vi.fn(), element: host },
      pipeline: {},
      options: { host, wrapperUrl: null, ...options },
    }) as ProveSession;
    return { session, logs };
  }

  it("explains what is missing and touches no network when nothing is configured", async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    try {
      const { session, logs } = sessionWith(await localRun(), { onchain: { config: readOnChainConfig({}, "") } });
      await session.submit();
      expect(logs.at(-1)).toMatch(/not configured — set VITE_RPC_URL \(or \?rpc=\), VITE_ROUTER_ADDRESS/);
      expect(fetchSpy).not.toHaveBeenCalled();
      expect(host.querySelector(".onchain-overlay")).toBeNull();
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("goes straight to the cost screen when the batch id is already known (a 'wait' pressed again)", async () => {
    const state = freshState();
    const signer = mockSigner(state);
    const rpc = mockRpc(state);
    const { session, logs } = sessionWith(await localRun(), {
      onchain: {
        config: { ok: true, config: CONFIG },
        connectSigner: async () => signer,
        fetchBatch: async () => batch,
        rpc: rpc as unknown as RpcClient,
        priceSource: new StaticPriceSource({ usd: 0.5, eur: 0.4, at: "2026-09-15T00:00:00Z" }),
      },
    });
    const submitted = session.submit();
    await reviewShown();
    button("submit")!.click();
    await submitted;
    expect(signer.sent).toEqual(["begin", "merkle", "answers", "fri", "fri", "register_member"]);
    expect(logs.at(-1)).toMatch(/is on chain \(fact 0xfac7/);
  });

  it("refuses a run kept offline before the wrapper or the chain is asked (C6)", async () => {
    const run = await localRun();
    await store.updateRun(run.id, { keepOffline: true });
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    try {
      const { session, logs } = sessionWith(run, {
        wrapperUrl: "http://wrapper.invalid",
        onchain: { config: { ok: true, config: CONFIG } },
      });
      await session.submit();
      expect(logs.at(-1)).toMatch(/kept offline/);
      expect(fetchSpy).not.toHaveBeenCalled();
    } finally {
      vi.unstubAllGlobals();
    }
  });
});

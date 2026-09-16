// SPDX-License-Identifier: Apache-2.0
/**
 * The integration test: the real orchestrator against an optimized P4.1 router on a real (local)
 * devnet — and, around it, the D35 open-prover round from two accounts.
 *
 * Skipped — not failed — when `SUBMIT_TEST_RPC` is unset or nothing answers there, so a clone
 * with no devnet still has a green `npm test`. To run it:
 *
 *   starknet-devnet --seed 42 --port 5081 …            (see README.md)
 *   scripts/devnet_setup.sh .work/accounts.json http://127.0.0.1:5081/rpc .work/deployment.json
 *   SUBMIT_TEST_RPC=http://127.0.0.1:5081/rpc \
 *   SUBMIT_TEST_ROUTER=<router> SUBMIT_TEST_RUNS=<doom_runs> \
 *   SUBMIT_TEST_ACCOUNT=<addr>:<key> \
 *   SUBMIT_TEST_PLAYER=<addr>:<key>  npx vitest run test/devnet.test.ts
 *
 * `SUBMIT_TEST_ACCOUNT` submits (the owner of the setup script's `DoomRuns`, and the *prover*
 * of the commitment round); `SUBMIT_TEST_PLAYER`, another predeployed account, commits. Without
 * it the two commitment tests skip themselves and the submission runs as before.
 *
 * What it pins is the property the whole lane exists for: the estimate of the ordered sequence
 * is within C5's 20 % of what the receipts bill, and the fact the router registers from the
 * TypeScript calldata is the one P4.2b recorded for the same batch. The commitment tests pin
 * the D35 round end to end, with the code the browser, the indexer and the prover node use:
 * `buildCommitCalls` → `RunCommitted`/`RunLog` decoded by `infra/indexer` and reassembled by
 * `infra/prover-node`, the consumer transaction of the *other* account settling it
 * (`CommitmentProved`, bounty paid to the caller, `get_commitment` = PROVED), then a second
 * commitment nothing settles, refused before expiry and reclaimed after it.
 */

import { join } from "node:path";
import { beforeAll, describe, expect, it } from "vitest";

import { packLog, unpackLog } from "../../../client/src/prove/ticcmd.js";
import {
  buildCommitCalls,
  COMMIT_STATUS,
  commitLog,
  commitmentIdOf,
  findRunCommitted,
  readCommitment,
  readFeeToken,
  reclaimCall,
  simulateCalls,
  u256Calldata,
} from "../../../client/src/chain/commit.js";
import { priceEstimate, simulateSequence, withPrices } from "../../../client/src/chain/estimate.js";
import { RpcClient, toHex, type Call } from "../../../client/src/chain/rpc.js";
import { resumePoint, runSequence } from "../../../client/src/chain/sequence.js";
import { prepareSubmission } from "../../../client/src/chain/submission.js";
import { StaticPriceSource, S5_SNAPSHOT } from "../../../client/src/chain/prices.js";
import { decodeEvent } from "../../indexer/src/decode.js";
import type { RawEvent } from "../../indexer/src/types.js";
import {
  assembleJournal,
  commitmentIdOf as nodeCommitmentIdOf,
  decodeCommitmentEvent,
  settlementIn,
  type RunCommittedEvent,
  type RunLogEvent,
} from "../../prover-node/src/commitments.js";
import { DevnetSigner } from "../src/devnetSigner.js";
import { loadBatch, type LoadedBatch } from "../src/fixture.js";
import { addVersionCall, setGenesisCall } from "../src/version.js";

const RPC = process.env["SUBMIT_TEST_RPC"];
const ROUTER = process.env["SUBMIT_TEST_ROUTER"];
const RUNS = process.env["SUBMIT_TEST_RUNS"];
const ACCOUNT = process.env["SUBMIT_TEST_ACCOUNT"];
const PLAYER = process.env["SUBMIT_TEST_PLAYER"];
/** The fact `results/e2e_10felt_receipts.json` recorded for `B2-1_doom` in P4.2b. */
const EXPECTED_FACT = "0x53ae959ad8221763147edc9660adf753b1fa6423cd353914e304a00a98c3c40";
const FIXTURE = join(
  import.meta.dirname,
  "../../../cairo/doom_contracts/crates/recursion_outputs/fixtures/B2-1_doom",
);
/** One token of the fee token (18 decimals), escrowed by each commitment. */
const BOUNTY = 10n ** 18n;
/** Empty blocks the reclaim test is willing to mine (`devnet_createBlock`) to reach expiry. */
const MAX_MINED_BLOCKS = 2_000;

let reachable = false;
beforeAll(async () => {
  if (!RPC || !ROUTER || !RUNS || !ACCOUNT) return;
  try {
    await new RpcClient(RPC, { timeoutMs: 3_000 }).specVersion();
    reachable = true;
  } catch {
    reachable = false;
  }
});

const norm = (v: string): string => toHex(BigInt(v));

/** A receipt's events as the indexer's `RawEvent`s, restricted to one contract. */
function rawEvents(receipt: any, contract: string): RawEvent[] {
  return ((receipt.events ?? []) as { from_address: string; keys: string[]; data: string[] }[])
    .filter((e) => BigInt(e.from_address) === BigInt(contract))
    .map((e) => ({
      from_address: e.from_address,
      keys: e.keys,
      data: e.data,
      block_number: Number(receipt.block_number ?? 0),
      block_hash: receipt.block_hash ?? "0x0",
      transaction_hash: receipt.transaction_hash,
    }));
}

/**
 * The whole packed journal of one wrapper run of the fixture and its tic count: every leaf's
 * log is packed from its own first tic, so the run's log is their words re-packed from tic 0
 * (`infra/prover-node/src/journal.ts` does the inverse cut).
 */
function journalOf(loaded: LoadedBatch, runId: string): { packed: string[]; tics: number; segments: number; aligned: boolean } {
  const positions = loaded.batch.placements.filter((p) => p.runId === runId).map((p) => p.position);
  const words: number[] = [];
  let aligned = true;
  positions.forEach((pos, i) => {
    const leaf = loaded.batch.leaves[pos]!;
    const span = Number(leaf.tic_end - leaf.tic_start);
    if (i < positions.length - 1 && span % 7 !== 0) aligned = false;
    words.push(...unpackLog(loaded.batch.logs![pos]!.map((f) => toHex(f)), span));
  });
  return { packed: packLog(words), tics: words.length, segments: positions.length, aligned };
}

describe.runIf(RPC && ROUTER && RUNS && ACCOUNT)("devnet", () => {
  // The body is collected even when the suite is skipped: nothing here may throw offline.
  const [address, key] = (ACCOUNT ?? ":").split(":") as [string, string];
  const rpc = new RpcClient(RPC ?? "http://127.0.0.1:0/rpc");
  const loaded = loadBatch(FIXTURE);
  const levelId = loaded.levelIds["game0"] ?? 1;

  /** The run the contract's settlement rule can recompute (one segment, or 7-tic aligned). */
  const runs = [...new Set(loaded.batch.placements.map((p) => p.runId))];
  const journals = Object.fromEntries(runs.map((r) => [r, journalOf(loaded, r)]));
  const settleableRun = runs.find((r) => journals[r]!.aligned);
  const otherRun = runs.find((r) => !journals[r]!.aligned) ?? runs.find((r) => r !== settleableRun);

  const player = PLAYER ? (PLAYER.split(":") as [string, string]) : undefined;
  const playerSigner = player && RPC ? new DevnetSigner(RPC, player[0], player[1]) : undefined;

  const boundsOf = async (calls: Call[], sender: string) => {
    const est = await simulateCalls(rpc, calls, { sender });
    return withPrices(est.bounds, est.prices)[0]!.bounds;
  };
  const send = async (signer: DevnetSigner, calls: Call[]) => {
    const { transactionHash } = await signer.execute(calls, { bounds: await boundsOf(calls, signer.address) });
    return rpc.waitForReceipt(transactionHash);
  };
  const balanceOf = async (token: string, who: string): Promise<bigint> => {
    const [low, high] = await rpc.call({ contractAddress: token, entrypoint: "balance_of", calldata: [who] });
    return BigInt(low ?? "0x0") + (BigInt(high ?? "0x0") << 128n);
  };
  const view = async (entrypoint: string, calldata: string[] = []) => rpc.call({ contractAddress: RUNS!, entrypoint, calldata });

  /** What the commitment test leaves for the submission and the reclaim tests. */
  let committed: { commitmentId: string; runId: string; tics: number; l2Gas: bigint } | undefined;
  let feeToken: string | undefined;

  it("pins the fixture's version and level when the account owns a bare DoomRuns", async () => {
    if (!reachable) {
      console.warn(`skipping: nothing answers on ${RPC}`);
      return;
    }
    const [genesis] = await view("genesis_of", [toHex(loaded.versionId), toHex(levelId)]);
    if (BigInt(genesis ?? "0x0") !== 0n) return; // already pinned by a drive or an earlier run
    const [owner] = await view("owner");
    if (BigInt(owner ?? "0x0") !== BigInt(address)) return; // someone else's table: the drive pins it
    const signer = new DevnetSigner(RPC!, address, key);
    const calls = [
      addVersionCall({ doomRuns: RUNS!, versionId: loaded.versionId, batch: loaded.batch, router: ROUTER!, registryName: "doom" }),
      ...[...new Set(Object.values(loaded.levelIds))].map((l) => setGenesisCall(RUNS!, loaded.versionId, l, loaded.genesis!)),
    ];
    for (const call of calls) await send(signer, [call]);
    const [pinned] = await view("genesis_of", [toHex(loaded.versionId), toHex(levelId)]);
    expect(BigInt(pinned!)).toBe(loaded.genesis);
  }, 120_000);

  it("commits the settleable game from the player account, with a bounty in escrow (D35)", async (ctx) => {
    if (!reachable) return;
    if (!playerSigner || !settleableRun) return ctx.skip();
    const journal = journals[settleableRun]!;
    feeToken = await readFeeToken(rpc, RUNS!);
    const [expiryFelt] = await view("expiry_blocks");
    const expiry = Number(BigInt(expiryFelt!));
    expect(expiry).toBeGreaterThan(0);

    // A mintable fee token (the setup script's MockERC20) funds the bounty; STRK would not.
    try {
      await send(playerSigner, [{ contractAddress: feeToken, entrypoint: "mint", calldata: [playerSigner.address, ...u256Calldata(BOUNTY)] }]);
    } catch (e) {
      console.warn(`fee token ${feeToken} has no mint: relying on the player's balance (${(e as Error).message.slice(0, 80)})`);
    }
    expect(await balanceOf(feeToken, playerSigner.address)).toBeGreaterThanOrEqual(BOUNTY);
    const escrowBefore = await balanceOf(feeToken, RUNS!);

    const args = { versionId: loaded.versionId, levelId, packed: journal.packed, tics: journal.tics, bounty: BOUNTY, doomRuns: RUNS!, feeToken };
    const calls = buildCommitCalls(args);
    expect(calls.map((c) => c.entrypoint)).toEqual(["approve", "commit_run"]);
    const receipt = await send(playerSigner, calls);
    const l2Gas = BigInt(receipt.execution_resources?.l2_gas ?? 0);
    console.log(`commit_run: ${journal.packed.length} packed felts, ${journal.tics} tics, l2_gas ${l2Gas} (approve + commit_run multicall)`);

    // The client's view of the receipt…
    const expectedId = toHex(commitmentIdOf(loaded.versionId, levelId, playerSigner.address, commitLog(journal.packed)));
    const header = findRunCommitted(receipt.events, RUNS!);
    expect(header).toMatchObject({ commitmentId: expectedId, player: norm(playerSigner.address), versionId: loaded.versionId, levelId, tics: journal.tics, bounty: BOUNTY, nChunks: Math.ceil(journal.packed.length / 256) });
    expect(header!.inputsCommitment).toBe(toHex(commitLog(journal.packed)));

    // …the indexer's, event by event…
    const decoded = rawEvents(receipt, RUNS!).map((e) => decodeEvent(e));
    expect(decoded.map((e) => e?.kind)).toEqual(["RunCommitted", ...Array<string>(header!.nChunks).fill("RunLog")]);
    expect(decoded[0]).toMatchObject({ kind: "RunCommitted", commitmentId: expectedId, bounty: BOUNTY.toString(), genesis: toHex(loaded.genesis!), expiresAt: Number(receipt.block_number) + expiry });

    // …and the prover node's: the chunks reassemble into the committed journal.
    const nodeEvents = rawEvents(receipt, RUNS!).map((e) => decodeCommitmentEvent(e));
    const nodeHeader = nodeEvents[0] as RunCommittedEvent;
    const chunks = nodeEvents.slice(1) as RunLogEvent[];
    expect(assembleJournal(nodeHeader, chunks)).toEqual(journal.packed.map(norm));
    expect(nodeCommitmentIdOf(loaded.versionId, levelId, playerSigner.address, nodeHeader.inputsCommitment)).toBe(expectedId);

    // The view and the escrow.
    const commitment = await readCommitment(rpc, RUNS!, expectedId);
    expect(commitment).toMatchObject({ status: COMMIT_STATUS.PENDING, player: norm(playerSigner.address), tics: journal.tics, bounty: BOUNTY, prover: "0x0", runId: "0x0" });
    expect(commitment.expiresAt).toBe(commitment.createdBlock + expiry);
    expect(await balanceOf(feeToken, RUNS!)).toBe(escrowBefore + BOUNTY);
    committed = { commitmentId: expectedId, runId: settleableRun, tics: journal.tics, l2Gas };
  }, 300_000);

  it("verifies a real root proof and records its games, within C5 — and settles the commitment", async () => {
    if (!reachable) {
      console.warn(`skipping: nothing answers on ${RPC}`);
      return;
    }
    // A proof id nobody used yet: the router's slots are per (caller, proof_id) and write-once.
    const proofId = BigInt(Date.now()) % 1_000_000n;
    // The committed game is recorded for the player who committed it; the others for the submitter.
    const players = Object.fromEntries(
      loaded.batch.placements.map((p) => [p.runId, committed && p.runId === committed.runId ? playerSigner!.address : address]),
    );
    const prepared = prepareSubmission({
      batch: loaded.batch,
      router: ROUTER!,
      doomRuns: RUNS!,
      versionId: loaded.versionId,
      proofId,
      players,
      levelIds: loaded.levelIds,
      replay: true,
    });
    expect(prepared.phases).toHaveLength(5);

    const resume = await resumePoint(rpc, prepared.sequence, address);
    expect(resume.nextPhase).toBe(0);

    const est = await simulateSequence(rpc, prepared.sequence, { sender: address });
    const bounds = withPrices(est.bounds, est.prices);
    for (const b of bounds) expect(b.overCap).toBe(false);

    const priced = priceEstimate(est, await new StaticPriceSource(S5_SNAPSHOT).quote());
    expect(priced.totalStrk).toBeGreaterThan(0);
    expect(priced.totalUsd).toBeGreaterThan(0);

    const proverBefore = feeToken ? await balanceOf(feeToken, address) : 0n;
    const result = await runSequence(rpc, prepared.sequence, {
      signer: new DevnetSigner(RPC!, address, key),
      bounds: bounds.map((b) => b.bounds),
    });
    expect(result.fact).toBe(EXPECTED_FACT);

    const accepted = result.steps.filter((s) => s.state === "accepted");
    expect(accepted).toHaveLength(6);
    for (const step of accepted) {
      const e = est.steps.find((s) => s.label === step.label)!;
      const gap = Math.abs(Number(e.estimate.l2GasConsumed - step.l2Gas!)) / Number(step.l2Gas!);
      expect(gap).toBeLessThan(0.2); // C5
    }
    const actual = accepted.reduce((a, s) => a + s.l2Gas!, 0n);
    expect(Math.abs(Number(est.totalL2Gas - actual)) / Number(actual)).toBeLessThan(0.002);

    // Re-running the same proof id must cost nothing: everything is already on chain.
    const again = await resumePoint(rpc, prepared.sequence, address);
    expect(again.factRegistered).toBe(true);
    expect(again.nextPhase).toBe(prepared.phases.length);

    // D35: the consumer transaction, sent by this account, settled the player's commitment and
    // paid the bounty to the caller — read with the indexer's decoder and the node's.
    if (!committed) return;
    const consumer = accepted[accepted.length - 1]!;
    const receipt = await rpc.receipt(consumer.transactionHash!);
    const events = rawEvents(receipt, RUNS!).map((e) => decodeEvent(e)!);
    const submitted = events.find((e) => e.kind === "RunSubmitted" && e.player === norm(playerSigner!.address));
    expect(submitted, "the committed game was recorded for its player").toBeDefined();
    const proved = events.find((e) => e.kind === "CommitmentProved");
    expect(proved).toMatchObject({ commitmentId: committed.commitmentId, runId: (submitted as { runId: string }).runId, prover: norm(address), player: norm(playerSigner!.address), bounty: BOUNTY.toString() });
    expect(events.indexOf(submitted!)).toBeLessThan(events.indexOf(proved!));
    expect(settlementIn(receipt.events, committed.commitmentId)).toMatchObject({ prover: norm(address), bounty: BOUNTY });

    const commitment = await readCommitment(rpc, RUNS!, committed.commitmentId);
    expect(commitment).toMatchObject({ status: COMMIT_STATUS.PROVED, runId: (submitted as { runId: string }).runId, prover: norm(address), tics: committed.tics });
    expect(await balanceOf(feeToken!, address)).toBe(proverBefore + BOUNTY);
    expect(await balanceOf(feeToken!, RUNS!)).toBe(0n);
  }, 600_000);

  it("a second commitment nothing settles is refused before expiry and reclaimed after it", async (ctx) => {
    if (!reachable) return;
    if (!playerSigner || !otherRun || !feeToken) return ctx.skip();
    // The other game's journal: its run is already recorded (and its first segment is not
    // 7-tic aligned), so no submission can settle this commitment — it can only expire.
    const journal = journals[otherRun]!;
    expect(journal.packed.length).toBe(Math.ceil(journal.tics / 7));
    try {
      await send(playerSigner, [{ contractAddress: feeToken, entrypoint: "mint", calldata: [playerSigner.address, ...u256Calldata(BOUNTY)] }]);
    } catch {
      /* not mintable: the player's balance must do */
    }
    const playerBefore = await balanceOf(feeToken, playerSigner.address);
    const receipt = await send(playerSigner, buildCommitCalls({ versionId: loaded.versionId, levelId, packed: journal.packed, tics: journal.tics, bounty: BOUNTY, doomRuns: RUNS!, feeToken }));
    const header = findRunCommitted(receipt.events, RUNS!)!;
    console.log(`commit_run(2): ${journal.packed.length} packed felts, ${journal.tics} tics, l2_gas ${receipt.execution_resources?.l2_gas}`);
    expect(await balanceOf(feeToken, playerSigner.address)).toBe(playerBefore - BOUNTY);
    let commitment = await readCommitment(rpc, RUNS!, header.commitmentId);
    expect(commitment.status).toBe(COMMIT_STATUS.PENDING);

    // Before expiry the contract refuses: the transaction is REVERTED ('doomruns: not expired').
    // (A simulation would not do: the RPC answers a reverted trace, not an error.)
    const reclaim = reclaimCall(RUNS!, header.commitmentId);
    const head = Number(await rpc.request<number | string>("starknet_blockNumber", []));
    expect(head).toBeLessThan(commitment.expiresAt);
    const early = await playerSigner.execute([reclaim], { bounds: await boundsOf([reclaim], playerSigner.address) });
    await expect(rpc.waitForReceipt(early.transactionHash)).rejects.toThrow(/REVERTED/);
    expect((await readCommitment(rpc, RUNS!, header.commitmentId)).status).toBe(COMMIT_STATUS.PENDING);

    // Empty blocks up to `expires_at` (devnet only), then the refund.
    const toMine = commitment.expiresAt - Number(await rpc.request<number | string>("starknet_blockNumber", []));
    if (toMine > MAX_MINED_BLOCKS) {
      console.warn(`expiry is ${toMine} blocks away: not mining that many, reclaim not exercised`);
      return;
    }
    for (let i = 0; i < toMine; i++) await rpc.request("devnet_createBlock", {});
    const reclaimed = await send(playerSigner, [reclaim]);
    const events = rawEvents(reclaimed, RUNS!).map((e) => decodeEvent(e));
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ kind: "CommitmentReclaimed", commitmentId: header.commitmentId, player: norm(playerSigner.address), bounty: BOUNTY.toString() });
    expect(decodeCommitmentEvent(rawEvents(reclaimed, RUNS!)[0]!)).toMatchObject({ kind: "CommitmentReclaimed", bounty: BOUNTY });
    commitment = await readCommitment(rpc, RUNS!, header.commitmentId);
    expect(commitment.status).toBe(COMMIT_STATUS.RECLAIMED);
    expect(await balanceOf(feeToken, playerSigner.address)).toBe(playerBefore);
    expect(await balanceOf(feeToken, RUNS!)).toBe(0n);
    console.log(`reclaim after ${toMine} empty blocks: l2_gas ${reclaimed.execution_resources?.l2_gas}`);
  }, 300_000);
});

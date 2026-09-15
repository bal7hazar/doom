// SPDX-License-Identifier: Apache-2.0
/** Decoding a fabricated `RunCommitted`, its integrity checks, discovery and the policy. */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import {
  checkCommitment,
  claimCall,
  decodeCommitmentEvent,
  wrapperRunId,
} from "../src/commitments.js";
import { discoverOnce, emptyDiscoveryState, FileDiscoveryStore } from "../src/discovery.js";
import { reconstructJournal, segmentLog } from "../src/journal.js";
import { DEFAULT_POLICY, selectCommitments } from "../src/policy.js";
import {
  fakeCommitment,
  FakeEventSource,
  fixtureGenesis,
  fixtureJournal,
  fixtureLeaf,
  runCommittedEvent,
  settledEvent,
} from "./fixtures.js";

const words = fixtureJournal(0);

describe("RunCommitted decoding", () => {
  it("round-trips a fabricated event and verifies its commitment", () => {
    const c = fakeCommitment(words);
    const decoded = decodeCommitmentEvent(runCommittedEvent(c));
    expect(decoded?.kind).toBe("RunCommitted");
    if (decoded?.kind !== "RunCommitted") throw new Error("unreachable");
    const { kind: _k, ...fields } = decoded;
    expect(fields).toEqual(c);
    expect(checkCommitment(decoded, { genesis: fixtureGenesis() })).toEqual([]);
    const journal = reconstructJournal(decoded, { genesis: fixtureGenesis() });
    expect(journal.words).toEqual(words);
    expect(journal.inputsCommitment).toBe(BigInt(c.inputsCommitment));
  });

  it("decodes a settlement and ignores the other DoomRuns events", () => {
    const s = decodeCommitmentEvent(settledEvent({ commitmentId: "0xc1", runId: "0x77", outcome: 0, block: 5 }));
    expect(s).toMatchObject({ kind: "CommitmentSettled", commitmentId: "0xc1", runId: "0x77", outcome: "proved" });
    const other = runCommittedEvent(fakeCommitment(words));
    other.keys[0] = "0x1234";
    expect(decodeCommitmentEvent(other)).toBeUndefined();
  });

  it("refuses a tampered journal, a wrong length and a wrong genesis", () => {
    const c = fakeCommitment(words);
    const tampered = { ...c, journal: [...c.journal] };
    tampered.journal[3] = "0x" + (BigInt(tampered.journal[3]!) ^ 1n).toString(16);
    expect(checkCommitment(tampered)[0]).toMatch(/differs from inputs_commitment/);
    expect(checkCommitment({ ...c, tics: c.tics - 7 })[0]).toMatch(/packed_len/);
    expect(checkCommitment({ ...c, tics: c.tics + 7 })[0]).toMatch(/packed_len/);
    // 296 tics pack into the same 43 felts as 297: only the lane check can catch it.
    expect(checkCommitment({ ...c, tics: c.tics - 1 })[0]).toMatch(/lane/);
    expect(checkCommitment(c, { genesis: "0x1" })[0]).toMatch(/not the pinned/);
    expect(() => reconstructJournal(tampered)).toThrow(/refused/);
    // The last felt may not carry lanes beyond the tic count.
    const overfull = { ...c, journal: [...c.journal] };
    overfull.journal[overfull.journal.length - 1] = "0x" + ((1n << 224n) - 1n).toString(16);
    expect(checkCommitment(overfull).some((p) => /lane/.test(p))).toBe(true);
    // A malformed raw event (declared journal length off by one) is rejected at decode time.
    const raw = runCommittedEvent(c);
    raw.data[6] = "0x" + (c.journal.length + 1).toString(16);
    expect(() => decodeCommitmentEvent(raw)).toThrow(/journal length/);
  });

  it("re-packs a segment's own slice to the commitment the proof carries", () => {
    const leaf1 = fixtureLeaf(0, 1);
    expect(segmentLog(words, 160, 297)).toEqual({ packed: leaf1.packed.map(BigInt), commitment: leaf1.inputsCommitment });
    expect(() => segmentLog(words, 100, 300)).toThrow(/outside/);
  });

  it("derives a wrapper run id and the claim call", () => {
    const id = wrapperRunId("0x" + "f".repeat(63));
    expect(id).toMatch(/^[A-Za-z0-9_-]{1,64}$/);
    expect(claimCall("0xd00d", "0x0c1")).toEqual({
      contractAddress: "0xd00d",
      entrypoint: "claim_bounty",
      calldata: ["0xc1"],
    });
  });
});

describe("discovery", () => {
  const dirs: string[] = [];
  afterEach(() => dirs.splice(0).forEach((d) => rmSync(d, { recursive: true })));

  it("lists open commitments, drops settled ones, pages and re-scans the reorg window", async () => {
    const a = fakeCommitment(words, { blockNumber: 3 });
    const b = fakeCommitment(words.slice(0, 50), { blockNumber: 8 });
    const c = fakeCommitment(words.slice(0, 20), { blockNumber: 23 });
    const source = new FakeEventSource(
      [
        runCommittedEvent(a),
        runCommittedEvent(b),
        settledEvent({ commitmentId: b.commitmentId, block: 12 }),
        runCommittedEvent(c),
      ],
      25,
      2,
    );
    const state = emptyDiscoveryState();
    const first = await discoverOnce(source, state, { address: "0xd00d", startBlock: 0, reorgDepth: 5 });
    expect(first).toMatchObject({ fromBlock: 0, head: 25, seen: 4 });
    expect(first.open.map((x) => x.commitmentId)).toEqual([a.commitmentId, c.commitmentId]);
    expect(source.calls).toHaveLength(2);

    // Next poll re-scans only the last five blocks; `c` (block 23) vanished in a reorg.
    source.head = 26;
    source.events = source.events.filter((e) => e.block_number !== 23);
    const second = await discoverOnce(source, state, { address: "0xd00d", startBlock: 0, reorgDepth: 5 });
    expect(second.fromBlock).toBe(21);
    expect(second.open.map((x) => x.commitmentId)).toEqual([a.commitmentId]);
    expect(state.settled[b.commitmentId]).toBeDefined();

    const dir = mkdtempSync(join(tmpdir(), "prover-node-discovery-"));
    dirs.push(dir);
    const store = new FileDiscoveryStore(join(dir, "discovery.json"));
    store.save(state);
    const reloaded = store.load();
    expect(reloaded.lastBlock).toBe(26);
    expect(reloaded.committed[a.commitmentId]!.bounty).toBe(a.bounty);
  });
});

describe("selection policy", () => {
  it("filters on bounty, version, length and players, then orders by bounty per tic", () => {
    const cheap = fakeCommitment(words, { bounty: 1n, blockNumber: 1 });
    const other = fakeCommitment(words, { versionId: 7, bounty: 10n ** 20n, blockNumber: 2 });
    const long = fakeCommitment(words, { tics: 297, bounty: 10n ** 20n, blockNumber: 3 });
    const denied = fakeCommitment(words.slice(0, 50), { player: "0x0bad", bounty: 10n ** 20n, blockNumber: 4 });
    const good = fakeCommitment(words, { bounty: 10n ** 19n, blockNumber: 5 });
    const better = fakeCommitment(words.slice(0, 100), { bounty: 10n ** 19n, blockNumber: 6 });
    const done = fakeCommitment(words, { bounty: 10n ** 21n, blockNumber: 7 });
    const sel = selectCommitments([cheap, other, long, denied, good, better, done], {
      ...DEFAULT_POLICY,
      minBounty: 10n ** 18n,
      versions: [1],
      maxTics: 200,
      denyPlayers: ["0xbad"],
    }, { done: new Set([done.commitmentId]), inFlight: new Set() });
    expect(sel.selected.map((c) => c.commitmentId)).toEqual([better.commitmentId]);
    expect(Object.fromEntries(sel.skipped.map((s) => [s.commitmentId, s.reason]))).toMatchObject({
      [cheap.commitmentId]: expect.stringMatching(/below/),
      [other.commitmentId]: expect.stringMatching(/version 7/),
      [long.commitmentId]: expect.stringMatching(/over the 200/),
      [denied.commitmentId]: "player denied",
      [good.commitmentId]: expect.stringMatching(/over the 200/),
      [done.commitmentId]: "already handled",
    });
  });

  it("bounds the queue by what is already in flight and keeps the order stable", () => {
    const a = fakeCommitment(words.slice(0, 10), { bounty: 100n, blockNumber: 1 });
    const b = fakeCommitment(words.slice(0, 10), { bounty: 100n, blockNumber: 2 });
    const c = fakeCommitment(words.slice(0, 10), { bounty: 300n, blockNumber: 3 });
    const sel = selectCommitments([a, b, c], { ...DEFAULT_POLICY, maxQueue: 2 }, {
      done: new Set(),
      inFlight: new Set(["0xother"]),
    });
    expect(sel.selected.map((x) => x.commitmentId)).toEqual([c.commitmentId]);
    expect(sel.skipped.map((s) => s.reason)).toEqual(["queue full (waiting)", "queue full (waiting)"]);
    expect(selectCommitments([a, b, c], { ...DEFAULT_POLICY, allowPlayers: ["0x0"] }, { done: new Set(), inFlight: new Set() }).selected).toEqual([]);
  });
});

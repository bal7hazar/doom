// SPDX-License-Identifier: Apache-2.0
/** Decoding a fabricated `RunCommitted`, its integrity checks, discovery and the policy. */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { hash } from "starknet";

import { camel, entrypointOutputs, eventLayout, loadDoomRunsAbi, shortName, structLayout, synthesize, u256Of } from "../../indexer/test/abi.js";
import {
  assembleJournal,
  checkCommitment,
  COMMITMENT_EVENT_NAMES,
  COMMITMENT_SELECTORS,
  commitmentIdOf,
  decodeCommitmentEvent,
  decodeCommitmentView,
  settlementIn,
  wrapperRunId,
  type RunCommittedEvent,
  type RunLogEvent,
} from "../src/commitments.js";
import { discoverOnce, emptyDiscoveryState, FileDiscoveryStore } from "../src/discovery.js";
import { reconstructJournal, segmentLog } from "../src/journal.js";
import { DEFAULT_POLICY, selectCommitments } from "../src/policy.js";
import {
  CHUNK,
  commitmentEvents,
  fakeCommitment,
  FakeEventSource,
  fixtureGenesis,
  fixtureJournal,
  fixtureLeaf,
  provedEvent,
  reclaimedEvent,
  runCommittedEvent,
  runLogEvents,
} from "./fixtures.js";

const words = fixtureJournal(0);

describe("RunCommitted decoding", () => {
  it("pins the selectors the contract wave announced", () => {
    expect(COMMITMENT_SELECTORS["0x1099626e2b9a923474254b7263af666f7c1a048447bb0a1e4dc8b8d0419e33c"]).toBe("RunCommitted");
    expect(COMMITMENT_SELECTORS["0x2d88b9fb81ec1e6da1d03071766806fc8fa19acced5d8e3c6d2d603a6b9d251"]).toBe("RunLog");
  });

  it("decodes a fabricated header and its chunks, assembles the journal and verifies it", () => {
    const c = fakeCommitment(words);
    expect(c.nChunks).toBe(Math.ceil(43 / CHUNK));
    const header = decodeCommitmentEvent(runCommittedEvent(c)) as RunCommittedEvent;
    expect(header.kind).toBe("RunCommitted");
    const { kind: _k, ...fields } = header;
    const { journal: _j, ...expected } = c;
    expect(fields).toEqual(expected);
    const chunks = runLogEvents(c).map((e) => decodeCommitmentEvent(e) as RunLogEvent);
    expect(chunks.map((ch) => [ch.chunk, ch.offset, ch.packed.length])).toEqual([[0, 0, 16], [1, 16, 16], [2, 32, 11]]);
    // Chunks arrive in any order; the journal is the concatenation in chunk order.
    const journal = assembleJournal(header, [...chunks].reverse());
    expect(journal).toEqual(c.journal);
    const assembled = { ...fields, journal: journal! };
    expect(checkCommitment(assembled, { genesis: fixtureGenesis(), head: 999 })).toEqual([]);
    const rec = reconstructJournal(assembled, { genesis: fixtureGenesis() });
    expect(rec.words).toEqual(words);
    expect(rec.inputsCommitment).toBe(BigInt(c.inputsCommitment));
    expect(c.commitmentId).toBe(commitmentIdOf(1, 1, "0x1a7e5", c.inputsCommitment));
  });

  it("waits for missing chunks and refuses inconsistent ones", () => {
    const c = fakeCommitment(words);
    const header = decodeCommitmentEvent(runCommittedEvent(c)) as RunCommittedEvent;
    const chunks = runLogEvents(c).map((e) => decodeCommitmentEvent(e) as RunLogEvent);
    expect(assembleJournal(header, chunks.slice(0, 2))).toBeNull();
    expect(assembleJournal(header, [chunks[0]!, chunks[2]!])).toBeNull();
    const shifted = { ...chunks[1]!, offset: 15 };
    expect(() => assembleJournal(header, [chunks[0]!, shifted, chunks[2]!])).toThrow(/chunk 1 starts at 15, expected 16/);
    const short = { ...chunks[2]!, packed: chunks[2]!.packed.slice(1) };
    expect(() => assembleJournal(header, [chunks[0]!, chunks[1]!, short])).toThrow(/42 felts over 3 chunk\(s\), packed_len\(297\) = 43/);
    const twice = { ...chunks[1]!, packed: [...chunks[1]!.packed].reverse() };
    expect(() => assembleJournal(header, [...chunks, twice])).toThrow(/emitted twice/);
    // A raw chunk whose declared length is off is rejected at decode time.
    const raw = runLogEvents(c)[0]!;
    raw.data[2] = "0x11";
    expect(() => decodeCommitmentEvent(raw)).toThrow(/packed length/);
  });

  it("decodes settlements and the Commitment view, and ignores the other DoomRuns events", () => {
    const proved = decodeCommitmentEvent(provedEvent({ commitmentId: "0xc1", prover: "0x9", runId: "0x77", block: 5 }));
    expect(proved).toMatchObject({ kind: "CommitmentProved", commitmentId: "0xc1", runId: "0x77", prover: "0x9", player: "0x1a7e5", bounty: 5_000_000_000_000_000_000n });
    expect(decodeCommitmentEvent(reclaimedEvent({ commitmentId: "0xc1", block: 6 }))).toMatchObject({ kind: "CommitmentReclaimed", player: "0x1a7e5" });
    const other = runCommittedEvent(fakeCommitment(words));
    other.keys[0] = "0x1234";
    expect(decodeCommitmentEvent(other)).toBeUndefined();
    const view = decodeCommitmentView(["0x1a7e5", "0x1", "0x1", "0x3", "0x4", "0x129", "0x64", "0x0", "0x5", "0x3e8", "0x2", "0x77", "0x9"]);
    expect(view).toMatchObject({ player: "0x1a7e5", tics: 297, bounty: 100n, expiresAt: 1000, status: 2, runId: "0x77", prover: "0x9" });
    expect(settlementIn(provedEvent({ commitmentId: "0xc1", prover: "0x9", block: 1 }) && [{ keys: provedEvent({ commitmentId: "0xc1", prover: "0x9", block: 1 }).keys, data: provedEvent({ commitmentId: "0xc1", prover: "0x9", block: 1 }).data }], "0x0c1"))
      .toMatchObject({ prover: "0x9" });
    expect(settlementIn([{ keys: ["0x1", "0x2"], data: [] }], "0xc1")).toBeNull();
  });

  it("refuses a tampered journal, a wrong length, a wrong id, a wrong genesis and an expiry", () => {
    const c = fakeCommitment(words);
    const tampered = { ...c, journal: [...c.journal] };
    tampered.journal[3] = "0x" + (BigInt(tampered.journal[3]!) ^ 1n).toString(16);
    expect(checkCommitment(tampered)[0]).toMatch(/differs from inputs_commitment/);
    expect(checkCommitment({ ...c, tics: c.tics - 7 })[0]).toMatch(/packed_len/);
    expect(checkCommitment({ ...c, tics: c.tics + 7 })[0]).toMatch(/packed_len/);
    // 296 tics pack into the same 43 felts as 297: only the lane check can catch it.
    expect(checkCommitment({ ...c, tics: c.tics - 1 })[0]).toMatch(/lane/);
    expect(checkCommitment({ ...c, commitmentId: "0x1" })[0]).toMatch(/not poseidon\('HP.COMMIT'/);
    expect(checkCommitment(c, { genesis: "0x1" })[0]).toMatch(/not the pinned/);
    expect(checkCommitment(c, { head: 1000 })[0]).toMatch(/expired at block 1000/);
    expect(checkCommitment({ ...c, expiresAt: 0 }, { head: 10_000 })).toEqual([]);
    expect(() => reconstructJournal(tampered)).toThrow(/refused/);
    const overfull = { ...c, journal: [...c.journal] };
    overfull.journal[overfull.journal.length - 1] = "0x" + ((1n << 224n) - 1n).toString(16);
    expect(checkCommitment(overfull).some((p) => /lane/.test(p))).toBe(true);
  });

  it("re-packs a segment's own slice to the commitment the proof carries", () => {
    const leaf1 = fixtureLeaf(0, 1);
    expect(segmentLog(words, 160, 297)).toEqual({ packed: leaf1.packed.map(BigInt), commitment: leaf1.inputsCommitment });
    expect(() => segmentLog(words, 100, 300)).toThrow(/outside/);
  });

  it("derives a wrapper run id", () => {
    const id = wrapperRunId("0x" + "f".repeat(63));
    expect(id).toMatch(/^[A-Za-z0-9_-]{1,64}$/);
  });
});

describe("discovery", () => {
  const dirs: string[] = [];
  afterEach(() => dirs.splice(0).forEach((d) => rmSync(d, { recursive: true })));

  it("lists open commitments, drops settled ones, pages and re-scans the reorg window", async () => {
    const a = fakeCommitment(words, { blockNumber: 3 });
    const b = fakeCommitment(words.slice(0, 50), { blockNumber: 8 });
    const c = fakeCommitment(words.slice(0, 20), { blockNumber: 23 });
    const d = fakeCommitment(words.slice(0, 30), { blockNumber: 9, expiresAt: 20 });
    const partial = fakeCommitment(words.slice(0, 40), { blockNumber: 15 });
    const source = new FakeEventSource(
      [
        ...commitmentEvents(a),
        ...commitmentEvents(b),
        provedEvent({ commitmentId: b.commitmentId, prover: "0x9", block: 12 }),
        ...commitmentEvents(d),
        runCommittedEvent(partial), // its RunLog chunks never show up
        ...commitmentEvents(c),
      ],
      25,
      2,
    );
    const state = emptyDiscoveryState();
    const first = await discoverOnce(source, state, { address: "0xd00d", startBlock: 0, reorgDepth: 5 });
    expect(first).toMatchObject({ fromBlock: 0, head: 25, seen: source.events.length });
    expect(first.open.map((x) => x.commitmentId)).toEqual([a.commitmentId, c.commitmentId]);
    expect(first.open[0]!.journal).toEqual(a.journal);
    expect(first.incomplete).toEqual([{ commitmentId: partial.commitmentId, reason: "0 of 1 journal chunk(s) seen" }]);
    expect(source.calls.length).toBeGreaterThan(3);

    // Next poll re-scans only the last five blocks; `c` (block 23) vanished in a reorg.
    source.head = 26;
    source.events = source.events.filter((e) => e.block_number !== 23);
    const second = await discoverOnce(source, state, { address: "0xd00d", startBlock: 0, reorgDepth: 5 });
    expect(second.fromBlock).toBe(21);
    expect(second.open.map((x) => x.commitmentId)).toEqual([a.commitmentId]);
    expect(state.settled[b.commitmentId]?.kind).toBe("CommitmentProved");
    // A reclaim closes a commitment too.
    source.events.push(reclaimedEvent({ commitmentId: a.commitmentId, block: 26 }));
    expect((await discoverOnce(source, state, { address: "0xd00d", startBlock: 0, reorgDepth: 5 })).open).toEqual([]);

    const dir = mkdtempSync(join(tmpdir(), "prover-node-discovery-"));
    dirs.push(dir);
    const store = new FileDiscoveryStore(join(dir, "discovery.json"));
    store.save(state);
    const reloaded = store.load();
    expect(reloaded.lastBlock).toBe(26);
    expect(reloaded.headers[a.commitmentId]!.bounty).toBe(a.bounty);
    expect(reloaded.settled[b.commitmentId]!.bounty).toBe(5_000_000_000_000_000_000n);
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

// -- against the compiled ABI (`scarb build -p doom_runs`; skipped until it exists) ------------

describe("the compiled DoomRuns ABI", () => {
  const abi = loadDoomRunsAbi();
  const norm = (v: string): string => "0x" + BigInt(v).toString(16);

  it.skipIf(!abi)("serialises the four commitment events exactly as decodeCommitmentEvent reads them", () => {
    for (const name of COMMITMENT_EVENT_NAMES) {
      const layout = eventLayout(abi!, name);
      const keys = synthesize(layout.keys, 0x1000);
      const data = synthesize(layout.data, 0x2000, 3);
      const decoded = decodeCommitmentEvent({
        from_address: "0x1",
        keys: [hash.getSelectorFromName(name), ...keys.felts],
        data: data.felts,
        block_number: 7,
        block_hash: "0xb",
        transaction_hash: "0xt",
      }) as Record<string, unknown> | undefined;
      expect(decoded?.["kind"], name).toBe(name);
      for (const [fields, values] of [
        [layout.keys, keys.values],
        [layout.data, data.values],
      ] as const) {
        for (const f of fields) {
          const got = values.get(f.name)!;
          const where = `${name}.${f.name} (${f.type})`;
          if (f.felts === -1) expect(decoded![camel(f.name)], where).toEqual(got.map(norm));
          else if (f.type === "core::integer::u256") expect(decoded![camel(f.name)], where).toBe(u256Of(got));
          else if (/^core::integer::u(8|16|32|64)$/.test(f.type)) expect(decoded![camel(f.name)], where).toBe(Number(BigInt(got[0]!)));
          else expect(decoded![camel(f.name)], where).toBe(norm(got[0]!));
        }
      }
    }
  });

  it.skipIf(!abi)("returns Commitment from get_commitment as the 13 felts decodeCommitmentView expects", () => {
    expect(entrypointOutputs(abi!, "get_commitment").map(shortName)).toEqual(["Commitment"]);
    expect(entrypointOutputs(abi!, "commitment_of").map(shortName)).toEqual(["Commitment"]);
    const layout = structLayout(abi!, "Commitment");
    expect(layout.reduce((n, f) => n + f.felts, 0)).toBe(13);
    const { felts, values } = synthesize(layout, 0x3000);
    const view = decodeCommitmentView(felts) as unknown as Record<string, unknown>;
    for (const f of layout) {
      const got = values.get(f.name)!;
      if (f.type === "core::integer::u256") expect(view[camel(f.name)], f.name).toBe(u256Of(got));
      else if (/^core::integer::u(8|16|32|64)$/.test(f.type)) expect(view[camel(f.name)], f.name).toBe(Number(BigInt(got[0]!)));
      else expect(view[camel(f.name)], f.name).toBe(norm(got[0]!));
    }
  });
});

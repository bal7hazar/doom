// SPDX-License-Identifier: Apache-2.0
/**
 * Test fixtures: a real journal, a fabricated commitment event around it, and an in-memory
 * `EventSource`. Nothing here touches a network.
 *
 * The journal is game 0 of the proved `B2-1_doom` fixture (two leaves, 160 + 137 tics, `EXIT`):
 * its packed logs are the ones the contract checked against the Cairo program's own
 * `inputs_commitment`, so a node that reproduces those commitments from the same words is
 * reproducing what the proof consumed.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { hash } from "starknet";

import { packLog, unpackLog } from "../../../client/src/prove/ticcmd.js";
import type { EventSource, RawEvent } from "../../indexer/src/types.js";
import { commitWords } from "../src/commitment.js";
import { commitmentIdOf, type RunCommitment } from "../src/commitments.js";

export const FIXTURE_DIR = join(
  import.meta.dirname,
  "../../../cairo/doom_contracts/crates/recursion_outputs/fixtures/B2-1_doom",
);

interface FixturePlan {
  version_id: number;
  level_id: number;
  genesis: string;
  members: { game: number; level_id: number; leaf_start: number; leaf_len: number }[];
  leaves: { game: number; segment: number; packed: string[]; output: string[] }[];
}

export function fixturePlan(): FixturePlan {
  return JSON.parse(readFileSync(join(FIXTURE_DIR, "batch.json"), "utf8")) as FixturePlan;
}

/** One leaf of the fixture: its words, tic span and the commitment the proof carries. */
export function fixtureLeaf(game: number, segment: number) {
  const leaf = fixturePlan().leaves.find((l) => l.game === game && l.segment === segment);
  if (!leaf) throw new Error(`no leaf for game ${game} segment ${segment}`);
  const ticStart = Number(leaf.output[3]);
  const ticEnd = Number(leaf.output[4]);
  return {
    packed: leaf.packed.map((p) => "0x" + BigInt(p).toString(16)),
    ticStart,
    ticEnd,
    words: unpackLog(leaf.packed.map((p) => "0x" + BigInt(p).toString(16)), ticEnd - ticStart),
    inputsCommitment: BigInt(leaf.output[6]!),
    status: Number(leaf.output[5]),
    hIn: "0x" + BigInt(leaf.output[1]!).toString(16),
    hOut: "0x" + BigInt(leaf.output[2]!).toString(16),
    kills: Number(leaf.output[7]),
    items: Number(leaf.output[8]),
    secrets: Number(leaf.output[9]),
  };
}

/** The whole journal of one game of the fixture, as words. */
export function fixtureJournal(game = 0): number[] {
  const leaves = fixturePlan().leaves.filter((l) => l.game === game).sort((a, b) => a.segment - b.segment);
  return leaves.flatMap((l) => fixtureLeaf(game, l.segment).words);
}

export function fixtureGenesis(): string {
  return "0x" + BigInt(fixturePlan().genesis).toString(16);
}

let counter = 0;

/** Chunk size the fixtures emit `RunLog` with; the contract's ceiling is 256. */
export const CHUNK = 16;

/** A commitment around a journal, as the contract derives it (values, not the raw events). */
export function fakeCommitment(
  words: readonly number[],
  overrides: Partial<RunCommitment> = {},
): RunCommitment {
  counter++;
  const journal = packLog(words);
  const base = {
    player: "0x1a7e5",
    versionId: 1,
    levelId: 1,
    inputsCommitment: "0x" + commitWords(words).toString(16),
    ...overrides,
  };
  return {
    commitmentId: commitmentIdOf(base.versionId, base.levelId, base.player, base.inputsCommitment),
    genesis: fixtureGenesis(),
    tics: words.length,
    bounty: 5_000_000_000_000_000_000n,
    expiresAt: 1000,
    nChunks: Math.max(1, Math.ceil(journal.length / CHUNK)),
    journal,
    blockNumber: 10 + counter,
    txHash: "0x7c" + counter.toString(16),
    ...overrides,
    ...base,
  };
}

const hex = (v: bigint | number): string => "0x" + BigInt(v).toString(16);
const block = (n: number) => ({ block_number: n, block_hash: "0xb" + n.toString(16) });

/** The raw `RunCommitted` header of a commitment (no journal: that travels in `runLogEvents`). */
export function runCommittedEvent(c: RunCommitment, from = "0xd00d"): RawEvent {
  return {
    from_address: from,
    keys: [hash.getSelectorFromName("RunCommitted"), c.commitmentId, c.player, hex(c.versionId)],
    data: [
      hex(c.levelId), c.genesis, c.inputsCommitment, hex(c.tics),
      hex(c.bounty & ((1n << 128n) - 1n)), hex(c.bounty >> 128n), hex(c.expiresAt), hex(c.nChunks),
    ],
    ...block(c.blockNumber),
    transaction_hash: c.txHash,
  };
}

/** The `RunLog` chunks of a commitment's journal, `chunk` felts each, in the same transaction. */
export function runLogEvents(c: RunCommitment, chunk = CHUNK): RawEvent[] {
  const events: RawEvent[] = [];
  for (let i = 0, offset = 0; i < c.nChunks; i++, offset += chunk) {
    const packed = c.journal.slice(offset, offset + chunk);
    events.push({
      from_address: "0xd00d",
      keys: [hash.getSelectorFromName("RunLog"), c.commitmentId],
      data: [hex(i), hex(offset), hex(packed.length), ...packed],
      ...block(c.blockNumber),
      transaction_hash: c.txHash,
    });
  }
  return events;
}

/** Header then chunks — the order the transaction emits them. */
export function commitmentEvents(c: RunCommitment): RawEvent[] {
  return [runCommittedEvent(c), ...runLogEvents(c)];
}

export function provedEvent(args: { commitmentId: string; prover: string; runId?: string; player?: string; bounty?: bigint; block: number }): RawEvent {
  const bounty = args.bounty ?? 5_000_000_000_000_000_000n;
  return {
    from_address: "0xd00d",
    keys: [hash.getSelectorFromName("CommitmentProved"), args.commitmentId, args.runId ?? "0x7777", args.prover],
    data: [args.player ?? "0x1a7e5", hex(bounty & ((1n << 128n) - 1n)), hex(bounty >> 128n)],
    ...block(args.block),
    transaction_hash: "0x5e" + args.block.toString(16),
  };
}

export function reclaimedEvent(args: { commitmentId: string; player?: string; block: number }): RawEvent {
  return {
    from_address: "0xd00d",
    keys: [hash.getSelectorFromName("CommitmentReclaimed"), args.commitmentId, args.player ?? "0x1a7e5"],
    data: [hex(5_000_000_000_000_000_000n), "0x0"],
    ...block(args.block),
    transaction_hash: "0x5f" + args.block.toString(16),
  };
}

/** A fixed, in-memory `EventSource` (the indexer's test double, copied so tests need no
 * second `node_modules`). */
export class FakeEventSource implements EventSource {
  calls: { fromBlock: number; toBlock: number }[] = [];
  constructor(
    public events: RawEvent[],
    public head: number,
    public pageSize = 100,
  ) {}

  async blockNumber(): Promise<number> {
    return this.head;
  }

  async getEvents(args: {
    fromBlock: number;
    toBlock: number;
    continuationToken?: string;
  }): Promise<{ events: RawEvent[]; continuationToken?: string }> {
    this.calls.push({ fromBlock: args.fromBlock, toBlock: args.toBlock });
    const inRange = this.events.filter((e) => e.block_number >= args.fromBlock && e.block_number <= args.toBlock);
    const start = args.continuationToken ? Number(args.continuationToken) : 0;
    const next = start + this.pageSize;
    return {
      events: inRange.slice(start, next),
      ...(next < inRange.length ? { continuationToken: String(next) } : {}),
    };
  }
}

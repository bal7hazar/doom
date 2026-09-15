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
import type { RunCommitment } from "../src/commitments.js";

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

/** A commitment around a journal, as the contract would emit it (values, not the raw event). */
export function fakeCommitment(
  words: readonly number[],
  overrides: Partial<RunCommitment> = {},
): RunCommitment {
  counter++;
  return {
    commitmentId: "0x" + (0xc0ffee00 + counter).toString(16),
    player: "0x1a7e5",
    versionId: 1,
    levelId: 1,
    genesis: fixtureGenesis(),
    inputsCommitment: "0x" + commitWords(words).toString(16),
    tics: words.length,
    bounty: 5_000_000_000_000_000_000n,
    journal: packLog(words),
    blockNumber: 10 + counter,
    txHash: "0x7c" + counter.toString(16),
    ...overrides,
  };
}

const hex = (v: bigint | number): string => "0x" + BigInt(v).toString(16);

/** The raw `starknet_getEvents` entry of a `RunCommitted`, in the layout `commitments.ts` assumes. */
export function runCommittedEvent(c: RunCommitment, from = "0xd00d"): RawEvent {
  return {
    from_address: from,
    keys: [hash.getSelectorFromName("RunCommitted"), c.commitmentId, c.player, hex(c.versionId)],
    data: [
      hex(c.levelId),
      c.genesis,
      c.inputsCommitment,
      hex(c.tics),
      hex(c.bounty & ((1n << 128n) - 1n)),
      hex(c.bounty >> 128n),
      hex(c.journal.length),
      ...c.journal,
    ],
    block_number: c.blockNumber,
    block_hash: "0xb" + c.blockNumber.toString(16),
    transaction_hash: c.txHash,
  };
}

export function settledEvent(args: {
  commitmentId: string;
  prover?: string;
  runId?: string;
  outcome?: 0 | 1;
  block: number;
}): RawEvent {
  return {
    from_address: "0xd00d",
    keys: [hash.getSelectorFromName("CommitmentSettled"), args.commitmentId, args.prover ?? "0x9"],
    data: [args.runId ?? "0x0", hex(args.outcome ?? 0)],
    block_number: args.block,
    block_hash: "0xb" + args.block.toString(16),
    transaction_hash: "0x5e" + args.block.toString(16),
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

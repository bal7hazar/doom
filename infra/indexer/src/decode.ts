// SPDX-License-Identifier: Apache-2.0
/**
 * Decodes one raw `starknet_getEvents` entry into a typed {@link DoomRunsEvent}.
 *
 * Cairo serialises a non-`#[flat]` event enum the same way for every variant: `keys[0]` is the
 * selector of the variant's name (`hash.getSelectorFromName`, the same function used for
 * entrypoints), followed by the struct's own `#[key]` fields in declaration order; every
 * remaining field lands in `data`, also in declaration order. That layout is read directly off
 * `cairo/doom_contracts/crates/doom_runs/src/doom_runs.cairo`'s `Event` enum — there is no ABI
 * dependency here, so decoding does not need the contract to have been built.
 *
 * `test/decode.test.ts` cross-checks every selector against the compiled contract's ABI when
 * `cairo/doom_contracts/target/dev/doom_runs_DoomRuns.contract_class.json` exists (it skips
 * itself otherwise, same convention as the rest of the repo).
 */
import { hash } from "starknet";

import { feltToNumber, feltToShortString, normFelt } from "./felt.js";
import type { DoomRunsEvent, RawEvent } from "./types.js";

type EventName =
  | "RunSubmitted"
  | "AttemptRecorded"
  | "MemberRejected"
  | "Replay"
  | "VersionAdded"
  | "GenesisSet"
  | "Frozen";

const EVENT_NAMES: EventName[] = [
  "RunSubmitted",
  "AttemptRecorded",
  "MemberRejected",
  "Replay",
  "VersionAdded",
  "GenesisSet",
  "Frozen",
];

/** Selector -> event name, computed once. */
export const EVENT_SELECTORS: Record<string, EventName> = Object.fromEntries(
  EVENT_NAMES.map((name) => [normFelt(hash.getSelectorFromName(name)), name]),
);

export function decodeEvent(raw: RawEvent): DoomRunsEvent | undefined {
  const selector = raw.keys[0];
  if (selector === undefined) return undefined;
  const name = EVENT_SELECTORS[normFelt(selector)];
  if (!name) return undefined;

  const keys = raw.keys.slice(1);
  const data = raw.data;
  const common = { blockNumber: raw.block_number, txHash: raw.transaction_hash };

  switch (name) {
    case "RunSubmitted": {
      const [runId, player, versionId] = keys;
      const [levelId, tics, kills, items, secrets, score, nSegments, fact] = data;
      return {
        kind: "RunSubmitted",
        runId: normFelt(runId!),
        player: normFelt(player!),
        versionId: feltToNumber(versionId!),
        levelId: feltToNumber(levelId!),
        tics: feltToNumber(tics!),
        kills: feltToNumber(kills!),
        items: feltToNumber(items!),
        secrets: feltToNumber(secrets!),
        score: feltToNumber(score!),
        nSegments: feltToNumber(nSegments!),
        fact: normFelt(fact!),
        ...common,
      };
    }
    case "AttemptRecorded": {
      const [runId, player, versionId] = keys;
      const [levelId, tics, score, fact] = data;
      return {
        kind: "AttemptRecorded",
        runId: normFelt(runId!),
        player: normFelt(player!),
        versionId: feltToNumber(versionId!),
        levelId: feltToNumber(levelId!),
        tics: feltToNumber(tics!),
        score: feltToNumber(score!),
        fact: normFelt(fact!),
        ...common,
      };
    }
    case "MemberRejected": {
      const [memberIndex, player] = keys;
      const [reason, leafStart, leafLen] = data;
      return {
        kind: "MemberRejected",
        memberIndex: feltToNumber(memberIndex!),
        player: normFelt(player!),
        reason: normFelt(reason!),
        reasonText: feltToShortString(reason!),
        leafStart: feltToNumber(leafStart!),
        leafLen: feltToNumber(leafLen!),
        ...common,
      };
    }
    case "Replay": {
      const [runId] = keys;
      const [leafIndex, ticStart, ticEnd, packedLen, ...packed] = data;
      const n = feltToNumber(packedLen!);
      return {
        kind: "Replay",
        runId: normFelt(runId!),
        leafIndex: feltToNumber(leafIndex!),
        ticStart: feltToNumber(ticStart!),
        ticEnd: feltToNumber(ticEnd!),
        packed: packed.slice(0, n).map((f) => normFelt(f)),
        ...common,
      };
    }
    case "VersionAdded": {
      const [versionId] = keys;
      const [programHash, registryName, verifierRouter] = data;
      return {
        kind: "VersionAdded",
        versionId: feltToNumber(versionId!),
        programHash: normFelt(programHash!),
        registryName: normFelt(registryName!),
        registryNameText: feltToShortString(registryName!),
        verifierRouter: normFelt(verifierRouter!),
        ...common,
      };
    }
    case "GenesisSet": {
      const [versionId, levelId] = keys;
      const [genesis] = data;
      return {
        kind: "GenesisSet",
        versionId: feltToNumber(versionId!),
        levelId: feltToNumber(levelId!),
        genesis: normFelt(genesis!),
        ...common,
      };
    }
    case "Frozen": {
      const [by] = data;
      return { kind: "Frozen", by: normFelt(by!), ...common };
    }
  }
}

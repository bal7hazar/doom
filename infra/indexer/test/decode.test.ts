import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { hash } from "starknet";

import { decodeEvent, EVENT_SELECTORS } from "../src/decode.js";
import type { RawEvent } from "../src/types.js";

const CONTRACT_CLASS = fileURLToPath(
  new URL(
    "../../../cairo/doom_contracts/target/dev/doom_runs_DoomRuns.contract_class.json",
    import.meta.url,
  ),
);

const sel = (name: string): string => hash.getSelectorFromName(name);

function evt(keys: string[], data: string[]): RawEvent {
  return {
    from_address: "0x1",
    keys,
    data,
    block_number: 42,
    block_hash: "0xb42",
    transaction_hash: "0xt1",
  };
}

describe("decodeEvent", () => {
  it("decodes RunSubmitted (keys: run_id, player, version_id)", () => {
    const e = decodeEvent(
      evt(
        [sel("RunSubmitted"), "0x51", "0xf1a1", "0x1"],
        ["0x2", "0x1e0", "0x6", "0x1", "0x0", "0x279", "0x2", "0xfac71"],
      ),
    );
    expect(e).toEqual({
      kind: "RunSubmitted",
      runId: "0x51",
      player: "0xf1a1",
      versionId: 1,
      levelId: 2,
      tics: 480,
      kills: 6,
      items: 1,
      secrets: 0,
      score: 633,
      nSegments: 2,
      fact: "0xfac71",
      blockNumber: 42,
      txHash: "0xt1",
    });
  });

  it("decodes AttemptRecorded (no kills/items/secrets/n_segments)", () => {
    const e = decodeEvent(
      evt([sel("AttemptRecorded"), "0x52", "0xf1a2", "0x1"], ["0x3", "0x64", "0x190", "0xfac72"]),
    );
    expect(e).toEqual({
      kind: "AttemptRecorded",
      runId: "0x52",
      player: "0xf1a2",
      versionId: 1,
      levelId: 3,
      tics: 100,
      score: 400,
      fact: "0xfac72",
      blockNumber: 42,
      txHash: "0xt1",
    });
  });

  it("decodes MemberRejected and its short-string reason", () => {
    const reasonFelt = "0x" + Buffer.from("bad range").toString("hex");
    const e = decodeEvent(evt([sel("MemberRejected"), "0x3", "0xf1a3"], [reasonFelt, "0x0", "0x5"]));
    expect(e).toMatchObject({
      kind: "MemberRejected",
      memberIndex: 3,
      player: "0xf1a3",
      reason: reasonFelt,
      reasonText: "bad range",
      leafStart: 0,
      leafLen: 5,
    });
  });

  it("decodes Replay with its packed Span<felt252>", () => {
    const e = decodeEvent(
      evt([sel("Replay"), "0x51"], ["0x0", "0x0", "0xa0", "0x2", "0xaaaa", "0xbbbb"]),
    );
    expect(e).toEqual({
      kind: "Replay",
      runId: "0x51",
      leafIndex: 0,
      ticStart: 0,
      ticEnd: 160,
      packed: ["0xaaaa", "0xbbbb"],
      blockNumber: 42,
      txHash: "0xt1",
    });
  });

  it("decodes VersionAdded and GenesisSet", () => {
    const nameFelt = "0x" + Buffer.from("doom").toString("hex");
    const va = decodeEvent(evt([sel("VersionAdded"), "0x1"], ["0xdead1", nameFelt, "0xdead2"]));
    expect(va).toMatchObject({ kind: "VersionAdded", versionId: 1, registryNameText: "doom" });

    const gs = decodeEvent(evt([sel("GenesisSet"), "0x1", "0x2"], ["0xdead3"]));
    expect(gs).toEqual({
      kind: "GenesisSet",
      versionId: 1,
      levelId: 2,
      genesis: "0xdead3",
      blockNumber: 42,
      txHash: "0xt1",
    });
  });

  it("decodes Frozen", () => {
    const e = decodeEvent(evt([sel("Frozen")], ["0xdeaf1"]));
    expect(e).toEqual({ kind: "Frozen", by: "0xdeaf1", blockNumber: 42, txHash: "0xt1" });
  });

  it("returns undefined for an event from a different contract (unknown selector)", () => {
    expect(decodeEvent(evt(["0xdeadbeef"], []))).toBeUndefined();
  });

  it("cross-checks every selector against the compiled ABI, when it has been built", () => {
    if (!existsSync(CONTRACT_CLASS)) return; // same convention as client/ and infra/submit
    const abi = JSON.parse(readFileSync(CONTRACT_CLASS, "utf8")).abi as { type: string; name: string }[];
    const eventNames = abi.filter((i) => i.type === "event").map((i) => i.name.split("::").pop()!);
    for (const name of Object.values(EVENT_SELECTORS)) {
      expect(eventNames, `event ${name} missing from the compiled ABI`).toContain(name);
    }
  });
});

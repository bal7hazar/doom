// SPDX-License-Identifier: Apache-2.0
/**
 * Wrapper batch → `DoomRuns` calldata, and the selector primitive underneath it.
 *
 * The calldata is checked against the Python model the Cairo tests use
 * (`tools/doomruns_model.py::submit_calldata`), on the real P4.2b batches, so an accepted batch
 * here is one the contract accepted there.
 */

import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { hash } from "starknet";

import {
  checkBatch,
  membersFromPlacements,
  replayFor,
  registerMemberCalldata,
  submitBatchCalldata,
  STATUS,
  type LeafPlacement,
} from "../../../client/src/chain/batch.js";
import { executeCalldata, toHex } from "../../../client/src/chain/rpc.js";
import { getSelectorFromName, keccak256 } from "../../../client/src/chain/selector.js";
import { digestFelts, shortString } from "../src/version.js";
import { loadBatch } from "../src/fixture.js";

const CONTRACTS = join(import.meta.dirname, "../../../cairo/doom_contracts");
const FIXTURES = join(CONTRACTS, "crates/recursion_outputs/fixtures");

describe("selectors", () => {
  it("matches the known keccak-256 of the empty string", () => {
    expect("0x" + keccak256(new Uint8Array()).toString(16)).toBe(
      "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
    );
  });

  it("matches starknet.js on every entrypoint the orchestrator calls", () => {
    for (const name of [
      "begin",
      "merkle",
      "answers",
      "fri",
      "checkpoint",
      "is_valid",
      "submit_batch",
      "register_member",
      "batch_fact",
      "run_id_of",
      "is_run_registered",
      "add_version",
      "set_genesis",
      "__execute__",
      "Step",
    ]) {
      expect(getSelectorFromName(name)).toBe(hash.getSelectorFromName(name));
    }
  });

  it("builds the Cairo 1 __execute__ calldata", () => {
    const cd = executeCalldata([
      { contractAddress: "0x1", entrypoint: "fri", calldata: ["0x7", "0x8"] },
    ]);
    expect(cd).toEqual(["0x1", "0x1", getSelectorFromName("fri"), "0x2", "0x7", "0x8"]);
    expect(toHex(255n)).toBe("0xff");
  });
});

describe("the version table calldata", () => {
  it("encodes a short string the way Cairo does", () => {
    expect(shortString("doom")).toBe(0x646f6f6dn);
    expect(shortString("blake")).toBe(0x626c616b65n);
  });

  it("packs a circuit hash into the two u128 limbs of Digest", () => {
    expect(digestFelts([1, 0, 0, 0, 2, 0, 0, 0])).toEqual([1n, 2n]);
    expect(digestFelts([0, 1, 0, 0, 0, 0, 0, 0])).toEqual([1n << 32n, 0n]);
  });
});

describe.each(["B2-1_doom", "B2_doom"])("%s", (name) => {
  const loaded = loadBatch(join(FIXTURES, name), { withProof: false });

  it("recovers the ten-felt leaves from packed_output", () => {
    expect(loaded.batch.leaves.length).toBeGreaterThan(0);
    for (const leaf of loaded.batch.leaves) expect(leaf.version).toBe(1n);
    expect(loaded.batch.leafCircuitHash).toHaveLength(8);
    expect(loaded.batch.multiverifierHash).toHaveLength(8);
  });

  it("maps the fold order onto contiguous members", () => {
    const players = Object.fromEntries(
      loaded.batch.placements.map((p) => [p.runId, "0x" + (p.position + 1).toString(16)]),
    );
    const members = membersFromPlacements(loaded.batch.placements, {
      players,
      levelIds: loaded.levelIds,
    });
    expect(members.length).toBeGreaterThan(0);
    let next = 0;
    for (const m of members) {
      expect(m.leafStart).toBe(next);
      next += m.leafLen;
    }
    expect(next).toBe(loaded.batch.leaves.length);
    expect(checkBatch(loaded.batch, members, loaded.genesis)).toEqual([]);
  });

  it("builds the calldata the Python model builds", () => {
    const players = Object.fromEntries(
      loaded.batch.placements.map((p) => [p.runId, "0x1001"]),
    );
    const members = membersFromPlacements(loaded.batch.placements, {
      players,
      levelIds: loaded.levelIds,
    });
    const replay = replayFor(members, loaded.batch.logs!);
    const ours = submitBatchCalldata({
      versionId: loaded.versionId,
      leaves: loaded.batch.leaves,
      members,
      replay,
    });

    // `doomruns_model.py` is the independent model the Cairo tests are pinned against; its
    // `submit_calldata` is what `e2e_10felt_drive.py` sent on devnet.
    const script = `
import json, sys
sys.path.insert(0, ${JSON.stringify(join(CONTRACTS, "tools"))})
from pathlib import Path
from real_batch import load
from doomruns_drive import submit_calldata
batch = load(Path(${JSON.stringify(join(FIXTURES, name))}))
players = {m["game"]: 0x1001 for m in batch["members"]}
print(json.dumps(submit_calldata(batch, with_replay=True, version_id=batch["version_id"],
                                 players=players)))
`;
    const theirs = JSON.parse(
      execFileSync("python3", ["-c", script], { encoding: "utf8", stdio: "pipe" }),
    ) as string[];
    expect(ours).toEqual(theirs);
  });
});

describe("member mapping", () => {
  const placements = (runs: string[]): LeafPlacement[] =>
    runs.map((runId, position) => ({ position, runId, segmentIndex: 0 }));

  it("refuses a run whose leaves are interleaved with another's", () => {
    const p = placements(["a", "b", "a"]);
    p[2]!.segmentIndex = 1;
    expect(() =>
      membersFromPlacements(p, { players: { a: "0x1", b: "0x2" }, levelIds: {} }),
    ).toThrow(/not contiguous/);
  });

  it("refuses a fold order that is not segment order", () => {
    const p = placements(["a", "a"]);
    p[0]!.segmentIndex = 1;
    p[1]!.segmentIndex = 0;
    expect(() => membersFromPlacements(p, { players: { a: "0x1" }, levelIds: {} })).toThrow(
      /must be segment order/,
    );
  });

  it("drops a run nobody claims, keeping its leaves in the fold", () => {
    const p = placements(["a", "b"]);
    p[1]!.segmentIndex = 0;
    const members = membersFromPlacements(p, { players: { a: "0x1" }, levelIds: {} });
    expect(members).toHaveLength(1);
    expect(members[0]!.runId).toBe("a");
  });
});

describe("pre-flight checks", () => {
  const leaf = (over: Partial<Record<string, bigint>> = {}) => ({
    version: 1n,
    h_in: 1n,
    h_out: 2n,
    tic_start: 0n,
    tic_end: 10n,
    status: STATUS.EXIT,
    inputs_commitment: 9n,
    kills: 0n,
    items: 0n,
    secrets: 0n,
    ...over,
  });
  const batch = (leaves: ReturnType<typeof leaf>[]) =>
    ({ leaves, placements: [], programHash: 1n, leafCircuitHash: [], multiverifierHash: [], batchId: "x" }) as any;

  it("catches ABORT, a broken chain, a bad genesis and a non-final status", () => {
    const problems = checkBatch(
      batch([leaf({ status: STATUS.ABORT }), leaf({ h_in: 99n, status: STATUS.RUNNING })]),
      [{ player: "0x1", levelId: 1, leafStart: 0, leafLen: 2, runId: "a" }],
      1n,
    );
    expect(problems.join("\n")).toMatch(/ABORT/);
    expect(problems.join("\n")).toMatch(/chain break/);
    expect(problems.join("\n")).toMatch(/neither EXIT .* nor DEAD/);
    expect(
      checkBatch(batch([leaf()]), [{ player: "0x1", levelId: 1, leafStart: 0, leafLen: 1 }], 42n),
    ).toContainEqual(expect.stringMatching(/not the pinned genesis/));
  });

  it("accepts a DEAD last segment (an attempt, doomruns.md §12 q7)", () => {
    expect(
      checkBatch(
        batch([leaf({ status: STATUS.DEAD })]),
        [{ player: "0x1", levelId: 1, leafStart: 0, leafLen: 1 }],
        1n,
      ),
    ).toEqual([]);
  });

  it("serializes one member the same way for register_member", () => {
    const member = { player: "0x1001", levelId: 1, leafStart: 0, leafLen: 1 };
    const leaves = [leaf()];
    const single = registerMemberCalldata({ versionId: 1, leaves, member });
    const whole = submitBatchCalldata({ versionId: 1, leaves, members: [member] });
    // version_id + leaves.len() + one ten-felt leaf, then the member count only in the batch form.
    expect(single.slice(0, 12)).toEqual(whole.slice(0, 12));
    expect(whole[12]).toBe("0x1"); // members.len()
    expect(single.slice(12)).toEqual(whole.slice(13));
  });
});

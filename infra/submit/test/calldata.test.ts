// SPDX-License-Identifier: Apache-2.0
/**
 * The calldata splitter against its two references: the Python emitter
 * (`cairo/doom_contracts/tools/emit_calldata.py`), which is what the Cairo tests and every drive
 * so far used, and the devnet receipts of P4.2b, which recorded the calldata length each
 * transaction actually carried.
 *
 * A divergence here is not a style difference: the router unpacks the payload by section length
 * and checks the transcript, so one wrong felt costs a whole fact.
 */

import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gunzipSync } from "node:zlib";
import { describe, expect, it } from "vitest";

import {
  pack,
  packU32,
  parseFeltStream,
  parseProof,
  slotsOf,
  unpack,
} from "../../../client/src/chain/proof.js";
import { phaseCalldata, planPhases, planPhasesAuto } from "../../../client/src/chain/calldata.js";

const CONTRACTS = join(import.meta.dirname, "../../../cairo/doom_contracts");
const FIXTURES = join(CONTRACTS, "crates/recursion_outputs/fixtures");
const EMITTER = join(CONTRACTS, "tools/emit_calldata.py");
const RECEIPTS = join(CONTRACTS, "results/e2e_10felt_receipts.json");

const BATCHES = ["B2-1_doom", "B2_doom"] as const;

function feltsOf(batch: string): bigint[] {
  const dir = join(FIXTURES, batch);
  const plain = join(dir, "root.proof");
  if (existsSync(plain)) return parseFeltStream(readFileSync(plain, "utf8"));
  return parseFeltStream(gunzipSync(readFileSync(join(dir, "root.proof.gz"))).toString("utf8"));
}

const hexes = (v: bigint[]) => v.map((x) => "0x" + x.toString(16));

describe("proof packing", () => {
  it("round-trips the whole stream through the escaped encoding", () => {
    const felts = feltsOf("B2-1_doom");
    expect(unpack(pack(felts), felts.length)).toEqual(felts);
  });

  it("round-trips a section through the fast path", () => {
    const sec = parseProof(feltsOf("B2-1_doom"));
    const qv = sec.queriedValues[0]!;
    expect(unpack(packU32(qv), qv.length)).toEqual(qv);
  });

  it("escapes a plain 0xFFFFFFFF (the 2^-32 collision bug)", () => {
    const values = [0xffffffffn, 1n];
    expect(unpack(pack(values), 2)).toEqual(values);
    // The escape costs two extra limbs, so the value does not fit one slot on its own.
    expect(pack(values).length).toBe(1);
  });

  it("refuses a u64 on the fast path", () => {
    expect(() => packU32([1n << 33n])).toThrow(/not a u32/);
  });

  it("counts slots the way the router slices them", () => {
    expect(slotsOf(7)).toBe(1);
    expect(slotsOf(8)).toBe(2);
    expect(slotsOf(0)).toBe(0);
  });
});

describe.each(BATCHES)("%s: the plan against the Python emitter", (batch) => {
  const felts = feltsOf(batch);
  const sections = parseProof(felts);

  it("parses the sections the emitter parses", () => {
    // The shape of a ten-felt batch's root proof (onchain-verifier.md §2).
    expect(sections.queriedValues).toHaveLength(4);
    expect(sections.decommitments).toHaveLength(4);
    expect(sections.layers).toHaveLength(6);
    expect(sections.head.length).toBe(1949);
  });

  it("emits the same calldata as tools/emit_calldata.py", () => {
    const work = mkdtempSync(join(tmpdir(), "p43-"));
    const proof = join(work, "root.proof");
    writeFileSync(proof, felts.map((f) => "0x" + f.toString(16)).join("\n"));
    const out = join(work, "calls.json");
    execFileSync("python3", [EMITTER, proof, "--out", out, "--proof-id", "0x1"], {
      stdio: "pipe",
    });
    const py = JSON.parse(readFileSync(out, "utf8"));

    const phases = planPhases(sections, { proofId: 1n, friSplit: [2] });
    expect(phases).toHaveLength(py.txs.length);
    for (const [i, p] of phases.entries()) {
      const t = py.txs[i];
      expect(p.label).toBe(t.label);
      expect(p.entrypoint).toBe(t.entrypoint);
      expect(p.calldataFelts).toBe(t.calldata_felts);
      expect(p.payloadSlots).toBe(t.payload_slots);
      expect(hexes(p.payload)).toEqual(t.args.payload);
      if (p.head) expect(hexes(p.head)).toEqual(t.args.head);
      if (p.headN !== undefined) expect(p.headN).toBe(t.args.head_n);
      if (p.lens) expect(p.lens).toEqual(t.args.lens);
      if (p.trees) expect(p.trees).toEqual(t.args.trees);
      if (p.nValues !== undefined) expect(p.nValues).toBe(t.args.n_values);
    }
  });
});

describe("the plan against the P4.2b receipts", () => {
  const receipts = JSON.parse(readFileSync(RECEIPTS, "utf8"));

  it.each(BATCHES)("%s: every transaction carries the recorded calldata length", (batch) => {
    const rows = receipts.verifier_txs.filter((r: any) => r.batch === batch);
    const phases = planPhases(parseProof(feltsOf(batch)), { proofId: 1n, friSplit: [2] });
    expect(phases.map((p) => p.label)).toEqual(rows.map((r: any) => r.label));
    for (const [i, p] of phases.entries()) {
      // The emitter predicts the length; `phaseCalldata` builds it. The echo is not known
      // offline, so the prediction uses the checkpoint sizes of onchain-verifier.md §4.
      expect(p.calldataFelts).toBe(rows[i].calldata_felts);
      expect(p.payloadSlots).toBe(rows[i].payload_slots);
    }
  });

  it("builds a begin calldata of exactly the predicted length", () => {
    const phases = planPhases(parseProof(feltsOf("B2-1_doom")), { proofId: 1n, friSplit: [2] });
    expect(phaseCalldata(phases[0]!, null)).toHaveLength(phases[0]!.calldataFelts);
  });

  it("sizes an echoed phase's calldata from the real echo", () => {
    const phases = planPhases(parseProof(feltsOf("B2-1_doom")), { proofId: 1n, friSplit: [2] });
    const echo = new Array<string>(228).fill("0x1"); // MerkleState at 70 queries
    expect(phaseCalldata(phases[1]!, echo)).toHaveLength(phases[1]!.calldataFelts);
  });

  it("refuses to build an echoed phase without its echo", () => {
    const phases = planPhases(parseProof(feltsOf("B2-1_doom")), { proofId: 1n, friSplit: [2] });
    expect(() => phaseCalldata(phases[1]!, null)).toThrow(/missing state echo/);
  });
});

describe("plan selection", () => {
  const sections = parseProof(feltsOf("B2-1_doom"));

  it("defaults to the six-transaction plan", () => {
    const phases = planPhasesAuto(sections);
    expect(phases).toHaveLength(6);
    expect(phases.slice(3).map((p) => p.meta.layers)).toEqual([[0], [1, 2], [3, 4, 5]]);
  });

  it("returns the five-transaction plan when asked for the fewest", () => {
    expect(planPhasesAuto(sections, { preferFewestTransactions: true })).toHaveLength(5);
  });

  it("keeps every transaction under the calldata cap", () => {
    for (const split of [[2], [1, 3], [1, 2, 4]]) {
      for (const p of planPhases(sections, { friSplit: split })) {
        expect(p.calldataFelts).toBeLessThanOrEqual(4990);
      }
    }
  });

  it("refuses a plan that does not fit", () => {
    // One transaction for the whole FRI walk needs ~5 900 calldata felts.
    expect(() => planPhases(sections, { friSplit: [] })).toThrow(/calldata felts >/);
  });

  it("ignores cuts outside the walk", () => {
    expect(planPhases(sections, { friSplit: [0, 6, 99, 2] }).map((p) => p.label)).toEqual([
      "begin",
      "merkle",
      "answers",
      "fri1",
      "fri2",
    ]);
  });
});

// SPDX-License-Identifier: Apache-2.0
/** The cut against the client's own planner, chain continuity and every kind of break. */
import { describe, expect, it } from "vitest";

import { SegmentPlanner } from "../../../client/src/prove/planner.js";
import { packLog } from "../../../client/src/prove/ticcmd.js";
import { stepsOnlySummary, FakeExecutor } from "../src/executor.js";
import { alignCandidate, checkSegmentChain, cutJournal } from "../src/segmenter.js";
import { parseScarbOutput } from "../src/scarbExecutor.js";
import { fixtureJournal } from "./fixtures.js";

const words = fixtureJournal(0); // 297 tics, EXIT at the end of the fixture's game 0

async function fakeGenesis(executor: FakeExecutor): Promise<string> {
  return (await executor.genesis(1)).hash;
}

describe("cutJournal", () => {
  it("cuts exactly where the client's SegmentPlanner would, probe for probe", async () => {
    const executor = new FakeExecutor({ terminal: { tic: 297, status: 2 } });
    const genesis = await fakeGenesis(executor);
    const { segments, chain } = await cutJournal(executor, words, { genesis, levelId: 1 });
    expect(chain.ok).toBe(true);
    expect(chain.finalStatus).toBe(2);
    expect(segments[0]!.ticStart).toBe(0);
    expect(segments[segments.length - 1]!.ticEnd).toBe(297);

    // An independent replay of the browser loop (pipeline.ts::planNext) on the same cost model.
    const oracle = new FakeExecutor({ terminal: { tic: 297, status: 2 } });
    const planner = new SegmentPlanner();
    const expected: { ticStart: number; ticEnd: number; probes: number }[] = [];
    let tic = 0;
    let state = (await oracle.genesis(1)).state;
    while (tic < words.length) {
      const available = words.length - tic;
      let candidate = alignCandidate(Math.min(planner.propose(Number.MAX_SAFE_INTEGER, 1), available), available);
      let probes = 0;
      for (;;) {
        probes++;
        const ex = await oracle.segment(state, words.slice(tic, tic + candidate), tic, candidate);
        const verdict = planner.judge(candidate, ex.resources!, 1);
        if (verdict.verdict === "accept") {
          expected.push({ ticStart: tic, ticEnd: ex.output.ticEnd, probes });
          if (ex.output.status !== 0) {
            tic = words.length;
            break;
          }
          state = (await oracle.step(state, words.slice(tic, ex.output.ticEnd))).state;
          tic = ex.output.ticEnd;
          break;
        }
        if (verdict.verdict === "impossible") throw new Error(verdict.reason);
        candidate = verdict.tics;
        if (probes >= planner.config.maxProbes) candidate = Math.max(1, Math.floor(candidate / 2));
        candidate = alignCandidate(candidate, available);
      }
    }
    expect(segments.map((s) => ({ ticStart: s.ticStart, ticEnd: s.ticEnd, probes: s.probes }))).toEqual(expected);
    expect(expected.length).toBeGreaterThan(3);
    expect(segments.some((s) => s.probes > 1)).toBe(true); // the first proposal (64 tics) is over the ceiling
    for (const s of segments) {
      expect(s.nSteps).toBeLessThanOrEqual(2_300_000);
      expect(s.resources.rowsChecked).toBe(true);
      expect(s.args.length).toBe(1 + 47 + 1 + (s.ticEnd - s.ticStart) + 2);
    }
    // Every non-final boundary is on a multiple of 7 tics, so the replay logs concatenate to
    // the committed journal — which is what DoomRuns folds to pay a multi-segment bounty.
    for (const s of segments.slice(0, -1)) expect((s.ticEnd - s.ticStart) % 7).toBe(0);
    expect((segments[segments.length - 1]!.ticEnd - segments[segments.length - 1]!.ticStart) % 7).not.toBe(0);
    expect(segments.flatMap((s) => s.packed)).toEqual(packLog(words));
    // step_tic replays exactly the accepted tics, 32 at a time, never past a boundary.
    const steps = executor.calls.filter((c) => c.op === "step");
    expect(steps.reduce((a, c) => a + c.tics, 0)).toBe(segments[segments.length - 1]!.ticStart);
    expect(Math.max(...steps.map((c) => c.tics))).toBeLessThanOrEqual(32);
  });

  it("uses the threaded ceiling, the steps-only path and a caller's planner config", async () => {
    const executor = new FakeExecutor({ terminal: { tic: 297, status: 2 }, resources: "steps-only" });
    const genesis = await fakeGenesis(executor);
    const { segments } = await cutJournal(executor, words, { genesis, levelId: 1, threads: 4 });
    for (const s of segments) {
      expect(s.nSteps).toBeLessThanOrEqual(1_500_000);
      expect(s.resources.rowsChecked).toBe(false);
      expect(s.resources.maxComponent).toBe("steps-only");
    }
    // A native node with a higher measured ceiling (D35 calibration) cuts fewer, larger segments.
    const big = new FakeExecutor({ terminal: { tic: 297, status: 2 }, registryLogSize: 23 });
    const wide = await cutJournal(big, words, {
      genesis: await fakeGenesis(big), levelId: 1,
      planner: { maxStepsSingleThread: 13_000_000, maxComponentLogSize: 23, initialTics: 300 },
    });
    expect(wide.segments).toHaveLength(1);
    expect(stepsOnlySummary(5).fits_leaf_registry).toBe(true);
  });

  it("stops at a DEAD tic and refuses a journal that continues past it", async () => {
    const dead = new FakeExecutor({ terminal: { tic: 100, status: 1 } });
    const genesis = await fakeGenesis(dead);
    const cut = await cutJournal(dead, words.slice(0, 100), { genesis, levelId: 1 });
    expect(cut.chain.finalStatus).toBe(1);
    expect(cut.segments[cut.segments.length - 1]!.ticEnd).toBe(100);
    await expect(cutJournal(new FakeExecutor({ terminal: { tic: 100, status: 1 } }), words, { genesis, levelId: 1 }))
      .rejects.toThrow(/continues 197 tic\(s\) past the terminal state/);
  });

  it("refuses an unfinished journal, an aborting command and a foreign genesis", async () => {
    const running = new FakeExecutor();
    const genesis = await fakeGenesis(running);
    await expect(cutJournal(running, words, { genesis, levelId: 1 })).rejects.toThrow(/still RUNNING/);
    const bad = [...words.slice(0, 50), 0xffffffff, ...words.slice(51, 60)];
    await expect(cutJournal(new FakeExecutor(), bad, { genesis, levelId: 1 })).rejects.toThrow(/ABORT/);
    await expect(cutJournal(new FakeExecutor(), words, { genesis: "0x1", levelId: 1 })).rejects.toThrow(/genesis/);
  });

  it("detects a broken chain, a wrong commitment and partial coverage after the fact", async () => {
    const executor = new FakeExecutor({ terminal: { tic: 297, status: 2 } });
    const genesis = await fakeGenesis(executor);
    const { segments } = await cutJournal(executor, words, { genesis, levelId: 1 });
    expect(checkSegmentChain(segments, words, genesis).ok).toBe(true);

    const broken = structuredClone(segments);
    broken[2]!.output.hIn = "0x1234";
    expect(checkSegmentChain(broken, words, genesis)).toMatchObject({ ok: false, index: 2, reason: expect.stringMatching(/does not continue/) });

    const forged = structuredClone(segments);
    forged[1]!.output.inputsCommitment = "0x99";
    expect(checkSegmentChain(forged, words, genesis)).toMatchObject({ ok: false, index: 1, reason: expect.stringMatching(/inputs_commitment/) });

    const swapped = structuredClone(segments);
    swapped[1]!.packed = segments[0]!.packed;
    expect(checkSegmentChain(swapped, words, genesis).reason).toMatch(/not the segment's slice/);

    expect(checkSegmentChain(segments.slice(0, -1), words, genesis).reason).toMatch(/still RUNNING/);
    expect(checkSegmentChain(segments, [...words, 1], genesis).reason).toMatch(/cover 297 of 298/);

    // A cut that is continuous but not 7-aligned could never be settled: refused as a chain fault.
    const misaligned = structuredClone(segments);
    misaligned[0]!.ticEnd -= 1;
    misaligned[0]!.output.ticEnd -= 1;
    misaligned[1]!.ticStart -= 1;
    misaligned[1]!.output.ticStart -= 1;
    expect(checkSegmentChain(misaligned, words, genesis).reason).toMatch(/not a multiple of 7/);
  });

  it("aligns proposals on 7 tics and refuses a ceiling too low for seven", async () => {
    expect(alignCandidate(64, 297)).toBe(63);
    expect(alignCandidate(7, 297)).toBe(7);
    expect(alignCandidate(300, 297)).toBe(297);
    expect(alignCandidate(20, 20)).toBe(20);
    expect(() => alignCandidate(6, 297)).toThrow(/at least 7 tics/);
    const tight = new FakeExecutor({ terminal: { tic: 297, status: 2 }, fixedSteps: 2_100_000 });
    await expect(cutJournal(tight, words, { genesis: (await tight.genesis(1)).hash, levelId: 1 })).rejects.toThrow(/7-tic boundaries/);
  });
});

describe("scarb output parsing", () => {
  it("reads the felts after 'Program output:' and the step count", () => {
    const text = [
      "   Compiling doom_run",
      "Resources:",
      "  steps: 693425",
      "  builtins: range_check: 12",
      "Program output:",
      "1",
      "0x7b",
      "-1",
      "",
      "Saving output to: target/execute",
    ].join("\n");
    const parsed = parseScarbOutput(text);
    expect(parsed.nSteps).toBe(693425);
    expect(parsed.output).toEqual(["0x1", "0x7b", "0x800000000000011000000000000000000000000000000000000000000000000"]);
  });

  it("reads what Scarb 2.16.0 really prints: signed decimals and a step count with thousands separators", () => {
    // Verbatim shape of `scarb execute --print-program-output --print-resource-usage` on the
    // real `run_segment` (70 tics of the walk): the commitment came out negative, the step count
    // with commas — read as 2 instead of 2,383,556 the D26 ceiling would never bind.
    const text = [
      "   Executing doom_run",
      "Program output:",
      "1",
      "1274278165169918663920846137645782095596786929756411483948674016230306792794",
      "721861253222809819190156455560350791108641517704002613494693279197264662941",
      "0",
      "70",
      "0",
      "-1490066978920888978358014582453116020816513122388232826822029463219497483464",
      "0",
      "0",
      "0",
      "Resources:",
      "\tsteps: 2,383,556",
      "\tmax memory address: 2,417,013",
      "\tbuiltins:",
      "\t\trange_check_builtin: 85,898",
      "",
    ].join("\n");
    const parsed = parseScarbOutput(text);
    expect(parsed.nSteps).toBe(2_383_556);
    expect(parsed.output).toHaveLength(10);
    expect(parsed.output[1]).toBe("0x2d1374414503eb8db44adb1498990546a9b5e20a8e62f3c70b29fb07d78c55a"); // E1M1 genesis
    expect(parsed.output[4]).toBe("0x46");
    expect(BigInt(parsed.output[6]!)).toBe(
      (1n << 251n) + 17n * (1n << 192n) + 1n - 1490066978920888978358014582453116020816513122388232826822029463219497483464n,
    );
  });
});

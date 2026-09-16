// SPDX-License-Identifier: Apache-2.0
/**
 * The real executor: `ScarbExecutor` on the `doom_run` executables of this checkout, no proof.
 *
 * Skipped, with the reason on stderr, when `scarb` cannot be run (`$HELLPROOF_SCARB`, else the
 * PATH) or the proving profile has not been built
 * (`scarb --manifest-path cairo/Scarb.toml --profile proving build -p doom_run`). Runs one
 * `scarb execute` at a time; the whole file is a few minutes on four cores.
 *
 * Two real E1M1 journals of `cairo/doom/doom_game/regression/` drive it, rebuilt here from the
 * corpus definitions and pinned by the corpus's own `input_sha256`:
 *
 * - `walk_lift` (350 tics, still RUNNING): the ten D14 felts of one `run_segment` over the whole
 *   log must be the golden's, felt for felt — its `h_out` is the `WALK_HASH` of
 *   `doom_game/src/tests/e1m1.cairo`; then the same run as two 7-aligned segments joined by
 *   `step_tic`.
 * - `exit_route` (677 tics, a real spawn-to-EXIT game): what a player would commit. The
 *   segmenter cuts it under the D26 step ceiling (steps-only), the chain is continuous, the
 *   concatenated replay logs are the committed journal and the final `h_out` is the golden's.
 *   Then the whole node, on its network doubles, with this executor.
 */
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it, vi } from "vitest";

import { TAG } from "../../../client/src/chain/sequence.js";
import { checkState } from "../../../client/src/prove/doomPreparation.js";
import { normalizeFelt } from "../../../client/src/prove/felt.js";
import { packLog } from "../../../client/src/prove/ticcmd.js";
import { FileEchoStore } from "../../submit/src/stores.js";
import { commitLog } from "../src/commitment.js";
import { wrapperRunId } from "../src/commitments.js";
import { FileDiscoveryStore } from "../src/discovery.js";
import { segmentLog } from "../src/journal.js";
import { Logbook } from "../src/log.js";
import { MetricsFile } from "../src/metrics.js";
import { ProverNode } from "../src/node.js";
import { DEFAULT_POLICY } from "../src/policy.js";
import { FakeProver } from "../src/prover.js";
import { missingExecutables, probeScarb, ScarbExecutor } from "../src/scarbExecutor.js";
import { cutJournal, type PlannedSegment } from "../src/segmenter.js";
import { FileJobStore } from "../src/store.js";
import { commitmentEvents, fakeCommitment, FakeEventSource } from "./fixtures.js";
import { fakeWrapper, fixedEstimate, mockRpc } from "./wrapper.js";

const REPO = join(import.meta.dirname, "../../..");
const MANIFEST = join(REPO, "cairo/Scarb.toml");
const REGRESSION = join(REPO, "cairo/doom/doom_game/regression");
const E1M1 = 0;
/** The browser's single-thread D26 ceiling, the planner's default for `threads: 1`. */
const STEP_CEILING = 2_300_000;

const scarb = probeScarb();
const missing = missingExecutables(MANIFEST);
const reason = !scarb
  ? "no runnable scarb: set HELLPROOF_SCARB or put Scarb 2.16.0 on the PATH"
  : missing.length
    ? `doom_run is not built for the proving profile (missing ${missing.map((m) => m.split("/").pop()).join(", ")})`
    : null;
if (reason) console.warn(`realExecutor.test.ts skipped: ${reason}`);

// --- the corpus, rebuilt from its definitions -------------------------------------------------

interface Golden {
  input_sha256: string;
  status: number;
  tic: number;
  stats: number[];
  d14: string[];
}

function golden(name: string): Golden {
  const all = JSON.parse(readFileSync(join(REGRESSION, "goldens.json"), "utf8")) as { cases: Record<string, Golden> };
  const g = all.cases[name];
  if (!g) throw new Error(`no golden ${name}`);
  return g;
}

/** `corpus.word` / `ticcmd`: the canonical 32-bit command word. */
function word(forward = 0, side = 0, turn = 0, buttons = 0): number {
  return ((forward + 128) | ((side + 128) << 8) | ((turn / 256 + 128) << 16) | (buttons << 24)) >>> 0;
}

/** `abi.digest`: how the corpus pins an input log. */
function digest(words: readonly number[]): string {
  return createHash("sha256").update(words.map((w) => "0x" + w.toString(16)).join(" ")).digest("hex");
}

/** `corpus.scenarios()`'s `walk`: east out of the start room, over the lift, then idle. */
function walkLog(): number[] {
  const words = [...Array<number>(110).fill(word(25)), ...Array<number>(240).fill(word())];
  expect(digest(words)).toBe(golden("walk_lift").input_sha256);
  return words;
}

/** `exit_route.EXIT_RLE`: the 677 real commands from spawn to the exit switch (no suffix). */
function exitRouteLog(): number[] {
  const source = readFileSync(join(REGRESSION, "exit_route.py"), "utf8");
  const route = [...source.matchAll(/\((\d+),\s*(0x[0-9a-fA-F]+)\)/g)].flatMap(([, count, w]) =>
    Array<number>(Number(count)).fill(Number(BigInt(w!))),
  );
  const suffix = Number(/EXIT_SUFFIX_TICS\s*=\s*(\d+)/.exec(source)![1]);
  // The corpus supplies 17 more words after the exit; they are never consumed and a
  // commitment carrying them would be refused ("continues past the terminal state").
  expect(digest([...route, ...Array<number>(suffix).fill(word(50, 40, 512, 1))])).toBe(golden("exit_route").input_sha256);
  expect(route).toHaveLength(golden("exit_route").tic);
  return route;
}

const same = (a: readonly string[], b: readonly string[]) => expect(a.map(normalizeFelt)).toEqual(b.map(normalizeFelt));

// --- the tests --------------------------------------------------------------------------------

describe.skipIf(reason !== null)("ScarbExecutor on the real doom_run executables", () => {
  const work = mkdtempSync(join(tmpdir(), "prover-node-real-"));
  afterAll(() => rmSync(work, { recursive: true, force: true }));
  const executor = new ScarbExecutor({ manifest: MANIFEST, workDir: join(work, "execute"), ...(scarb ? { scarb: scarb.bin } : {}) });
  const report = (label: string, s: { nSteps: number; ms: number }, tics: number) =>
    console.log(`${label}: ${tics} tics, ${s.nSteps} steps (${Math.round(s.nSteps / Math.max(tics, 1))}/tic), ${Math.round(s.ms)} ms`);

  it("runs genesis: the E1M1 start state the corpus pins, schema 2 at tic zero", async () => {
    const g = await executor.genesis(E1M1);
    expect(normalizeFelt(g.hash)).toBe(normalizeFelt(golden("walk_lift").d14[1]!));
    expect(checkState(g.state)).toBe(0);
    expect(g.state.length).toBeGreaterThan(6000); // 6 362 felts on this engine, not the fake's 47
    await expect(executor.genesis(99)).rejects.toThrow(/invalid genesis envelope/); // `([], 0)`
  }, 120_000);

  it("reproduces the walk's ten D14 felts in one run_segment, and as two 7-aligned segments", async () => {
    const words = walkLog();
    const g = golden("walk_lift");
    const genesis = await executor.genesis(E1M1);

    const whole = await executor.segment(genesis.state, words, 0, words.length);
    report("run_segment walk (whole)", whole, words.length);
    same(whole.outputFelts, g.d14);
    expect(whole.output).toMatchObject({ ticStart: 0, ticEnd: 350, status: 0, kills: 0, items: 1, secrets: 0 });
    // The golden's h_out is `WALK_HASH` of doom_game/src/tests/e1m1.cairo.
    expect(BigInt(whole.output.hOut)).toBe(3462572684582230757027468800465421350164007866179957854524195282835990262921n);
    expect(whole.resources).toBeNull();

    // Cut at 175 = 25 × 7: the first segment's log is 25 whole felts, so the two logs
    // concatenate to the journal (D13 per segment, the contract folds the concatenation).
    const cut = 175;
    const first = await executor.segment(genesis.state, words.slice(0, cut), 0, cut);
    expect(first.output).toMatchObject({ ticStart: 0, ticEnd: cut, status: 0 });
    expect(normalizeFelt(first.output.hIn)).toBe(normalizeFelt(genesis.hash));
    let state = genesis.state;
    for (let tic = 0; tic < cut; tic += 32) {
      const step = await executor.step(state, words.slice(tic, Math.min(tic + 32, cut)));
      expect(step.status).toBe(0);
      state = step.state;
      expect(checkState(state)).toBe(Math.min(tic + 32, cut));
    }
    const second = await executor.segment(state, words.slice(cut), cut, words.length - cut);
    expect(second.output).toMatchObject({ ticStart: cut, ticEnd: 350, status: 0, items: 1 });
    expect(normalizeFelt(second.output.hIn)).toBe(normalizeFelt(first.output.hOut));
    expect(normalizeFelt(second.output.hOut)).toBe(normalizeFelt(g.d14[2]!));
    expect(BigInt(first.output.inputsCommitment)).toBe(segmentLog(words, 0, cut).commitment);
    expect(BigInt(second.output.inputsCommitment)).toBe(segmentLog(words, cut, words.length).commitment);
    const concatenated = [...segmentLog(words, 0, cut).packed, ...segmentLog(words, cut, words.length).packed];
    expect(concatenated).toEqual(packLog(words).map(BigInt));
    expect(commitLog(concatenated)).toBe(BigInt(g.d14[6]!));
    expect(first.nSteps + second.nSteps).toBeGreaterThan(whole.nSteps); // the boundary costs a second parse
  }, 300_000);

  it("measures run_segment at 35, 70 and 140 tics: the node's execution cost per tic", async () => {
    const words = walkLog();
    const genesis = await executor.genesis(E1M1);
    let previous = 0;
    for (const tics of [35, 70, 140]) {
      const s = await executor.segment(genesis.state, words.slice(0, tics), 0, tics);
      report(`run_segment walk`, s, tics);
      expect(s.output).toMatchObject({ ticStart: 0, ticEnd: tics, status: 0 });
      expect(normalizeFelt(s.output.hIn)).toBe(normalizeFelt(genesis.hash));
      expect(BigInt(s.output.inputsCommitment)).toBe(segmentLog(words, 0, tics).commitment);
      expect(s.nSteps).toBeGreaterThan(previous);
      previous = s.nSteps;
    }
  }, 300_000);

  let cutSegments: PlannedSegment[] = [];

  it("cuts the real exit route under the D26 ceiling into a chain the contract could settle", async () => {
    const words = exitRouteLog();
    const g = golden("exit_route");
    const lines: string[] = [];
    const { segments, chain } = await cutJournal(executor, words, {
      genesis: g.d14[1]!,
      levelId: E1M1,
      threads: 1,
      log: (m) => lines.push(m),
    });
    cutSegments = segments;
    for (const s of segments) report(`segment ${s.index} [${s.ticStart}, ${s.ticEnd}) ${s.probes} probe(s)`, { nSteps: s.nSteps, ms: s.executeMs }, s.ticEnd - s.ticStart);

    expect(chain).toMatchObject({ ok: true, tics: 677, finalStatus: 2 });
    expect(segments.length).toBeGreaterThan(5);
    const last = segments[segments.length - 1]!;
    expect(last.ticEnd).toBe(677);
    // Spawn to EXIT: the node's chain ends on the corpus's golden, felt for felt.
    same([last.output.hOut], [g.d14[2]!]);
    expect(last.output).toMatchObject({ status: 2, kills: g.stats[0], items: g.stats[1], secrets: g.stats[2] });
    expect(normalizeFelt(segments[0]!.output.hIn)).toBe(normalizeFelt(g.d14[1]!));
    for (let i = 1; i < segments.length; i++) {
      expect(normalizeFelt(segments[i]!.output.hIn)).toBe(normalizeFelt(segments[i - 1]!.output.hOut));
      expect(segments[i]!.ticStart).toBe(segments[i - 1]!.ticEnd);
    }
    for (const s of segments) {
      expect(s.output.status).toBe(s === last ? 2 : 0);
      expect(s.nSteps).toBeLessThanOrEqual(STEP_CEILING);
      expect(s.resources).toMatchObject({ rowsChecked: false, maxComponent: "steps-only" });
      expect(BigInt(s.output.inputsCommitment)).toBe(segmentLog(words, s.ticStart, s.ticEnd).commitment);
      // `[state_len, state…, words_len, words…, tic_start, max_tics]`; the state length varies by tic.
      const stateLen = Number(BigInt(s.args[0]!));
      expect(stateLen).toBeGreaterThan(6000);
      expect(Number(BigInt(s.args[1 + stateLen]!))).toBe(s.ticEnd - s.ticStart);
      expect(s.args.length).toBe(1 + stateLen + 1 + (s.ticEnd - s.ticStart) + 2);
      expect(s.args[s.args.length - 2]).toBe("0x" + s.ticStart.toString(16));
    }
    for (const s of segments.slice(0, -1)) expect((s.ticEnd - s.ticStart) % 7).toBe(0);
    const concatenated = segments.flatMap((s) => s.packed.map(BigInt));
    expect(concatenated).toEqual(packLog(words).map(BigInt));
    expect(commitLog(concatenated)).toBe(BigInt(g.d14[6]!));
    expect(lines.some((l) => /rejected/.test(l))).toBe(true); // the planner's first 63-tic proposal is over the ceiling
  }, 900_000);

  it("takes a committed exit route through the whole node on this executor", async () => {
    const words = exitRouteLog();
    const g = golden("exit_route");
    const genesis = normalizeFelt(g.d14[1]!);
    const commitment = fakeCommitment(words, { genesis, levelId: E1M1, blockNumber: 3 });
    const source = new FakeEventSource(commitmentEvents(commitment), 20);
    const prover = new FakeProver();
    const wrapper = fakeWrapper(wrapperRunId(commitment.commitmentId), { batch: "uploads" });
    const sent: string[] = [];
    const signer = {
      kind: "test", address: "0x123",
      execute: vi.fn(async (calls: { entrypoint: string }[]) => { sent.push(calls[0]!.entrypoint); return { transactionHash: "0x" + (sent.length * 16).toString(16) }; }),
    };
    const node = new ProverNode(
      { doomRuns: "0xd00d", router: "0x456", startBlock: 0, policy: DEFAULT_POLICY, threads: 1 },
      {
        source, executor, prover, wrapper: wrapper.client,
        rpc: mockRpc({ tag: TAG.FREE, settles: { commitmentId: commitment.commitmentId, prover: "0x123" }, commitment: { status: 1, genesis, tics: commitment.tics, player: commitment.player } }),
        signer, echoStore: new FileEchoStore(join(work, "echoes.json")), estimate: fixedEstimate,
      },
      { jobs: new FileJobStore(work), discovery: new FileDiscoveryStore(join(work, "discovery.json")), metrics: new MetricsFile(join(work, "metrics.json")), log: new Logbook(join(work, "logbook.txt")) },
    );
    const out = await node.pollOnce();
    expect(out.selection.selected.map((c) => c.commitmentId)).toEqual([commitment.commitmentId]);
    const job = out.processed[0]!;
    expect(job.error).toBeUndefined();
    expect(job.stage).toBe("registered");
    const n = job.segments!.length;
    // Deterministic: the same cut as the direct one, boundary for boundary.
    expect(job.segments!.map((s) => [s.ticStart, s.ticEnd, s.output.hOut])).toEqual(cutSegments.map((s) => [s.ticStart, s.ticEnd, s.output.hOut]));
    expect(prover.calls).toEqual(Array.from({ length: n }, (_, i) => i));
    expect(wrapper.calls.filter((c) => c.startsWith("PUT"))).toHaveLength(n);
    expect(sent).toEqual(["begin", "merkle", "answers", "fri", "fri", "register_member"]);
    expect(job.chain).toMatchObject({ settled: true });
    expect(readFileSync(join(work, "logbook.txt"), "utf8")).toMatch(new RegExp(`cut into ${n} segment\\(s\\), chain continuous, final status 2`));
    expect(job.timings["cut"]).toBeGreaterThan(0);
    console.log(`node: ${n} segments, cut ${Math.round(job.timings["cut"]!)} ms, registered`);
  }, 900_000);
});

import { describe, expect, it } from "vitest";
import { verifyChain } from "../src/prove/chain.js";
import { decodeSegmentOutput, splitPreimage } from "../src/prove/program.js";
import { SegmentStatus, type SegmentOutput } from "../src/prove/types.js";

function out(over: Partial<SegmentOutput> = {}): SegmentOutput {
  return {
    version: 1,
    hIn: "0x1",
    hOut: "0x2",
    ticStart: 0,
    ticEnd: 10,
    status: SegmentStatus.RUNNING,
    inputsCommitment: "0xabc",
    kills: 0,
    items: 0,
    secrets: 0,
    ...over,
  };
}

describe("verifyChain", () => {
  it("accepts a two-segment chain that links up", () => {
    const result = verifyChain(
      [out(), out({ hIn: "0x2", hOut: "0x3", ticStart: 10, ticEnd: 21 })],
      { genesis: "0x1" },
    );
    expect(result.ok).toBe(true);
    expect(result.tics).toBe(21);
  });

  it("accepts the same felts written differently (0x01 vs 0x1)", () => {
    const result = verifyChain([out({ hOut: "0x02" }), out({ hIn: "0x2", ticStart: 10, ticEnd: 20 })], {
      genesis: "0x0000001",
    });
    expect(result.ok).toBe(true);
  });

  it("rejects a first segment that does not start at the genesis", () => {
    const result = verifyChain([out({ hIn: "0x9" })], { genesis: "0x1" });
    expect(result.ok).toBe(false);
    expect(result.index).toBe(0);
    expect(result.reason).toMatch(/genesis/);
  });

  it("rejects a broken h_out -> h_in link", () => {
    const result = verifyChain([out(), out({ hIn: "0x99", ticStart: 10, ticEnd: 20 })], { genesis: "0x1" });
    expect(result.ok).toBe(false);
    expect(result.index).toBe(1);
    expect(result.reason).toMatch(/does not continue h_out/);
  });

  it("rejects a tic gap between segments", () => {
    const result = verifyChain([out(), out({ hIn: "0x2", ticStart: 11, ticEnd: 20 })], { genesis: "0x1" });
    expect(result.ok).toBe(false);
    expect(result.reason).toMatch(/tic_start/);
  });

  it("rejects ABORT outright (R4-A2, D21)", () => {
    const result = verifyChain([out({ status: SegmentStatus.ABORT })], { genesis: "0x1" });
    expect(result.ok).toBe(false);
    expect(result.reason).toMatch(/ABORT/);
  });

  it("rejects a terminal status on a segment that is not the last", () => {
    const result = verifyChain(
      [out({ status: SegmentStatus.EXIT }), out({ hIn: "0x2", ticStart: 10, ticEnd: 20 })],
      { genesis: "0x1" },
    );
    expect(result.ok).toBe(false);
    expect(result.index).toBe(0);
    expect(result.reason).toMatch(/EXIT/);
  });

  it("rejects an empty segment", () => {
    const result = verifyChain([out({ ticEnd: 0 })], { genesis: "0x1" });
    expect(result.ok).toBe(false);
    expect(result.reason).toMatch(/empty segment/);
  });

  it("rejects score counters going backwards", () => {
    const result = verifyChain(
      [out({ kills: 3 }), out({ hIn: "0x2", ticStart: 10, ticEnd: 20, kills: 2 })],
      { genesis: "0x1" },
    );
    expect(result.ok).toBe(false);
    expect(result.reason).toMatch(/backwards/);
  });

  it("only demands a terminal status when the run claims to be finished", () => {
    const running = [out({ status: SegmentStatus.RUNNING })];
    expect(verifyChain(running, { genesis: "0x1" }).ok).toBe(true);
    const finished = verifyChain(running, { genesis: "0x1", requireFinished: true });
    expect(finished.ok).toBe(false);
    expect(finished.reason).toMatch(/still RUNNING/);
    expect(
      verifyChain([out({ status: SegmentStatus.EXIT })], { genesis: "0x1", requireFinished: true }).ok,
    ).toBe(true);
  });

  it("refuses an empty run", () => {
    expect(verifyChain([], { genesis: "0x1" }).ok).toBe(false);
  });
});

describe("segment output decoding (D14)", () => {
  const felts = ["0x1", "0xaa", "0xbb", "0x0", "0x46", "0x0", "0xcc", "0x3", "0x1", "0x2"];

  it("reads the ten felts in Serde order", () => {
    expect(decodeSegmentOutput(felts)).toEqual({
      version: 1,
      hIn: "0xaa",
      hOut: "0xbb",
      ticStart: 0,
      ticEnd: 70,
      status: 0,
      inputsCommitment: "0xcc",
      kills: 3,
      items: 1,
      secrets: 2,
    });
  });

  it("refuses a layout version it does not know", () => {
    expect(() => decodeSegmentOutput(["0x2", ...felts.slice(1)])).toThrow(/version/);
  });

  it("refuses anything that is not ten felts", () => {
    expect(() => decodeSegmentOutput(felts.slice(1))).toThrow(/10 felts/);
  });

  it("splits [program_hash, out_0 … out_9]", () => {
    const { programHash, output } = splitPreimage(["0xdead", ...felts]);
    expect(programHash).toBe("0xdead");
    expect(output.ticEnd).toBe(70);
  });
});

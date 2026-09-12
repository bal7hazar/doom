import { describe, expect, it } from "vitest";
import { EXIT_BUDGET_EXCEEDED, parseArgs } from "../src/cli.js";

describe("CLI argument parsing", () => {
  it("parses the required flags with their defaults", () => {
    const args = parseArgs(["--wad", "freedoom1.wad", "--map", "E1M1", "--out", "out/"]);
    expect(args.wad).toBe("freedoom1.wad");
    expect(args.map).toBe("E1M1");
    expect(args.out).toBe("out/");
    expect(args.maxWords).toBe(12_000);
    // No --report given: the report is opt-in, decoupled from --out, so that
    // --out alone can never overwrite the committed REPORT-<map>.md.
    expect(args.report).toBeUndefined();
    expect(args.noBudgetGate).toBe(false);
  });

  it("requires --wad, --map and --out", () => {
    expect(() => parseArgs(["--map", "E1M1", "--out", "out/"])).toThrow(/Usage/);
    expect(() => parseArgs(["--wad", "x.wad", "--out", "out/"])).toThrow(/Usage/);
    expect(() => parseArgs(["--wad", "x.wad", "--map", "E1M1"])).toThrow(/Usage/);
  });

  it("parses --report as an absolute path, independent of --out", () => {
    const args = parseArgs([
      "--wad",
      "x.wad",
      "--map",
      "E1M1",
      "--out",
      "/tmp/scratch/out",
      "--report",
      "REPORT-e1m1.md",
    ]);
    expect(args.report).toBeDefined();
    expect(args.report).toMatch(/REPORT-e1m1\.md$/);
    // --report never derives from --out (see cli.ts's comment on the fix).
    expect(args.report).not.toContain("/tmp/scratch/out");
  });

  it("parses --no-budget-gate as a boolean flag with no value", () => {
    const args = parseArgs(["--wad", "x.wad", "--map", "E1M1", "--out", "out/", "--no-budget-gate"]);
    expect(args.noBudgetGate).toBe(true);
  });

  it("parses --max-words and rejects a non-positive value", () => {
    const args = parseArgs(["--wad", "x.wad", "--map", "E1M1", "--out", "out/", "--max-words", "500"]);
    expect(args.maxWords).toBe(500);
    expect(() =>
      parseArgs(["--wad", "x.wad", "--map", "E1M1", "--out", "out/", "--max-words", "0"]),
    ).toThrow(/positive number/);
    expect(() =>
      parseArgs(["--wad", "x.wad", "--map", "E1M1", "--out", "out/", "--max-words", "nope"]),
    ).toThrow(/positive number/);
  });

  it("rejects an unknown flag", () => {
    expect(() => parseArgs(["--wad", "x.wad", "--map", "E1M1", "--out", "out/", "--bogus"])).toThrow(
      /Unknown argument/,
    );
  });

  it("the bytecode-budget exit code is distinct from the generic error exit code (1)", () => {
    expect(EXIT_BUDGET_EXCEEDED).toBe(3);
    expect(EXIT_BUDGET_EXCEEDED).not.toBe(1);
  });
});

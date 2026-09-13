import { describe, expect, it } from "vitest";
import type { ResourceSummary } from "@hellproof/prover-wasm";
import { DEFAULT_PLANNER_CONFIG, SegmentPlanner, nextPow2, rawMaxComponentRows } from "../src/prove/planner.js";

/**
 * A `resources()` answer, built the way the prover builds one: raw counters, the
 * largest of them rounded up to a power of two, `fits_leaf_registry` iff that
 * power of two is at most 2^20.
 */
function summary(options: {
  steps: number;
  /** Raw count of the largest component. */
  rows: number;
  component?: string;
  idToSmall?: number;
  addressToId?: number;
  idToBigComponents?: number;
}): ResourceSummary {
  const component = options.component ?? "assert_eq_opcode_double_deref";
  const maxRows = nextPow2(
    Math.max(options.rows, options.idToSmall ?? 0, (options.addressToId ?? 0) / 16),
  );
  return {
    n_steps: options.steps,
    opcodes: [
      [component, options.rows],
      ["add_opcode_small", Math.floor(options.rows / 2)],
    ],
    builtins: [["range_check_builtin", Math.floor(options.rows / 8)]],
    unique_aggregator_inputs: [],
    memory_address_to_id: options.addressToId ?? 16,
    memory_id_to_big: 158,
    memory_id_to_small: options.idToSmall ?? 1,
    verify_instruction: 1149,
    max_component_rows: maxRows,
    max_component: component,
    log_max_component_size: Math.log2(maxRows),
    fits_leaf_registry: maxRows <= 2 ** 20,
    ...(options.idToBigComponents === undefined
      ? {}
      : { n_memory_id_to_big_components: options.idToBigComponents }),
  } as ResourceSummary;
}

describe("rawMaxComponentRows", () => {
  it("recovers the un-rounded count of the component the prover named", () => {
    const s = summary({ steps: 1_000, rows: 34_660 });
    expect(s.max_component_rows).toBe(65_536);
    expect(rawMaxComponentRows(s)).toEqual({ rows: 34_660, exact: true });
  });

  it("applies the /16 split of memory_address_to_id", () => {
    const s = summary({ steps: 1_000, rows: 10, addressToId: 16_000_000, component: "memory_address_to_id" });
    // 16 000 000 / 16 = 1 000 000 -> 2^20 rows
    expect(s.max_component_rows).toBe(2 ** 20);
    expect(rawMaxComponentRows(s)).toEqual({ rows: 1_000_000, exact: true });
  });

  it("falls back to the rounded value when the prover names a component it does not model", () => {
    const s = summary({ steps: 1, rows: 10 });
    const unknown = { ...s, max_component: "some_future_component", max_component_rows: 2 ** 19 };
    expect(rawMaxComponentRows(unknown)).toEqual({ rows: 2 ** 19, exact: false });
  });

  it("does not claim exactness from another component in the same rounded bucket", () => {
    const s = summary({ steps: 800_000, rows: 600_000 });
    const unknown = { ...s, max_component: "unknown_auxiliary", max_component_rows: 2 ** 20 };
    expect(rawMaxComponentRows(unknown)).toEqual({ rows: 2 ** 20, exact: false });
  });

  it("uses Blake G's real active count instead of a smaller opcode count", () => {
    const s = summary({ steps: 2_681_207, rows: 770_870 });
    const blake = {
      ...s,
      auxiliary_components: [["blake_round", 162_900], ["blake_g", 1_303_200], ["triple_xor_32", 130_320]] as [string, number][],
      max_component: "blake_g",
      max_component_rows: 2 ** 21,
      log_max_component_size: 21,
      fits_leaf_registry: false,
    };
    expect(rawMaxComponentRows(blake)).toEqual({ rows: 1_303_200, exact: true });
    const verdict = new SegmentPlanner().judge(4, blake, 4);
    expect(verdict.verdict).toBe("shrink");
    expect(verdict.utilisation).toBeCloseTo(1_303_200 / 2 ** 20);
  });

  it("keeps the 80 percent margin when an auxiliary shares an opcode's padded height", () => {
    const s = {
      ...summary({ steps: 900_000, rows: 600_000 }),
      auxiliary_components: [["some_counted_auxiliary", 950_000]] as [string, number][],
      max_component: "some_counted_auxiliary",
    };
    expect(rawMaxComponentRows(s)).toEqual({ rows: 950_000, exact: true });
    expect(new SegmentPlanner().judge(4, s, 4).verdict).toBe("shrink");
  });

  it("excludes memory address zero at a padding boundary", () => {
    const s = {
      ...summary({ steps: 1_000, rows: 1_024 }),
      memory_address_to_id: 16 * 1_024 + 1,
      max_component: "memory_address_to_id",
    };
    expect(rawMaxComponentRows(s)).toEqual({ rows: 1_024, exact: true });
  });
});

describe("SegmentPlanner.judge", () => {
  const planner = (over: Partial<typeof DEFAULT_PLANNER_CONFIG> = {}): SegmentPlanner =>
    new SegmentPlanner({ maxTics: 100_000, ...over });

  it("accepts a candidate under the row target and under the step ceiling", () => {
    const verdict = planner().judge(1000, summary({ steps: 800_000, rows: 700_000 }), 4);
    expect(verdict.verdict).toBe("accept");
    expect(verdict.utilisation).toBeCloseTo(700_000 / 2 ** 20, 6);
  });

  it("shrinks when the largest component is over the 80 % target", () => {
    const verdict = planner().judge(1000, summary({ steps: 100_000, rows: 1_000_000 }), 4);
    expect(verdict.verdict).toBe("shrink");
    if (verdict.verdict !== "shrink") throw new Error("unreachable");
    // 0.8 / (1e6 / 2^20) = 0.839 -> 0.797 after the 0.95 safety guard.
    expect(verdict.tics).toBeLessThan(1000);
    expect(verdict.tics).toBeGreaterThan(700);
    expect(verdict.reason).toMatch(/ceiling/);
  });

  it("shrinks when resources() says the segment does not fit the leaf registry", () => {
    // 2^21 rows: outside the current log20 registry (not every component needs Seq21).
    const verdict = planner().judge(2000, summary({ steps: 200_000, rows: 1_200_000 }), 1);
    expect(verdict.verdict).toBe("shrink");
    if (verdict.verdict !== "shrink") throw new Error("unreachable");
    expect(verdict.utilisation).toBeGreaterThan(1);
    expect(verdict.reason).toMatch(/leaf registry|ceiling/);
  });

  it("applies the 1.5 M step ceiling with threads and 2.3 M without (R1-A8)", () => {
    const threaded = planner().judge(1000, summary({ steps: 2_000_000, rows: 10_000 }), 4);
    expect(threaded.verdict).toBe("shrink");
    if (threaded.verdict !== "shrink") throw new Error("unreachable");
    expect(threaded.reason).toMatch(/R1-A8/);

    const single = planner().judge(1000, summary({ steps: 2_000_000, rows: 10_000 }), 1);
    expect(single.verdict).toBe("accept");
  });

  it("refuses more memory_id_to_big components than the leaf parameters force", () => {
    const verdict = planner().judge(
      1000,
      summary({ steps: 100_000, rows: 10_000, idToBigComponents: 32 }),
      1,
    );
    expect(verdict.verdict).toBe("shrink");
    if (verdict.verdict !== "shrink") throw new Error("unreachable");
    expect(verdict.reason).toMatch(/memory_id_to_big/);
  });

  it("says 'impossible' rather than shrinking below one tic", () => {
    const p = planner({ minTics: 1 });
    const verdict = p.judge(1, summary({ steps: 9_000_000, rows: 4_000_000 }), 1);
    expect(verdict.verdict).toBe("impossible");
  });
});

describe("SegmentPlanner.propose", () => {
  it("starts at initialTics with nothing measured", () => {
    const p = new SegmentPlanner({ initialTics: 64 });
    expect(p.propose(10_000, 4)).toBe(64);
  });

  it("never proposes more tics than the journal holds", () => {
    const p = new SegmentPlanner({ initialTics: 64 });
    expect(p.propose(10, 4)).toBe(10);
  });

  it("reads a single observation as a line through the origin — conservative", () => {
    const p = new SegmentPlanner({ initialTics: 64, maxGrowth: 1000, maxTics: 10 ** 9 });
    // 100 tics cost 171 000 steps and 34 000 rows: almost all of it fixed cost,
    // but with one point the planner cannot know that and assumes it scales.
    p.judge(100, summary({ steps: 171_000, rows: 34_000 }), 1);
    const k = p.propose(10 ** 9, 1);
    // rows: 0.8·2^20 / 340 = 2467; steps: 2.3e6 / 1710 = 1345 -> steps bind.
    expect(k).toBeGreaterThan(1000);
    expect(k).toBeLessThan(1400);
  });

  it("fits the affine model once two lengths have been measured", () => {
    const p = new SegmentPlanner({ initialTics: 64, maxGrowth: 10 ** 6, maxTics: 10 ** 9 });
    // The stub's real numbers: 174 689 steps at 70 tics, 205 648 at 700.
    p.judge(70, summary({ steps: 174_689, rows: 34_660 }), 1);
    p.judge(700, summary({ steps: 205_648, rows: 40_000 }), 1);
    const k = p.propose(10 ** 9, 1);
    // slope 49.1 steps/tic, intercept 171 250 -> (2.3e6 - 171k) / 49.1 = 43 400,
    // times the 0.95 guard.
    expect(k).toBeGreaterThan(35_000);
    expect(k).toBeLessThan(45_000);
  });

  it("bounds growth by maxGrowth so one lucky fit cannot overshoot", () => {
    const p = new SegmentPlanner({ initialTics: 64, maxGrowth: 4, maxTics: 10 ** 9 });
    p.judge(70, summary({ steps: 174_689, rows: 34_660 }), 1);
    p.judge(700, summary({ steps: 205_648, rows: 40_000 }), 1);
    expect(p.propose(10 ** 9, 1)).toBe(700 * 4);
  });

  it("respects the configured maxTics", () => {
    const p = new SegmentPlanner({ initialTics: 10_000, maxTics: 128 });
    expect(p.propose(10 ** 6, 1)).toBe(128);
  });
});

/**
 * Segment planner — how many tics go into one proof.
 *
 * Decision **D1** (revised by S4b and P3.1): a segment is *not* capped at 2^20
 * steps. The leaf registry is keyed on `trace_log_size`, which stays 20 as long
 * as **every AIR component stays under 2^20 rows**; the step count is only a
 * proxy, and a bad one — the ceiling of `steps_k` is 2.31 M steps while a
 * program with a different memory profile reaches it somewhere else entirely.
 * So the planner asks the prover (`resources()`), it does not count steps.
 *
 * ## The policy
 *
 * Two constraints, both hard:
 *
 * 1. **Rows.** `next_pow2(count_i) <= 2^20` for every AIR component, which is
 *    exactly `count_i <= 2^20` on the *raw* counters `resources()` returns.
 *    Working on the raw counts rather than on `max_component_rows` matters:
 *    the reported rows are already rounded to a power of two, so they only ever
 *    say "you are at 100 %, 50 %, 25 % …" — useless as a control signal. The
 *    raw counts give a continuous utilisation, and `nextPow2(raw) ===
 *    max_component_rows` is checked on every summary so the derivation cannot
 *    drift away from what the prover actually does (if it ever does, the planner
 *    falls back to the coarse rounded ratio, which is conservative).
 * 2. **Steps.** R1-A8: threaded proving hung twice in ~16 runs at >= 2 M steps
 *    in Chrome, so with threads a segment is capped at **1.5 M steps**. A
 *    single-threaded run — which has never failed, in all of S2 and P3.1 — gets
 *    the measured 2.3 M ceiling instead.
 *
 * Both are affine in the number of tics, so the planner keeps a two-point least
 * squares fit of `rows(k)` and `steps(k)` from the segments it has already
 * measured and solves for the largest `k` that lands at `targetUtilisation` of
 * the row ceiling and under the step ceiling. It then *verifies* that guess with
 * a real `execute()` + `resources()`, and shrinks if it was wrong. The model is
 * an accelerator, never an authority: nothing is proved that `resources()` has
 * not just approved.
 *
 * With no measurements at all the first proposal is `initialTics`, and a single
 * measurement is read as if the affine intercept were zero — which
 * under-estimates the slope's capacity for any program with a fixed cost (every
 * one of them: the leaf bootloader alone is ~4 881 steps), so the first guess is
 * short rather than over the ceiling. `maxGrowth` then bounds how fast it
 * catches up.
 */
import type { ResourceSummary } from "@hellproof/prover-wasm";

export interface PlannerConfig {
  /** Log2 of the row ceiling one AIR component may not cross (leaf registry: 20). */
  maxComponentLogSize: number;
  /** Fraction of that ceiling to aim at. 0.8 keeps the 20 % margin D1 asks for. */
  targetUtilisation: number;
  /** Hard step ceiling while proving with threads (R1-A8). */
  maxStepsThreaded: number;
  /** Hard step ceiling while proving single-threaded (P3.1's measured ceiling). */
  maxStepsSingleThread: number;
  /** `opt_n_id_to_big_components` of the leaf parameters; more than this cannot be proved. */
  maxIdToBigComponents: number;
  minTics: number;
  maxTics: number;
  /** First proposal, before anything has been measured. */
  initialTics: number;
  /** `execute()` probes per segment before the planner gives up and halves blindly. */
  maxProbes: number;
  /** Multiplicative guard on every model-derived proposal. */
  safety: number;
  /** A proposal may not exceed this many times the last accepted length. */
  maxGrowth: number;
  /** Observations kept for the fit. */
  historyLength: number;
}

export const DEFAULT_PLANNER_CONFIG: PlannerConfig = {
  maxComponentLogSize: 20,
  targetUtilisation: 0.8,
  maxStepsThreaded: 1_500_000,
  maxStepsSingleThread: 2_300_000,
  maxIdToBigComponents: 16,
  minTics: 1,
  maxTics: 8192,
  initialTics: 64,
  maxProbes: 4,
  safety: 0.95,
  maxGrowth: 8,
  historyLength: 16,
};

/** What the planner learned from one `execute()` + `resources()` probe. */
export interface PlannerObservation {
  tics: number;
  /** Largest AIR component, un-rounded. */
  rows: number;
  steps: number;
  /** False when `rows` had to be taken from the rounded `max_component_rows`. */
  exact: boolean;
}

export type PlannerVerdict =
  | { verdict: "accept"; utilisation: number; stepUtilisation: number }
  | {
      verdict: "shrink";
      /** The next candidate length to try. Always `< tics` and `>= minTics`. */
      tics: number;
      reason: string;
      utilisation: number;
      stepUtilisation: number;
    }
  | { verdict: "impossible"; reason: string; utilisation: number; stepUtilisation: number };

/** `next_pow2`, as the witness generators compute it. */
export function nextPow2(n: number): number {
  if (n <= 1) return 1;
  return 2 ** Math.ceil(Math.log2(n));
}

/**
 * The raw (un-rounded) row count of the largest AIR component.
 *
 * The transforms are the ones the README pins: `next_pow2(count)` per opcode and
 * for `verify_instruction`, `next_pow2(len / 16)` for `memory_address_to_id`
 * (`MEMORY_ADDRESS_TO_ID_SPLIT`), `next_pow2(len)` for `memory_id_to_small` —
 * the one that binds first for a memory-writing program. Builtin components are
 * counted at face value, which is right for the ones that get one row per
 * instance and conservative for the others.
 */
export function rawMaxComponentRows(summary: ResourceSummary): { rows: number; exact: boolean } {
  const candidates = new Map<string, number>();
  for (const [name, count] of summary.opcodes) candidates.set(name, count);
  for (const [name, count] of summary.builtins) candidates.set(name, count);
  candidates.set("verify_instruction", summary.verify_instruction);
  candidates.set("memory_address_to_id", summary.memory_address_to_id / 16);
  candidates.set("memory_id_to_small", summary.memory_id_to_small);

  const reported = summary.max_component_rows;
  const named = candidates.get(summary.max_component);
  if (named !== undefined && nextPow2(named) === reported) return { rows: named, exact: true };

  let best = 0;
  for (const value of candidates.values()) best = Math.max(best, value);
  if (best > 0 && nextPow2(best) === reported) return { rows: best, exact: true };

  // The prover knows a component we do not model. Fall back to its own rounded
  // number: coarser, never optimistic.
  return { rows: reported, exact: false };
}

export class SegmentPlanner {
  readonly config: PlannerConfig;
  private readonly history: PlannerObservation[] = [];
  private lastAccepted = 0;

  constructor(config: Partial<PlannerConfig> = {}) {
    this.config = { ...DEFAULT_PLANNER_CONFIG, ...config };
    if (this.config.targetUtilisation <= 0 || this.config.targetUtilisation > 1) {
      throw new RangeError("targetUtilisation must be in (0, 1]");
    }
  }

  /** The row ceiling, in rows. */
  get rowCeiling(): number {
    return 2 ** this.config.maxComponentLogSize;
  }

  /** The step ceiling that applies to a prove with this many threads (R1-A8). */
  stepCeiling(threads: number): number {
    return threads > 1 ? this.config.maxStepsThreaded : this.config.maxStepsSingleThread;
  }

  /** Everything measured so far, oldest first. Read by the diagnostics panel. */
  get observations(): readonly PlannerObservation[] {
    return this.history;
  }

  /**
   * The next candidate length, given how many unplanned tics are available and
   * how many threads the prove will use.
   *
   * `available` caps the answer: a segment never covers tics that have not been
   * played. The caller decides whether a short segment is worth cutting now (mid
   * game: wait for more) or not (end of game: flush).
   */
  propose(available: number, threads: number): number {
    const { minTics, maxTics, initialTics, safety, maxGrowth } = this.config;
    if (available <= 0) return 0;

    const rowsFit = this.fit("rows");
    const stepsFit = this.fit("steps");
    let k: number;
    if (!rowsFit || !stepsFit) {
      k = initialTics;
    } else {
      const kRows = (this.rowCeiling * this.config.targetUtilisation - rowsFit.intercept) / rowsFit.slope;
      const kSteps = (this.stepCeiling(threads) - stepsFit.intercept) / stepsFit.slope;
      k = Math.floor(Math.min(kRows, kSteps) * safety);
    }
    if (!Number.isFinite(k) || k < minTics) k = minTics;
    if (this.lastAccepted > 0) k = Math.min(k, this.lastAccepted * maxGrowth);
    k = Math.min(k, maxTics, available);
    return Math.max(Math.min(minTics, available), k);
  }

  /**
   * Reads a probe. Either the candidate is good — and the caller proves it — or
   * the planner says how much smaller to go and the caller probes again.
   */
  judge(tics: number, summary: ResourceSummary, threads: number): PlannerVerdict {
    const { rows, exact } = rawMaxComponentRows(summary);
    this.remember({ tics, rows, steps: summary.n_steps, exact });

    const ceiling = this.rowCeiling;
    const stepCeiling = this.stepCeiling(threads);
    const utilisation = rows / ceiling;
    const stepUtilisation = summary.n_steps / stepCeiling;
    const target = this.config.targetUtilisation;

    const reasons: string[] = [];
    let factor = 1;
    if (!summary.fits_leaf_registry) {
      reasons.push(
        `resources() says the segment does not fit the leaf registry (${summary.max_component} at 2^${summary.log_max_component_size} rows)`,
      );
      factor = Math.min(factor, target / Math.max(utilisation, target * 1.25));
    }
    if (utilisation > target) {
      reasons.push(
        `${summary.max_component} at ${Math.round(utilisation * 100)} % of the 2^${this.config.maxComponentLogSize}-row ceiling (target ${Math.round(target * 100)} %)`,
      );
      factor = Math.min(factor, target / utilisation);
    }
    if (stepUtilisation > 1) {
      reasons.push(
        `${summary.n_steps} steps over the ${stepCeiling}-step ceiling for ${threads} thread(s) (R1-A8)`,
      );
      factor = Math.min(factor, 1 / stepUtilisation);
    }
    // The README documents this counter; the package's `ResourceSummary` does not
    // declare it yet, so read it defensively rather than pinning a version.
    const idToBig =
      (summary as ResourceSummary & { n_memory_id_to_big_components?: number })
        .n_memory_id_to_big_components ?? 1;
    if (idToBig > this.config.maxIdToBigComponents) {
      reasons.push(
        `${idToBig} memory_id_to_big components, over the ${this.config.maxIdToBigComponents} the leaf parameters force`,
      );
      factor = Math.min(factor, this.config.maxIdToBigComponents / idToBig);
    }

    if (reasons.length === 0) {
      this.lastAccepted = tics;
      return { verdict: "accept", utilisation, stepUtilisation };
    }

    const reason = reasons.join("; ");
    if (tics <= this.config.minTics) {
      return { verdict: "impossible", reason, utilisation, stepUtilisation };
    }
    let next = Math.floor(tics * factor * this.config.safety);
    if (next >= tics) next = Math.floor(tics / 2);
    next = Math.max(this.config.minTics, Math.min(next, tics - 1));
    return { verdict: "shrink", tics: next, reason, utilisation, stepUtilisation };
  }

  /** Forgets the fit, e.g. after a program change. */
  reset(): void {
    this.history.length = 0;
    this.lastAccepted = 0;
  }

  private remember(observation: PlannerObservation): void {
    this.history.push(observation);
    while (this.history.length > this.config.historyLength) this.history.shift();
  }

  /**
   * Least squares over the observations. One observation is read as a line
   * through the origin, which understates the slope's capacity for any program
   * with a fixed cost and is therefore the safe reading.
   */
  private fit(key: "rows" | "steps"): { slope: number; intercept: number } | null {
    if (this.history.length === 0) return null;
    const points = this.history.map((o) => ({ x: o.tics, y: o[key] }));
    if (points.length === 1) {
      const only = points[0] as { x: number; y: number };
      if (only.x <= 0 || only.y <= 0) return null;
      return { slope: only.y / only.x, intercept: 0 };
    }
    const n = points.length;
    const meanX = points.reduce((s, p) => s + p.x, 0) / n;
    const meanY = points.reduce((s, p) => s + p.y, 0) / n;
    let num = 0;
    let den = 0;
    for (const p of points) {
      num += (p.x - meanX) * (p.y - meanY);
      den += (p.x - meanX) ** 2;
    }
    if (den === 0 || num <= 0) {
      // Every probe had the same length, or the measurement is not increasing in
      // it (noise on a tiny slope). Fall back to the through-the-origin reading
      // of the most recent point.
      const last = points[points.length - 1] as { x: number; y: number };
      if (last.x <= 0 || last.y <= 0) return null;
      return { slope: last.y / last.x, intercept: 0 };
    }
    const slope = num / den;
    return { slope, intercept: meanY - slope * meanX };
  }
}

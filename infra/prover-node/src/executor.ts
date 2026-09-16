// SPDX-License-Identifier: Apache-2.0
/**
 * `Executor` — the seam between the pipeline and the Cairo runtime that replays a journal.
 *
 * It exposes the three `doom_run` executables of `cairo/doom/doom_run/README.md` ("Flat felt
 * ABI"): `genesis` for the serialized start state, `step_tic` to advance that state between two
 * segments (only `h_out`, a hash, comes out of `run_segment`, so the next segment's start state
 * has to be replayed), and `run_segment` for the ten public felts (D14) and the resource
 * measurement that decides whether the candidate segment fits (D26).
 *
 * The real implementation is a subprocess (`scarbExecutor.ts`); `FakeExecutor` is the test
 * double — a deterministic toy game with the same ABI, hashes and commitments, whose cost model
 * is the one measured in `docs/ORCHESTRATOR-HANDOFF.md` (≈ 440 k fixed steps per segment,
 * ≈ 41 k steps per tic after O1).
 */
import type { ResourceSummary } from "@hellproof/prover-wasm";
import { hash } from "starknet";

import { checkState, checkedWords, stepArgs } from "../../../client/src/prove/doomPreparation.js";
import { normalizeFelt, toFelt } from "../../../client/src/prove/felt.js";
import { nextPow2 } from "../../../client/src/prove/planner.js";
import { decodeSegmentOutput } from "../../../client/src/prove/program.js";
import { SegmentStatus, type Felt, type SegmentOutput } from "../../../client/src/prove/types.js";
import { commitWords } from "./commitment.js";

export interface GenesisResult {
  /** The serialized `doom_game` schema-2 state, as felts. */
  state: Felt[];
  /** `Poseidon(state)` — the `h_in` of segment 0. */
  hash: Felt;
}

export interface StepResult {
  /** 0 RUNNING, 1 DEAD, 2 EXIT, 3 ABORT. */
  status: number;
  state: Felt[];
}

export interface SegmentExecution {
  /** The full `run_segment` argument vector — what the prover proves. */
  args: Felt[];
  /** The ten public felts, as returned. */
  outputFelts: Felt[];
  output: SegmentOutput;
  nSteps: number;
  /**
   * AIR sizing when the runtime measures it (the browser's `resources()`); `null` for a
   * steps-only runtime, in which case only the D26 step ceiling constrains the cut.
   */
  resources: ResourceSummary | null;
  ms: number;
}

export interface Executor {
  readonly id: string;
  genesis(levelId: number): Promise<GenesisResult>;
  step(state: readonly Felt[], words: readonly number[]): Promise<StepResult>;
  segment(
    state: readonly Felt[],
    words: readonly number[],
    ticStart: number,
    maxTics: number,
  ): Promise<SegmentExecution>;
}

/** `run_segment`'s argument vector: `[state_len, state…, words_len, words…, tic_start, max_tics]`. */
export function segmentArgs(
  state: readonly Felt[],
  words: readonly number[],
  ticStart: number,
  maxTics: number,
): Felt[] {
  checkedWords(words);
  return [...stepArgs(state, words), toFelt(ticStart), toFelt(maxTics)];
}

/**
 * A `ResourceSummary` carrying only a step count: every row-related field is minimal, so the
 * planner's row rule never binds and the D26 step ceiling is the only constraint. Used when the
 * runtime cannot size the AIR; the segment record says so (`rowsChecked: false`).
 */
export function stepsOnlySummary(nSteps: number): ResourceSummary {
  return {
    n_steps: nSteps,
    opcodes: [],
    builtins: [],
    unique_aggregator_inputs: [],
    memory_address_to_id: 0,
    memory_id_to_big: 0,
    memory_id_to_small: 0,
    verify_instruction: 0,
    auxiliary_components: [],
    max_component_rows: 16,
    max_component: "steps-only",
    log_max_component_size: 4,
    fits_leaf_registry: true,
    n_memory_id_to_big_components: 1,
  };
}

// --- the deterministic test double -------------------------------------------------------

export interface FakeExecutorOptions {
  /** Steps charged per segment before the first tic (parser, serialisation, two Poseidon). */
  fixedSteps?: number;
  stepsPerTic?: number;
  /** Ends the game at this tic with `DEAD` (1) or `EXIT` (2). */
  terminal?: { tic: number; status: 1 | 2 };
  /** Whether `segment()` reports AIR sizing (`full`) or only steps (`steps-only`). */
  resources?: "full" | "steps-only";
  /** The row count of the largest component, as a fraction of the step count. */
  rowsPerStep?: number;
  /** Log2 of the registry's row limit the fake reports `fits_leaf_registry` against (20). */
  registryLogSize?: number;
}

const STATE_TAG = 0x48502e5354415445n; // 'HP.STATE'
const STATE_LEN = 47;
const MASK64 = (1n << 64n) - 1n;

/** Toy game with the real ABI: 47-felt schema-2 state, Poseidon state hash, D13 commitment. */
export class FakeExecutor implements Executor {
  readonly id = "fake";
  readonly calls: { op: "genesis" | "step" | "segment"; ticStart: number; tics: number }[] = [];
  private readonly fixedSteps: number;
  private readonly stepsPerTic: number;
  private readonly terminal: { tic: number; status: 1 | 2 } | null;
  private readonly mode: "full" | "steps-only";
  private readonly rowsPerStep: number;
  private readonly registryRows: number;

  constructor(options: FakeExecutorOptions = {}) {
    this.fixedSteps = options.fixedSteps ?? 440_000;
    this.stepsPerTic = options.stepsPerTic ?? 41_385;
    this.terminal = options.terminal ?? null;
    this.mode = options.resources ?? "full";
    this.rowsPerStep = options.rowsPerStep ?? 0.35;
    this.registryRows = 2 ** (options.registryLogSize ?? 20);
  }

  private static hashState(state: readonly Felt[]): Felt {
    return normalizeFelt(hash.computePoseidonHashOnElements(state.map((f) => BigInt(f))));
  }

  async genesis(levelId: number): Promise<GenesisResult> {
    this.calls.push({ op: "genesis", ticStart: 0, tics: 0 });
    const state = new Array<bigint>(STATE_LEN).fill(0n);
    state[0] = STATE_TAG;
    state[1] = 2n;
    state[2] = BigInt(STATE_LEN - 3);
    state[3] = BigInt(levelId);
    const felts = state.map((v) => toFelt(v));
    return { state: felts, hash: FakeExecutor.hashState(felts) };
  }

  /** Applies words until a terminal status; returns the consumed count. */
  private play(state: bigint[], words: readonly number[]): number {
    let consumed = 0;
    for (const word of words) {
      if (state[5] !== 0n) break;
      consumed++;
      const tic = Number(state[4]!) + 1;
      state[4] = BigInt(tic);
      state[9] = (state[9]! * 31n + BigInt(word >>> 0)) & MASK64;
      if ((word >>> 24) & 1 && tic % 30 === 0) state[6] = state[6]! + 1n; // kills
      state[7] = BigInt(Math.floor(tic / 100)); // items
      if (word === 0xffffffff) {
        state[5] = 3n; // an invalid command aborts
      } else if (this.terminal && tic === this.terminal.tic) {
        state[5] = BigInt(this.terminal.status);
      }
    }
    return consumed;
  }

  async step(state: readonly Felt[], words: readonly number[]): Promise<StepResult> {
    checkState(state);
    checkedWords(words);
    this.calls.push({ op: "step", ticStart: Number(BigInt(state[4]!)), tics: words.length });
    const next = state.map((f) => BigInt(f));
    this.play(next, words);
    return { status: Number(next[5]), state: next.map((v) => toFelt(v)) };
  }

  async segment(
    state: readonly Felt[],
    words: readonly number[],
    ticStart: number,
    maxTics: number,
  ): Promise<SegmentExecution> {
    const t0 = performance.now();
    const args = segmentArgs(state, words, ticStart, maxTics);
    this.calls.push({ op: "segment", ticStart, tics: Math.min(words.length, maxTics) });
    const hIn = FakeExecutor.hashState(state);
    const next = state.map((f) => BigInt(f));
    let status: number;
    let consumed = 0;
    if (Number(next[4]) !== ticStart) {
      status = SegmentStatus.ABORT; // tic_start must match the state clock (README)
    } else {
      consumed = this.play(next, words.slice(0, maxTics));
      status = Number(next[5]);
    }
    const hOut = FakeExecutor.hashState(next.map((v) => toFelt(v)));
    const outputFelts: Felt[] = [
      toFelt(1),
      hIn,
      hOut,
      toFelt(ticStart),
      toFelt(ticStart + consumed),
      toFelt(status),
      toFelt(commitWords(words.slice(0, consumed))),
      toFelt(next[6]!),
      toFelt(next[7]!),
      toFelt(next[8]!),
    ];
    const nSteps = this.fixedSteps + this.stepsPerTic * consumed;
    const rows = Math.round(nSteps * this.rowsPerStep);
    const resources: ResourceSummary | null =
      this.mode === "steps-only"
        ? null
        : {
            n_steps: nSteps,
            opcodes: [["generic_opcode", rows], ["add_opcode", Math.round(rows / 3)]],
            builtins: [["range_check_builtin", Math.round(nSteps / 8)]],
            unique_aggregator_inputs: [],
            memory_address_to_id: Math.round(nSteps / 2),
            memory_id_to_big: Math.round(nSteps / 10),
            memory_id_to_small: Math.round(rows / 2),
            verify_instruction: Math.round(rows / 2),
            auxiliary_components: [["poseidon_round", Math.round(rows / 20)]],
            max_component_rows: nextPow2(Math.max(16, rows)),
            max_component: "generic_opcode",
            log_max_component_size: Math.log2(nextPow2(Math.max(16, rows))),
            fits_leaf_registry: rows <= this.registryRows,
            n_memory_id_to_big_components: 1,
          };
    return {
      args,
      outputFelts,
      output: decodeSegmentOutput(outputFelts),
      nSteps,
      resources,
      ms: performance.now() - t0,
    };
  }
}

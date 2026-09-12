// SPDX-License-Identifier: Apache-2.0
/**
 * The router's transaction plan: which proof sections travel in which transaction, and the
 * exact calldata of each one.
 *
 * Port of the `tx_*` / `plan` half of `cairo/doom_contracts/tools/emit_calldata.py` plus the
 * `calldata_for` of `tools/devnet_drive.py` — the two live in different Python files because the
 * emitter cannot know the checkpoint echo (it is the *return value* of the previous
 * transaction), and that split survives here: `planPhases` is pure and offline,
 * `phaseCalldata(phase, echo)` needs the echo of the phase before it.
 *
 * Plan shapes (`onchain-verifier.md` §3):
 *   begin(head, trees 0+1) → merkle(trees 2+3) → answers(sampled + the 4 queried sets)
 *   → fri(layers …) × 2 or 3
 * The FRI cut is the only degree of freedom: `--fri-split 2` gives 5 transactions (worst at
 * 90.4 % of the invoke cap), `1,3` gives 6 (worst 84.0 %, the R7-A5-clean plan).
 */

import {
  DEFAULT_MAX_CALLDATA,
  FRI_STATE_FELTS,
  MERKLE_STATE_FELTS,
  packSections,
  packU32,
  pack,
  type ProofSections,
} from "./proof.js";

export type PhaseEntrypoint = "begin" | "merkle" | "answers" | "fri";
/** Which checkpoint the phase echoes back; `null` for `begin`, which starts the sequence. */
export type EchoKind = "merkle_state" | "fri_state" | null;

export interface PhasePlan {
  /** Stable label used by receipts, the estimator and the UI (`begin`, `fri1`, …). */
  label: string;
  entrypoint: PhaseEntrypoint;
  echo: EchoKind;
  /** Predicted calldata length, echo included — asserted against the cap at plan time. */
  calldataFelts: number;
  /** Packed felt252 slots carried by this transaction (payload + head). */
  payloadSlots: number;
  proofId: bigint;
  /** Packed head, `begin` only. */
  head?: bigint[];
  /** Unpacked head length, needed to drive the escaped decoder. */
  headN?: number;
  payload: bigint[];
  /** Unpacked lengths of the sections inside `payload`, in order. */
  lens?: number[];
  /** Merkle tree indices carried, `begin` / `merkle` only. */
  trees?: number[];
  /** Unpacked value count of the FRI chunk, `fri` only. */
  nValues?: number;
  /** What travels in this transaction, for the UI and the receipts. */
  meta: { sections?: string[]; layers?: number[] };
}

export interface PlanOptions {
  proofId?: bigint;
  /**
   * Layer indices where the FRI walk is cut, e.g. `[2]` (5 tx) or `[1, 3]` (6 tx). The walk is
   * chunkable at any layer boundary; the plan asserts the calldata cap afterwards.
   */
  friSplit?: number[];
  maxCalldata?: number;
}

function txBegin(sec: ProofSections, trees: number[], proofId: bigint): PhasePlan {
  const head = pack(sec.head);
  const sections = trees.flatMap((t) => [sec.queriedValues[t]!, sec.decommitments[t]!]);
  const payload = packSections(sections);
  return {
    label: "begin",
    entrypoint: "begin",
    echo: null,
    proofId,
    head,
    headN: sec.head.length,
    payload,
    lens: sections.map((s) => s.length),
    trees,
    calldataFelts:
      1 + 1 + head.length + 1 + 1 + payload.length + 1 + sections.length + 1 + trees.length,
    payloadSlots: head.length + payload.length,
    meta: { sections: ["head", ...trees.map((t) => `qv${t}/dec${t}`)] },
  };
}

function txMerkle(sec: ProofSections, trees: number[], proofId: bigint): PhasePlan {
  const sections = trees.flatMap((t) => [sec.queriedValues[t]!, sec.decommitments[t]!]);
  const payload = packSections(sections);
  return {
    label: "merkle",
    entrypoint: "merkle",
    echo: "merkle_state",
    proofId,
    payload,
    lens: sections.map((s) => s.length),
    trees,
    calldataFelts:
      1 + 1 + MERKLE_STATE_FELTS + 1 + payload.length + 1 + sections.length + 1 + trees.length,
    payloadSlots: payload.length,
    meta: { sections: trees.map((t) => `qv${t}/dec${t}`) },
  };
}

function txAnswers(sec: ProofSections, proofId: bigint): PhasePlan {
  const sections = [sec.sampled, ...sec.queriedValues];
  const payload = packSections(sections);
  return {
    label: "answers",
    entrypoint: "answers",
    echo: "merkle_state",
    proofId,
    payload,
    lens: sections.map((s) => s.length),
    calldataFelts: 1 + 1 + MERKLE_STATE_FELTS + 1 + payload.length + 1 + sections.length,
    payloadSlots: payload.length,
    meta: { sections: ["sampled", "qv0", "qv1", "qv2", "qv3"] },
  };
}

function txFri(sec: ProofSections, first: number, last: number, proofId: bigint, idx: number): PhasePlan {
  const layers = sec.layers.slice(first, last);
  const flat = [BigInt(layers.length), ...layers.flat()];
  const payload = packU32(flat);
  return {
    label: `fri${idx}`,
    entrypoint: "fri",
    echo: "fri_state",
    proofId,
    payload,
    nValues: flat.length,
    calldataFelts: 1 + 1 + FRI_STATE_FELTS + 1 + payload.length + 1,
    payloadSlots: payload.length,
    meta: { layers: Array.from({ length: last - first }, (_, i) => first + i) },
  };
}

/** The ordered router transactions for one root proof. Pure: no RPC, no echo. */
export function planPhases(sec: ProofSections, options: PlanOptions = {}): PhasePlan[] {
  const proofId = options.proofId ?? 1n;
  const maxCalldata = options.maxCalldata ?? DEFAULT_MAX_CALLDATA;
  const nLayers = sec.layers.length;
  const cuts = [...new Set(options.friSplit ?? [2])]
    .filter((c) => c > 0 && c < nLayers)
    .sort((a, b) => a - b);
  const bounds = [0, ...cuts, nLayers];

  const phases: PhasePlan[] = [
    txBegin(sec, [0, 1], proofId),
    txMerkle(sec, [2, 3], proofId),
    txAnswers(sec, proofId),
  ];
  for (let i = 0; i < bounds.length - 1; i++) {
    phases.push(txFri(sec, bounds[i]!, bounds[i + 1]!, proofId, i + 1));
  }
  for (const p of phases) {
    if (p.calldataFelts > maxCalldata) {
      throw new Error(
        `${p.label}: ${p.calldataFelts} calldata felts > ${maxCalldata}; re-plan ` +
          `(a different friSplit, or another Merkle tree split)`,
      );
    }
  }
  return phases;
}

/**
 * The default plan: **six** transactions (`friSplit = [1, 3]`), falling back to other cuts when
 * a section does not fit the calldata cap.
 *
 * Why not the five-transaction plan, which is what P4.0 measured and 0.3 % cheaper: its `fri1`
 * consumes 90.3 % of the 1.21e9 invoke cap, and a *bound* is what the sequencer checks, so the
 * R7-A1 margin turns it into 1.257e9 — **over the cap, rejected before execution** (measured in
 * P4.3, `docs/design/submission.md` §4). The 5-tx plan is only sendable with a margin below
 * ×1.107, which is not a margin. `preferFewestTransactions` selects it anyway, for measurement.
 */
export function planPhasesAuto(
  sec: ProofSections,
  options: PlanOptions & { preferFewestTransactions?: boolean } = {},
): PhasePlan[] {
  const candidates = options.preferFewestTransactions
    ? [[2], [1, 3], [1, 2, 4]]
    : [[1, 3], [1, 2, 4], [2]];
  let last: unknown;
  for (const friSplit of candidates) {
    try {
      return planPhases(sec, { ...options, friSplit });
    } catch (e) {
      last = e;
    }
  }
  throw last;
}

const hex = (v: bigint | number): string =>
  "0x" + (typeof v === "bigint" ? v : BigInt(v)).toString(16);

/** A `Span<felt252>` in calldata: the length then the values. */
const span = (values: (bigint | number | string)[]): string[] => [
  hex(values.length),
  ...values.map((v) => (typeof v === "string" ? v : hex(v))),
];

/**
 * The calldata of one phase. `echo` is the checkpoint state the previous transaction returned
 * (its retdata, as 0x felts); `begin` takes `null`.
 */
export function phaseCalldata(phase: PhasePlan, echo: string[] | null): string[] {
  const cd: string[] = [hex(phase.proofId)];
  if (phase.entrypoint === "begin") {
    cd.push(...span(phase.head!), hex(phase.headN!));
  } else {
    if (!echo) throw new Error(`${phase.label}: missing state echo`);
    cd.push(...span(echo));
  }
  cd.push(...span(phase.payload));
  if (phase.entrypoint !== "fri") cd.push(...span(phase.lens!));
  if (phase.entrypoint === "begin" || phase.entrypoint === "merkle") cd.push(...span(phase.trees!));
  if (phase.entrypoint === "fri") cd.push(hex(phase.nValues!));
  return cd;
}

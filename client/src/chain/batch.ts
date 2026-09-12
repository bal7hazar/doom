// SPDX-License-Identifier: Apache-2.0
/**
 * A wrapper batch as `DoomRuns` wants it: the ten-felt leaves in fold order, the members that
 * map games onto contiguous leaf ranges, and the optional replay logs.
 *
 * The inputs are exactly what `GET /v1/batches/{id}` returns (`prover/wrapper/README.md`):
 * `leaves[]` is the fold order (`position`, `run_id`, `segment_index`), `packed_output` is the
 * recursive tree whose `Plain` nodes carry each leaf's `output_preimage`
 * (`[program_hash, out_0 … out_9]`, D14), and `root_proof_felts` is the proof the router
 * verifies. Nothing here touches the filesystem or the network, so the same code runs in the
 * browser and in `infra/submit`.
 *
 * Open question 2 of `docs/design/doomruns.md` §12 is answered here and not on chain: a game
 * whose leaf positions are not contiguous is refused *before* paying, because the contract
 * would reject it as a chain break after the 5 verifier transactions were already paid for.
 */

/** The ten public felts of a segment (D14), in `Serde` order. */
export interface LeafOutput {
  version: bigint;
  h_in: bigint;
  h_out: bigint;
  tic_start: bigint;
  tic_end: bigint;
  status: bigint;
  inputs_commitment: bigint;
  kills: bigint;
  items: bigint;
  secrets: bigint;
}

export const LEAF_FIELDS = [
  "version",
  "h_in",
  "h_out",
  "tic_start",
  "tic_end",
  "status",
  "inputs_commitment",
  "kills",
  "items",
  "secrets",
] as const satisfies readonly (keyof LeafOutput)[];

/** `status` values of D14. `ABORT` is a provably invalid execution and is rejected on chain. */
export const STATUS = { RUNNING: 0n, DEAD: 1n, EXIT: 2n, ABORT: 3n } as const;

/** `Member` — a half-open range of leaf positions in fold order, plus the recorded player. */
export interface Member {
  player: string;
  levelId: number;
  leafStart: number;
  leafLen: number;
  /** Bookkeeping only: the wrapper run this member came from. Not sent on chain. */
  runId?: string;
}

/** `ReplayLog` — one segment's packed input log (7 tics per felt, D13 / R10-A3). */
export interface ReplayLog {
  leafIndex: number;
  packed: bigint[];
}

/** One row of the wrapper's `leaves[]`: the fold order, left to right. */
export interface LeafPlacement {
  position: number;
  runId: string;
  segmentIndex: number;
  leafKey?: string;
}

export interface WrapperBatch {
  batchId: string;
  /** The fold order — index i of `leaves` is leaf position i. */
  placements: LeafPlacement[];
  leaves: LeafOutput[];
  /** `preimage[0]`, shared by every leaf: the executable that produced the segments. */
  programHash: bigint;
  /** The leaf verifier circuit hash (8 u32 words) of the registry. */
  leafCircuitHash: number[];
  /** The root node's circuit hash — the first half of the fact. */
  multiverifierHash: number[];
  /** The root proof felts, when the response was fetched with `?include=proof`. */
  rootProofFelts?: bigint[];
  /** Packed input logs per leaf position, when the client holds them. */
  logs?: bigint[][];
}

type PackedNode = {
  Composite?: { circuit_hash: number[]; subtasks: PackedNode[] };
  Plain?: { output_preimage: (string | number)[] };
};

/**
 * Walks `packed_output` and returns the leaf preimages in fold order plus the two circuit
 * hashes. Port of `tools/real_batch.py::walk`: a `Composite` whose single subtask is a `Plain`
 * *is* a leaf (its circuit hash is the leaf verifier's), every other `Composite` is a fold.
 */
export function walkPackedOutput(root: PackedNode): {
  preimages: bigint[][];
  leafCircuitHash: number[];
  multiverifierHash: number[];
} {
  const preimages: bigint[][] = [];
  const leafHashes: string[] = [];
  const mvHashes: string[] = [];
  const leafHashValues: number[][] = [];
  const mvHashValues: number[][] = [];

  const walk = (node: PackedNode): void => {
    const comp = node.Composite;
    if (!comp) throw new Error("packed_output: expected a Composite node");
    const subs = comp.subtasks;
    if (subs.length === 1 && subs[0]!.Plain) {
      leafHashes.push(comp.circuit_hash.join(","));
      leafHashValues.push(comp.circuit_hash);
      preimages.push(subs[0]!.Plain!.output_preimage.map((x) => BigInt(x)));
      return;
    }
    mvHashes.push(comp.circuit_hash.join(","));
    mvHashValues.push(comp.circuit_hash);
    for (const sub of subs) walk(sub);
  };
  walk(root);

  if (new Set(leafHashes).size !== 1) throw new Error("leaves do not share one leaf circuit hash");
  if (new Set(mvHashes).size !== 1) throw new Error("folds do not share one multiverifier hash");
  return {
    preimages,
    leafCircuitHash: leafHashValues[0]!,
    multiverifierHash: mvHashValues[0]!,
  };
}

/** `[program_hash, out_0 … out_9]` → the ten-felt leaf. */
export function leafFromPreimage(preimage: bigint[]): { programHash: bigint; leaf: LeafOutput } {
  if (preimage.length !== 11) {
    throw new Error(`leaf preimage is ${preimage.length} felts, expected 1 + 10 (D14)`);
  }
  const leaf = {} as LeafOutput;
  LEAF_FIELDS.forEach((f, i) => {
    leaf[f] = preimage[i + 1]!;
  });
  return { programHash: preimage[0]!, leaf };
}

/** The JSON shape of `GET /v1/batches/{id}` that this module reads. */
export interface BatchResponse {
  batch_id?: string;
  leaves?: { position: number; run_id: string; segment_index: number; leaf_key?: string }[];
  packed_output: PackedNode;
  root_proof_felts?: (string | number)[];
  /** Not part of the wrapper response: the packed input logs, held by the client per segment. */
  logs?: (string | number)[][];
}

/** Parses a wrapper batch response into everything the submission needs. */
export function parseWrapperBatch(doc: BatchResponse): WrapperBatch {
  const { preimages, leafCircuitHash, multiverifierHash } = walkPackedOutput(doc.packed_output);
  const parsed = preimages.map(leafFromPreimage);
  const programHashes = new Set(parsed.map((p) => p.programHash.toString()));
  if (programHashes.size !== 1) throw new Error(`several program hashes: ${[...programHashes]}`);

  const placements: LeafPlacement[] =
    doc.leaves?.map((l) => ({
      position: l.position,
      runId: l.run_id,
      segmentIndex: l.segment_index,
      ...(l.leaf_key === undefined ? {} : { leaf_key: l.leaf_key }),
    })) ?? parsed.map((_, i) => ({ position: i, runId: "unknown", segmentIndex: i }));
  if (placements.length !== parsed.length) {
    throw new Error(
      `leaves[] has ${placements.length} entries, packed_output has ${parsed.length} leaves`,
    );
  }
  for (const [i, p] of placements.entries()) {
    if (p.position !== i) throw new Error(`leaves[${i}].position is ${p.position}, not ${i}`);
  }

  return {
    batchId: doc.batch_id ?? "",
    placements,
    leaves: parsed.map((p) => p.leaf),
    programHash: parsed[0]!.programHash,
    leafCircuitHash,
    multiverifierHash,
    ...(doc.root_proof_felts ? { rootProofFelts: doc.root_proof_felts.map((x) => BigInt(x)) } : {}),
    ...(doc.logs ? { logs: doc.logs.map((l) => l.map((x) => BigInt(x))) } : {}),
  };
}

export interface MemberOptions {
  /** Address recorded as the player of each wrapper run. Missing runs are skipped. */
  players: Record<string, string>;
  /** `(version, level)` the run belongs to — the wrapper returns it with the batch. */
  levelIds: Record<string, number>;
  /** Default level for runs absent from `levelIds`. */
  defaultLevelId?: number;
}

/**
 * Groups the fold order into `Member` ranges, one per wrapper run.
 *
 * Refuses a run whose positions are not contiguous or not in segment order: the contract would
 * reject it as a chain break (`h_out[i] != h_in[i+1]`) *after* the whole fact was paid for. The
 * wrapper is supposed to guarantee contiguity at fold time; this is the client-side check that
 * the guarantee held.
 */
export function membersFromPlacements(
  placements: LeafPlacement[],
  options: MemberOptions,
): Member[] {
  const byRun = new Map<string, LeafPlacement[]>();
  for (const p of placements) {
    const list = byRun.get(p.runId);
    if (list) list.push(p);
    else byRun.set(p.runId, [p]);
  }

  const members: Member[] = [];
  for (const [runId, own] of byRun) {
    own.sort((a, b) => a.position - b.position);
    const start = own[0]!.position;
    for (const [i, p] of own.entries()) {
      if (p.position !== start + i) {
        throw new Error(
          `run ${runId}: leaf positions ${own.map((x) => x.position).join(",")} are not ` +
            `contiguous — the batch cannot be submitted (doomruns.md §12 q2)`,
        );
      }
      if (p.segmentIndex !== i) {
        throw new Error(
          `run ${runId}: leaf at position ${p.position} is segment ${p.segmentIndex}, ` +
            `expected ${i} — the fold order must be segment order`,
        );
      }
    }
    const player = options.players[runId];
    if (!player) continue; // a run nobody claims: its leaves still travel, no member is recorded
    members.push({
      player,
      levelId: options.levelIds[runId] ?? options.defaultLevelId ?? 0,
      leafStart: start,
      leafLen: own.length,
      runId,
    });
  }
  members.sort((a, b) => a.leafStart - b.leafStart);
  return members;
}

export interface SubmitBatchArgs {
  versionId: number;
  leaves: LeafOutput[];
  members: Member[];
  /** Replay logs to publish (R10-A3). Empty = no publication, ~24 % cheaper. */
  replay?: ReplayLog[];
}

const hex = (v: bigint | number | string): string =>
  typeof v === "string" ? (v.startsWith("0x") ? v : "0x" + BigInt(v).toString(16)) : "0x" + BigInt(v).toString(16);

/** Serializes `submit_batch(version_id, leaves, members, replay)`. */
export function submitBatchCalldata(args: SubmitBatchArgs): string[] {
  const words: string[] = [hex(args.versionId), hex(args.leaves.length)];
  for (const leaf of args.leaves) for (const f of LEAF_FIELDS) words.push(hex(leaf[f]));
  words.push(hex(args.members.length));
  for (const m of args.members) {
    words.push(hex(m.player), hex(m.levelId), hex(m.leafStart), hex(m.leafLen));
  }
  const replay = args.replay ?? [];
  words.push(hex(replay.length));
  for (const r of replay) {
    words.push(hex(r.leafIndex), hex(r.packed.length), ...r.packed.map(hex));
  }
  return words;
}

/** Serializes `register_member(version_id, leaves, member, replay)` — the per-player fallback. */
export function registerMemberCalldata(args: Omit<SubmitBatchArgs, "members"> & { member: Member }): string[] {
  const words: string[] = [hex(args.versionId), hex(args.leaves.length)];
  for (const leaf of args.leaves) for (const f of LEAF_FIELDS) words.push(hex(leaf[f]));
  const m = args.member;
  words.push(hex(m.player), hex(m.levelId), hex(m.leafStart), hex(m.leafLen));
  const replay = args.replay ?? [];
  words.push(hex(replay.length));
  for (const r of replay) {
    words.push(hex(r.leafIndex), hex(r.packed.length), ...r.packed.map(hex));
  }
  return words;
}

/**
 * The replay logs covering exactly the leaves the members claim, in position order — what the
 * drive publishes and what the contract checks against each segment's `inputs_commitment`.
 */
export function replayFor(members: Member[], logs: bigint[][]): ReplayLog[] {
  const covered: ReplayLog[] = [];
  for (const m of members) {
    for (let i = m.leafStart; i < m.leafStart + m.leafLen; i++) {
      const packed = logs[i];
      if (!packed) throw new Error(`no packed input log for leaf ${i}`);
      covered.push({ leafIndex: i, packed });
    }
  }
  return covered;
}

/** `submit_batch` reverts wholesale on a batch-level failure; these are the cheap pre-checks. */
export function checkBatch(batch: WrapperBatch, members: Member[], genesis?: bigint): string[] {
  const problems: string[] = [];
  for (const [i, leaf] of batch.leaves.entries()) {
    if (leaf.status === STATUS.ABORT) problems.push(`leaf ${i}: status ABORT (D14) is rejected`);
    if (leaf.version !== 1n) problems.push(`leaf ${i}: version ${leaf.version}, expected 1`);
  }
  for (const m of members) {
    const own = batch.leaves.slice(m.leafStart, m.leafStart + m.leafLen);
    if (own.length !== m.leafLen) {
      problems.push(`member ${m.runId ?? m.leafStart}: range runs past the leaves`);
      continue;
    }
    if (genesis !== undefined && own[0]!.h_in !== genesis) {
      problems.push(`member ${m.runId ?? m.leafStart}: h_in is not the pinned genesis`);
    }
    for (let i = 0; i + 1 < own.length; i++) {
      if (own[i]!.h_out !== own[i + 1]!.h_in) {
        problems.push(`member ${m.runId ?? m.leafStart}: chain break between segments ${i}/${i + 1}`);
      }
      if (own[i]!.tic_end !== own[i + 1]!.tic_start) {
        problems.push(`member ${m.runId ?? m.leafStart}: tic break between segments ${i}/${i + 1}`);
      }
    }
    const last = own[own.length - 1]!;
    if (last.status !== STATUS.EXIT && last.status !== STATUS.DEAD) {
      problems.push(
        `member ${m.runId ?? m.leafStart}: last segment is ${last.status}, ` +
          `neither EXIT (a run) nor DEAD (an attempt)`,
      );
    }
  }
  return problems;
}

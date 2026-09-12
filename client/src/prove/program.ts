/**
 * The **segment program** seam: everything the pipeline needs to know about the
 * Cairo executable it proves, and nothing else.
 *
 * Today the only implementation is the stand-in `segment_stub10`
 * (`spikes/s4/programs/segment_stub10`), which returns the real ten-felt output
 * of decision **D14** over a synthetic input log. When `doom_run` exists it
 * drops in here: a different `*.executable.json`, a different
 * {@link SegmentProgram.encodeArgs}, the same {@link decodeSegmentOutput} — the
 * output layout is the contract, and it is already the final one.
 */
import { feltToNumber, normalizeFelt, toFelt } from "./felt.js";
import { SEGMENT_OUTPUT_FELTS, SEGMENT_OUTPUT_VERSION, type Felt, type SegmentOutput } from "./types.js";

/** What the pipeline hands a program when it wants one segment's arguments. */
export interface SegmentRequest {
  /** State hash the segment starts from (`h_in`); the genesis for segment 0. */
  hIn: Felt;
  /** Absolute tic index of the first tic of the segment. */
  ticStart: number;
  /** Number of tics the planner wants in this segment. */
  ticCount: number;
  /** The segment's own slice of the journal, as 32-bit `ticcmd` words. */
  words: readonly number[];
  /** 0-based position of the segment in the run. */
  index: number;
}

export interface SegmentProgram {
  /** The program id the wrapper has pinned (`segment_stub10`, later `doom_run`). */
  readonly id: string;
  /** Which hash the leaf bootloader computes the program hash with (G0 **D4**). */
  readonly hashFunction: "blake" | "poseidon";
  /** `h_in` of the first segment of a fresh run. */
  readonly genesis: Felt;
  /** The Scarb `*.executable.json`, fetched (and cached) on first use. */
  executableJson(): Promise<string>;
  /** Program arguments for one segment, as felts, in the executable's own order. */
  encodeArgs(request: SegmentRequest): Felt[];
}

/**
 * Decodes the ten public felts of a segment (D14).
 *
 * The argument is the **tail** of the leaf bootloader's output preimage: the
 * preimage is `[program_hash, out_0 … out_9]`, so this takes `preimage.slice(1)`
 * — or the ten felts on their own.
 */
export function decodeSegmentOutput(felts: readonly Felt[]): SegmentOutput {
  if (felts.length !== SEGMENT_OUTPUT_FELTS) {
    throw new RangeError(
      `a segment output is ${SEGMENT_OUTPUT_FELTS} felts (D14), got ${felts.length}`,
    );
  }
  const at = (i: number): Felt => felts[i] as Felt;
  const version = feltToNumber(at(0));
  if (version !== SEGMENT_OUTPUT_VERSION) {
    throw new RangeError(`unknown segment output layout version ${version}`);
  }
  return {
    version,
    hIn: normalizeFelt(at(1)),
    hOut: normalizeFelt(at(2)),
    ticStart: feltToNumber(at(3)),
    ticEnd: feltToNumber(at(4)),
    status: feltToNumber(at(5)),
    inputsCommitment: normalizeFelt(at(6)),
    kills: feltToNumber(at(7)),
    items: feltToNumber(at(8)),
    secrets: feltToNumber(at(9)),
  };
}

/** Splits a bootloader output preimage into its program hash and the ten felts. */
export function splitPreimage(preimage: readonly Felt[]): {
  programHash: Felt;
  output: SegmentOutput;
} {
  if (preimage.length !== SEGMENT_OUTPUT_FELTS + 1) {
    throw new RangeError(
      `an output preimage is [program_hash, out_0 … out_9] = ${SEGMENT_OUTPUT_FELTS + 1} felts, got ${preimage.length}`,
    );
  }
  return {
    programHash: normalizeFelt(preimage[0] as Felt),
    output: decodeSegmentOutput(preimage.slice(1)),
  };
}

export interface StubProgramOptions {
  /** Where the committed `segment_stub10.executable.json` is served from. */
  executableUrl?: string;
  /** Injected in tests; defaults to `fetch`. */
  fetchImpl?: typeof globalThis.fetch;
  /** `h_in` of the first segment. Any non-zero felt: the stub does not interpret it. */
  genesis?: Felt;
  /**
   * Offsets the stub's synthetic input words, so two segments of the same length
   * get different `inputs_commitment`s. The pipeline derives it per segment from
   * the real journal, see {@link createStubProgram}.
   */
  seed?: number;
}

/**
 * `segment_stub10` — the stand-in executable, used until `doom_run` exists.
 *
 * Its arguments are `(h_in, tic_start, n_tics, seed, status, kills, items,
 * secrets)`, and its "game" is a fixed ~2^17-step arithmetic loop, so a segment
 * costs ~171 k steps plus ~49 steps per tic. What is *real* is the shape of the
 * pipeline around it: the ten-felt output, the `h_in`/`h_out` chain, the output
 * preimage the wrapper takes, and the leaf circuit the proof lands in.
 *
 * The stub does not read the journal — it synthesises its own words from `seed`
 * — so the pipeline folds the segment's real words into that seed. That keeps
 * two different games from producing the same commitment, which is what the run
 * id depends on, without pretending the stub consumes the journal.
 */
export function createStubProgram(options: StubProgramOptions = {}): SegmentProgram {
  const url = options.executableUrl ?? "/programs/segment_stub10.executable.json";
  const doFetch = options.fetchImpl ?? ((...a: Parameters<typeof fetch>) => globalThis.fetch(...a));
  const seedBase = options.seed ?? 0;
  let cached: Promise<string> | null = null;

  return {
    id: "segment_stub10",
    hashFunction: "poseidon",
    genesis: options.genesis ?? toFelt(1),
    executableJson(): Promise<string> {
      cached ??= doFetch(url).then(async (res) => {
        if (!res.ok) throw new Error(`cannot fetch ${url}: HTTP ${res.status}`);
        return res.text();
      });
      return cached;
    },
    encodeArgs({ hIn, ticStart, ticCount, words, index }): Felt[] {
      // A cheap, order-sensitive fold of the segment's own words; 32 bits, which
      // is what the stub's `seed: u32` takes.
      let seed = (seedBase + index) >>> 0;
      for (const word of words) seed = (Math.imul(seed ^ (word >>> 0), 0x01000193) >>> 0) >>> 0;
      return [
        toFelt(hIn),
        toFelt(ticStart),
        toFelt(ticCount),
        toFelt(seed),
        toFelt(0), // status: RUNNING; the stub never ends the game on its own.
        toFelt(0), // kills
        toFelt(0), // items
        toFelt(0), // secrets
      ];
    },
  };
}

/**
 * The browser twin of `cairo/crates/ticcmd`: the 32-bit input **word** and the
 * 7-tics-per-felt **transport felt**.
 *
 * Only the two encodings live here, not the game's reading of `buttons`. The
 * word is what the proving path consumes (one felt per tic); the transport felt
 * is what is persisted, exported and — later — published on chain, at the
 * density CONTEXT.md §9 budgets (~900 felts for a 3-minute run).
 *
 * ```text
 * word (32 bits, one tic)
 *   bits  0..7   forward + 128        forward in [-128, 127]
 *   bits  8..15  side    + 128        side    in [-128, 127]
 *   bits 16..23  turn / 256 + 128     turn in [-32768, 32512], multiples of 256
 *   bits 24..31  buttons              0..255
 *
 * transport felt (224 bits, seven tics)
 *   w0 + w1·2^32 + w2·2^64 + w3·2^96 + w4·2^128 + w5·2^160 + w6·2^192
 * ```
 *
 * `quantize` snaps a raw capture onto that grid — exactly what vanilla's demo
 * format does (`G_WriteDemoTiccmd` stores `angleturn >> 8`, decision **D12**) —
 * so the journal that is played is bit-for-bit the journal that is proven.
 */
import { toFelt } from "./felt.js";
import type { Felt } from "./types.js";

/** `ticcmd::TICS_PER_FELT`. */
export const TICS_PER_FELT = 7;
/** Lane width of the packing, `2^32`. */
const LANE = 1n << 32n;

export interface TicCmd {
  /** Forward/back thrust, `[-128, 127]`. */
  forward: number;
  /** Strafe, `[-128, 127]`. */
  side: number;
  /** BAM turn, a multiple of 256 in `[-32768, 32512]`. */
  turn: number;
  /** Doom's button bits, `[0, 255]`. */
  buttons: number;
}

function clamp(value: number, lo: number, hi: number): number {
  return value < lo ? lo : value > hi ? hi : value;
}

/**
 * Makes any raw input canonical: clamps each field and snaps the turn onto the
 * 256-BAM grid (rounding towards zero, as `angleturn >> 8` does for the values
 * `G_BuildTiccmd` produces). Total and idempotent.
 */
export function quantize(cmd: TicCmd): TicCmd {
  const turn = clamp(Math.trunc(cmd.turn / 256), -128, 127) * 256;
  return {
    forward: clamp(Math.trunc(cmd.forward), -128, 127),
    side: clamp(Math.trunc(cmd.side), -128, 127),
    turn,
    buttons: clamp(Math.trunc(cmd.buttons), 0, 255),
  };
}

export function isCanonical(cmd: TicCmd): boolean {
  const q = quantize(cmd);
  return (
    q.forward === cmd.forward && q.side === cmd.side && q.turn === cmd.turn && q.buttons === cmd.buttons
  );
}

/** One tic as a 32-bit word. Throws on a non-canonical command, never truncates. */
export function encodeCmd(cmd: TicCmd): number {
  if (!isCanonical(cmd)) {
    throw new RangeError(`ticcmd is not canonical: ${JSON.stringify(cmd)} (call quantize first)`);
  }
  const forward = cmd.forward + 128;
  const side = cmd.side + 128;
  const turn = cmd.turn / 256 + 128;
  return ((cmd.buttons << 24) | (turn << 16) | (side << 8) | forward) >>> 0;
}

export function decodeCmd(word: number): TicCmd {
  const w = word >>> 0;
  return {
    forward: (w & 0xff) - 128,
    side: ((w >>> 8) & 0xff) - 128,
    turn: (((w >>> 16) & 0xff) - 128) * 256,
    buttons: (w >>> 24) & 0xff,
  };
}

/** Up to seven words into one transport felt; a short group is left short. */
export function pack7(words: readonly number[]): Felt {
  if (words.length > TICS_PER_FELT) {
    throw new RangeError(`pack7 takes at most ${TICS_PER_FELT} words, got ${words.length}`);
  }
  let packed = 0n;
  let lane = 1n;
  for (const word of words) {
    if (!Number.isInteger(word) || word < 0 || word > 0xffffffff) {
      throw new RangeError(`not a 32-bit input word: ${word}`);
    }
    packed += BigInt(word >>> 0) * lane;
    lane *= LANE;
  }
  return toFelt(packed);
}

/** Inverse of {@link pack7}; `count` says how many of the seven lanes are real. */
export function unpack7(felt: Felt, count = TICS_PER_FELT): number[] {
  if (count < 0 || count > TICS_PER_FELT) throw new RangeError(`count out of range: ${count}`);
  let value = BigInt(felt);
  const words: number[] = [];
  for (let i = 0; i < count; i++) {
    words.push(Number(value % LANE));
    value /= LANE;
  }
  return words;
}

/** A whole log, seven words to a felt, the last group short. */
export function packLog(words: readonly number[]): Felt[] {
  const felts: Felt[] = [];
  for (let i = 0; i < words.length; i += TICS_PER_FELT) {
    felts.push(pack7(words.slice(i, i + TICS_PER_FELT)));
  }
  return felts;
}

/** Inverse of {@link packLog}. `ticCount` disambiguates the last, short group. */
export function unpackLog(felts: readonly Felt[], ticCount: number): number[] {
  const words: number[] = [];
  for (const felt of felts) {
    const remaining = ticCount - words.length;
    if (remaining <= 0) break;
    words.push(...unpack7(felt, Math.min(TICS_PER_FELT, remaining)));
  }
  return words;
}

/**
 * Streaming packer, the shape `segment` uses on the proving side: complete
 * groups are frozen as felts as soon as they fill, and the (0..6) leftover words
 * stay addressable so the journal can be persisted without re-reading it.
 */
export class TicLog {
  private readonly complete: Felt[];
  private tail: number[];

  constructor(complete: Felt[] = [], tail: number[] = []) {
    this.complete = complete;
    this.tail = [...tail];
  }

  /** Number of tics recorded. */
  get length(): number {
    return this.complete.length * TICS_PER_FELT + this.tail.length;
  }

  push(word: number): void {
    this.tail.push(word >>> 0);
    if (this.tail.length === TICS_PER_FELT) {
      this.complete.push(pack7(this.tail));
      this.tail = [];
    }
  }

  pushCmd(cmd: TicCmd): void {
    this.push(encodeCmd(quantize(cmd)));
  }

  /** The frozen groups; safe to persist incrementally (they never change). */
  get completeFelts(): readonly Felt[] {
    return this.complete;
  }

  /** The 0..6 words of the group in flight. */
  get tailWords(): readonly number[] {
    return this.tail;
  }

  /** Every felt, the last one short — byte-identical to `packLog(words)`. */
  toFelts(): Felt[] {
    return this.tail.length > 0 ? [...this.complete, pack7(this.tail)] : [...this.complete];
  }

  /** The raw words, e.g. to slice a segment's own span out of the journal. */
  toWords(): number[] {
    return unpackLog(this.toFelts(), this.length);
  }

  /** `[from, to)` of the journal, as words. */
  slice(from: number, to: number): number[] {
    return this.toWords().slice(from, to);
  }

  static fromPersisted(complete: readonly Felt[], tail: readonly number[]): TicLog {
    return new TicLog([...complete], [...tail]);
  }
}

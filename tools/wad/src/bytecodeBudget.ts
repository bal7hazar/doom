/**
 * Bytecode-size budget for the generated `const` arrays (RISKS.md R2-A12,
 * docs/spikes/S1.md §5.9, docs/G0.md D4).
 *
 * S1 measured that the bootloader rehashes the whole compiled program on
 * every proof segment for `2 340 + 14.7 * words` steps, and that a `const`
 * array of felts costs *exactly one word of bytecode per felt*
 * (`spikes/s1/results/bytecode_size.txt`: `[felt252; 32000]` compiles to
 * 32 157 words, i.e. 1.00 word/value once the array is a few hundred
 * elements). That makes the size of the constants this tool emits a first-
 * class budget, on top of the runtime steps/tic budget: G0.md D4 sets a
 * 16k-word budget for the whole `doom_run` program, and this task's default
 * is a 12k-word slice of that for level data alone (`--max-words`, task
 * item 3).
 *
 * This module applies "1 word per emitted array element" uniformly to
 * every `const` array regardless of its declared Cairo type (`felt252` or
 * `u32`): S1's measurement is specifically for `[felt252; N]`, and a
 * `[u32; N]` array's exact bytecode cost was not separately measured here,
 * so treating it the same is a documented approximation, not a re-measured
 * fact - see README.md. It is conservative in the direction that matters
 * (it does not let a real `u32` array look artificially cheap: `u32` array
 * elements are Sierra `felt252`-backed range-checked values compiled the
 * same way, so the two are expected to match, but this has not been
 * independently re-measured for this tool's Scarb/Cairo version).
 */

export interface ArrayEntry {
  /** Cairo const name, e.g. "LINEDEF_AB". */
  name: string;
  /** emit-config.json group this array belongs to, e.g. "linedefPredicates". */
  group: string;
  /** "planar" or "packed", whichever layout produced this array. */
  layout: string;
  /** Number of elements in the array (or 1 for a scalar const). */
  count: number;
}

export interface ArrayBudget extends ArrayEntry {
  words: number;
}

export interface BytecodeBudget {
  arrays: ArrayBudget[];
  totalWords: number;
}

/** One word of bytecode per emitted array element (S1 §5.9); see the module header for scope/caveats. */
export function computeBytecodeBudget(entries: ArrayEntry[]): BytecodeBudget {
  const arrays = entries.map((e) => ({ ...e, words: e.count }));
  const totalWords = arrays.reduce((sum, a) => sum + a.words, 0);
  return { arrays, totalWords };
}

/**
 * Steps of bootloader program-hashing cost per proof segment for a program
 * of this many bytecode words (docs/spikes/S0.md §5.2: `2 340 + 14.7 *
 * words`, `program_hash_function = blake`). This budget module only
 * accounts for the level-data constants (not the rest of `doom_run`'s
 * compiled code), so this helper is informational (used in reports), not
 * itself an accept/reject gate.
 */
export function bootloaderHashSteps(words: number): number {
  return 2340 + 14.7 * words;
}

export class BudgetExceededError extends Error {
  constructor(
    public readonly totalWords: number,
    public readonly maxWords: number,
  ) {
    super(`Cairo constants use ${totalWords} bytecode words, exceeding --max-words ${maxWords} (R2-A12)`);
    this.name = "BudgetExceededError";
  }
}

/** Throws `BudgetExceededError` if `budget.totalWords` exceeds `maxWords`. */
export function assertBudget(budget: BytecodeBudget, maxWords: number): void {
  if (budget.totalWords > maxWords) {
    throw new BudgetExceededError(budget.totalWords, maxWords);
  }
}

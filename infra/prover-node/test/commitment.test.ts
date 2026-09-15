// SPDX-License-Identifier: Apache-2.0
/** The Poseidon fold against the contract's own vectors and the proved fixture. */
import { describe, expect, it } from "vitest";

import { packLog } from "../../../client/src/prove/ticcmd.js";
import { commitLog, commitWords, inputsSeed, packedLen } from "../src/commitment.js";
import { fixtureJournal, fixtureLeaf } from "./fixtures.js";

describe("commit_log (D13 port)", () => {
  it("reproduces inputs_seed and the nine-tic vector of tests/fixtures.cairo", () => {
    expect(inputsSeed()).toBe(1282518709132710633260571458233338951152986210120734438673228939417441244734n);
    expect(commitLog([])).toBe(inputsSeed());
    expect(
      commitLog([52862675047884335114613364565167029614684700343999192604006711424n, 36170118631293063n]),
    ).toBe(2547131120780086942321108118278711743934949688745852571659682634892536498898n);
  });

  it("is order-sensitive", () => {
    expect(commitLog([1n, 2n])).not.toBe(commitLog([2n, 1n]));
  });

  it("reproduces every inputs_commitment the Cairo program emitted for B2-1_doom", () => {
    const plan = [
      [0, 0],
      [0, 1],
      [1, 0],
    ] as const;
    for (const [game, segment] of plan) {
      const leaf = fixtureLeaf(game, segment);
      expect(leaf.packed.length).toBe(packedLen(leaf.ticEnd - leaf.ticStart));
      // From the published felts, and again from the words re-packed by this package.
      expect(commitLog(leaf.packed.map(BigInt))).toBe(leaf.inputsCommitment);
      expect(packLog(leaf.words)).toEqual(leaf.packed);
      expect(commitWords(leaf.words)).toBe(leaf.inputsCommitment);
    }
  });

  it("commits a whole journal differently from its segments", () => {
    const words = fixtureJournal(0);
    expect(words).toHaveLength(297);
    const whole = commitWords(words);
    expect(whole).not.toBe(fixtureLeaf(0, 0).inputsCommitment);
    expect(commitWords(words.slice(0, 160))).toBe(fixtureLeaf(0, 0).inputsCommitment);
    expect(commitWords(words.slice(160))).toBe(fixtureLeaf(0, 1).inputsCommitment);
  });
});

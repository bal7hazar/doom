import { describe, expect, it } from "vitest";
import {
  linedefFixedBBox,
  linedefPredicate,
  nodePredicate,
  PRED_BIGC,
  PRED_FRACUNIT,
  PRED_HK,
  PRED_OFF,
  pointOnSideReference,
} from "../src/predicates.js";
import { Vertex } from "../src/types.js";

/** Deterministic PRNG (mulberry32) so failures are reproducible without a fixed seed library dependency. */
function mulberry32(seed: number): () => number {
  let a = seed;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function randomInt16(rng: () => number): number {
  return Math.floor(rng() * 65536) - 32768;
}

/**
 * A coordinate bounded so that two independently-sampled values differ by
 * at most ~8000 map units either way - representative of a real map's
 * linedef span (Freedoom E1M1 is 3952 x 3400 units, see REPORT-e1m1.md),
 * and within `PRED_HK`'s documented domain (see predicates.ts). Unlike
 * `randomInt16`, this is *not* meant to cover the full WAD coordinate
 * range: see the dedicated out-of-range test below for that.
 */
function randomMapCoord(rng: () => number): number {
  return Math.floor(rng() * 8000) - 4000;
}

/** Evaluates our biased-integer predicate for a query point already in fixed-point map units. */
function sideFromPredicate(ab: bigint, bb: bigint, cb: bigint, xMapUnits: number, yMapUnits: number): 0 | 1 {
  const X = BigInt(xMapUnits) * PRED_FRACUNIT + PRED_OFF;
  const Y = BigInt(yMapUnits) * PRED_FRACUNIT + PRED_OFF;
  const cross = ab * Y + bb * X + cb;
  const hoist = PRED_HK * (X + Y) + PRED_BIGC;
  return cross >= hoist ? 1 : 0;
}

describe("linedefPredicate vs. a float re-implementation of P_PointOnLineSide", () => {
  const rng = mulberry32(0xd00d);

  it("agrees with the reference on random lines and random points, for 2000 samples", () => {
    let checked = 0;
    for (let i = 0; i < 2000; i++) {
      const v1: Vertex = { x: randomMapCoord(rng), y: randomMapCoord(rng) };
      const v2: Vertex = { x: randomMapCoord(rng), y: randomMapCoord(rng) };
      if (v1.x === v2.x && v1.y === v2.y) continue; // degenerate zero-length line, skip
      const px = randomInt16(rng);
      const py = randomInt16(rng);

      // Reference: is the query point exactly on the line? Skip those - S1 §7
      // documents a known divergence for on-line points on vertical lines,
      // and floating-point "on the line" is ill-defined for a random sample
      // anyway. Use the exact integer cross product to detect it.
      const ldx = v2.x - v1.x;
      const ldy = v2.y - v1.y;
      const exactCross = ldx * (py - v1.y) - ldy * (px - v1.x);
      if (exactCross === 0) continue;

      const pred = linedefPredicate(v1, v2);
      const ours = sideFromPredicate(pred.ab, pred.bb, pred.cb, px, py);
      const reference = pointOnSideReference(px, py, v1, v2);
      expect(ours, `line (${v1.x},${v1.y})-(${v2.x},${v2.y}), point (${px},${py})`).toBe(reference);
      checked++;
    }
    expect(checked).toBeGreaterThan(1500);
  });

  /**
   * Vanilla `P_PointOnLineSide`'s exact algorithm, including the `!line->dx`
   * / `!line->dy` special cases the general cross-product formula (used by
   * `pointOnSideReference`, and baked into `linedefPredicate`'s
   * coefficients) does not reproduce. Only used by the test below, to make
   * the S1 §7 "geom2d" documented divergence concrete instead of leaving it
   * as prose.
   */
  function pointOnSideVanillaExact(px: number, py: number, v1: Vertex, v2: Vertex): 0 | 1 {
    const dx = v2.x - v1.x;
    const dy = v2.y - v1.y;
    if (dx === 0) return (px <= v1.x ? dy > 0 : dy < 0) ? 1 : 0;
    if (dy === 0) return (py <= v1.y ? dx < 0 : dx > 0) ? 1 : 0;
    return pointOnSideReference(px, py, v1, v2);
  }

  it("documents the known vertical-line-through-v1.x divergence from true vanilla (S1 §7 geom2d), not from our own float reference", () => {
    // Vertical line, ldy < 0 (v2 below v1), point exactly on v1.x.
    const v1: Vertex = { x: 100, y: 200 };
    const v2: Vertex = { x: 100, y: -200 };
    const px = 100;
    const py = 50;
    const pred = linedefPredicate(v1, v2);
    const ours = sideFromPredicate(pred.ab, pred.bb, pred.cb, px, py);
    const generalReference = pointOnSideReference(px, py, v1, v2);
    const vanillaExact = pointOnSideVanillaExact(px, py, v1, v2);
    // Our integer predicate exactly reproduces the general cross-product
    // formula for every input (they're algebraically the same computation,
    // just biased/scaled) - no divergence here.
    expect(ours).toBe(generalReference);
    // But the general formula itself disagrees with vanilla's specialized
    // dx=0 branch at this exact point: this is the divergence S1 §7 says a
    // later, fidelity-focused crate must either special-case or document.
    expect(generalReference).toBe(1);
    expect(vanillaExact).toBe(0);
  });

  it("stays within the asserted coefficient ranges (|A|,|B| < 2^15, C < 2^50) for lines within PRED_HK's documented domain", () => {
    // Corners of a map roughly Freedoom E1M1's size (see predicates.ts's
    // PRED_HK comment): deltas stay within +-4000, well under PRED_HK.
    for (const v1 of [{ x: -2000, y: -2000 }, { x: 2000, y: 2000 }, { x: -2000, y: 2000 }]) {
      for (const v2 of [{ x: 2000, y: -2000 }, { x: -2000, y: -1999 }]) {
        const p = linedefPredicate(v1, v2);
        expect(p.ab >= 0n && p.ab < 1n << 15n).toBe(true);
        expect(p.bb >= 0n && p.bb < 1n << 15n).toBe(true);
        expect(p.cb >= 0n && p.cb < 1n << 50n).toBe(true);
      }
    }
  });

  it("throws a clear RangeError instead of silently wrapping for a line whose span exceeds PRED_HK's documented domain", () => {
    // A pathological linedef spanning almost the entire int16 range: ldx =
    // 65535, way beyond the +-8192 (PRED_HK) domain the bias is sized for.
    expect(() => linedefPredicate({ x: -32768, y: 0 }, { x: 32767, y: 0 })).toThrow(RangeError);
  });
});

describe("nodePredicate vs. the same float reference (node partitions use the same formula as linedefs)", () => {
  const rng = mulberry32(0xfeed);

  it("agrees with the reference on random partitions and random points, for 1000 samples", () => {
    let checked = 0;
    for (let i = 0; i < 1000; i++) {
      const x = randomInt16(rng);
      const y = randomInt16(rng);
      let dx = randomMapCoord(rng);
      let dy = randomMapCoord(rng);
      if (dx === 0 && dy === 0) dx = 1;
      const px = randomInt16(rng);
      const py = randomInt16(rng);

      const exactCross = dx * (py - y) - dy * (px - x);
      if (exactCross === 0) continue;

      const pred = nodePredicate({ x, y, dx, dy });
      const ours = sideFromPredicate(pred.ab, pred.bb, pred.cb, px, py);
      // A node partition is the same infinite line as a linedef from (x,y) in
      // direction (dx,dy); v2 = v1 + (dx,dy) reproduces the same line for the
      // reference formula.
      const reference = pointOnSideReference(px, py, { x, y }, { x: x + dx, y: y + dy });
      expect(ours).toBe(reference);
      checked++;
    }
    expect(checked).toBeGreaterThan(800);
  });
});

describe("linedefFixedBBox", () => {
  it("is order-independent and matches min/max of the two biased-fixed endpoints", () => {
    const v1: Vertex = { x: 100, y: -50 };
    const v2: Vertex = { x: -30, y: 400 };
    const a = linedefFixedBBox(v1, v2);
    const b = linedefFixedBBox(v2, v1);
    expect(a).toEqual(b);
    expect(a.left < a.right).toBe(true);
    expect(a.bottom < a.top).toBe(true);
  });
});

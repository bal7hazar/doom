/**
 * Half-plane predicate coefficients for linedefs and BSP node partitions
 * (RISKS.md R2-A4, docs/spikes/S1.md §5.5/§7 "geom2d"). This is a direct
 * port of the "three-array" biased form validated by `spikes/s1/proto` -
 * see `spikes/s1/tools/extract.py` (`three_array`, `line_coeffs`,
 * `node_coeffs`) and `spikes/s1/proto/src/geom.cairo` (`line_side_three`,
 * `node_side_three`) for the Cairo-side consumer this feeds.
 *
 * The idea (S1 §5.3): don't make the Cairo core recompute `cross = A*y +
 * B*x + C` from raw vertices every call (that's what SEGS/vertex lookups
 * were for); precompute A, B, C once per linedef/node here, so a runtime
 * check is 3 array reads + 2 multiplications + 1 comparison and never
 * divides, never looks at a vertex.
 *
 * `cross(x_f, y_f) = A*y_f + B*x_f + C`, with `x_f = x*FRACUNIT`, `y_f =
 * y*FRACUNIT` the query point in 16.16 fixed point (matching how mobj
 * positions are represented in the game state) and `side = 1 iff cross >=
 * 0` (vanilla `P_PointOnLineSide`/`R_PointOnSide` convention: side 0 is the
 * "front", where `right < left`).
 *
 * A, B, C can be negative, so each is rewritten with a fixed bias that
 * makes it a non-negative value staying comfortably under 2^72 (S1 §5.2,
 * §7 "fixed": felt comparisons are cheaper when nothing written to memory
 * needs a raw-negative sign test, and the exact bias size is free in
 * steps as long as it stays just above the real domain):
 *
 *   X = x_f + OFF,  Y = y_f + OFF                    (OFF = 2^32)
 *   Ab = A + HK,    Bb = B + HK                       (HK  = 2^13, |A|,|B| < 2^13)
 *   Cb = C2 + BIGC                                    (BIGC = 2^48, C2 = C - (A+B)*OFF)
 *
 *   cross(x_f,y_f) >= 0  <=>  Ab*Y + Bb*X + Cb  >=  HK*(X+Y) + BIGC
 *
 * The right-hand side does not depend on the line/node, so the Cairo core
 * hoists it out of the per-line loop (computed once per query point) - see
 * `hoist()` in `spikes/s1/proto/src/geom.cairo`. This module emits the left
 * side's three coefficients (`ab`, `bb`, `cb`) per linedef/node; `HK` and
 * `BIGC` are exported so the Cairo output can emit them as named constants
 * the core's `hoist` function reads.
 */

import { Node, Vertex } from "./types.js";

export const PRED_FRACBITS = 16n;
export const PRED_FRACUNIT = 1n << PRED_FRACBITS; // 65536
/** Coordinate bias: keeps X = x_f + OFF positive for the full int16 map-unit range. */
export const PRED_OFF = 1n << 32n;
/**
 * Bias for the A/B coefficients. `A` and `B` are `+-(v2 - v1)` for a
 * linedef (or `+-(dx, dy)` for a node partition) - not bounded by the
 * int16 *coordinate* range in general, but by how far apart a single
 * linedef's two vertices (or a single node's partition delta) actually
 * are, which for a real map is bounded by the map's extent, not by 65536.
 * `2^13 = 8192` comfortably covers Freedoom E1M1 (map extent 3952 x 3400
 * map units, see REPORT-e1m1.md) - matching `spikes/s1/proto`'s validated
 * choice - but is *not* a universal WAD guarantee; `threeArray` below
 * throws a clear `RangeError` rather than silently wrapping if a future
 * map's linedef exceeds it, per S1 §5.2's "size each bias just above the
 * real domain" rule.
 */
export const PRED_HK = 1n << 13n;
/** Bias for the C coefficient. */
export const PRED_BIGC = 1n << 48n;

export interface HalfPlane {
  ab: bigint;
  bb: bigint;
  cb: bigint;
}

function threeArray(a: bigint, b: bigint, c2: bigint): HalfPlane {
  const ab = a + PRED_HK;
  const bb = b + PRED_HK;
  const cb = c2 + PRED_BIGC;
  if (ab < 0n || bb < 0n || cb < 0n) {
    throw new RangeError(`predicates.threeArray: negative biased coefficient (a=${a}, b=${b}, c2=${c2})`);
  }
  if (ab >= 1n << 15n || bb >= 1n << 15n) {
    throw new RangeError(`predicates.threeArray: |A| or |B| out of the expected int16-derived range (a=${a}, b=${b})`);
  }
  if (cb >= 1n << 50n) {
    throw new RangeError(`predicates.threeArray: C coefficient out of the expected range (c2=${c2})`);
  }
  return { ab, bb, cb };
}

export interface LinedefPredicate extends HalfPlane {
  /** P_BoxOnLineSide diagonal selector: 1 for a negative-slope line (uses right/top, left/bottom corners), 0 otherwise. */
  diag: 0 | 1;
}

/**
 * Half-plane coefficients for the linedef through `v1` -> `v2`, plus the
 * diagonal flag `box_on_line_side` needs to pick which two corners of a
 * bbox to test (S1 §7 "geom2d": "Stocker le diagonal ... dans un tableau
 * const").
 */
export function linedefPredicate(v1: Vertex, v2: Vertex): LinedefPredicate {
  const x1 = BigInt(v1.x);
  const y1 = BigInt(v1.y);
  const x2 = BigInt(v2.x);
  const y2 = BigInt(v2.y);
  const ldx = x2 - x1;
  const ldy = y2 - y1;
  const a = ldx;
  const b = -ldy;
  const c = ldy * (x1 * PRED_FRACUNIT) - ldx * (y1 * PRED_FRACUNIT);
  const c2 = c - (a + b) * PRED_OFF;
  const diag: 0 | 1 = ldx * ldy < 0n ? 1 : 0;
  return { ...threeArray(a, b, c2), diag };
}

/** Half-plane coefficients for a BSP node's partition line. */
export function nodePredicate(node: Pick<Node, "x" | "y" | "dx" | "dy">): HalfPlane {
  const nx = BigInt(node.x);
  const ny = BigInt(node.y);
  const ndx = BigInt(node.dx);
  const ndy = BigInt(node.dy);
  const a = ndx;
  const b = -ndy;
  const c = ndy * (nx * PRED_FRACUNIT) - ndx * (ny * PRED_FRACUNIT);
  const c2 = c - (a + b) * PRED_OFF;
  return threeArray(a, b, c2);
}

export interface FixedBBox {
  left: bigint;
  right: bigint;
  bottom: bigint;
  top: bigint;
}

/**
 * The linedef's bounding box in the same biased-fixed-point domain as the
 * predicate (`x_f + OFF`), so `box_on_line_side`'s bbox pre-check (S1 §7:
 * "garder l'ordre de Doom ... le test de bbox est une exigence de
 * correction") can compare it directly against a mobj's bbox corners
 * without a unit conversion.
 */
export function linedefFixedBBox(v1: Vertex, v2: Vertex): FixedBBox {
  const x1 = BigInt(v1.x) * PRED_FRACUNIT + PRED_OFF;
  const x2 = BigInt(v2.x) * PRED_FRACUNIT + PRED_OFF;
  const y1 = BigInt(v1.y) * PRED_FRACUNIT + PRED_OFF;
  const y2 = BigInt(v2.y) * PRED_FRACUNIT + PRED_OFF;
  return {
    left: x1 < x2 ? x1 : x2,
    right: x1 < x2 ? x2 : x1,
    bottom: y1 < y2 ? y1 : y2,
    top: y1 < y2 ? y2 : y1,
  };
}

/**
 * Reference floating-point re-implementation of vanilla `P_PointOnLineSide`
 * (used only by tests, to check the integer predicate above against an
 * independent computation). Sign is scale-invariant, so raw map units (no
 * FRACUNIT scaling) are equivalent to the fixed-point runtime inputs for
 * this comparison - see the derivation in this file's header comment.
 *
 * Known divergence (S1 §7 "geom2d", documented not fixed): for a vertical
 * line and a query point exactly on `v1.x` with `ldy < 0`, this general
 * formula can disagree with vanilla's specialized `!line->dx` branch by one
 * side. Tests avoid points exactly on a line for the general property check
 * and cover this case separately.
 */
export function pointOnSideReference(px: number, py: number, v1: Vertex, v2: Vertex): 0 | 1 {
  const ldx = v2.x - v1.x;
  const ldy = v2.y - v1.y;
  const left = ldy * (px - v1.x);
  const right = (py - v1.y) * ldx;
  return right < left ? 0 : 1;
}

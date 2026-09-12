# geom2d

**Does**: 2D geometry primitives on top of `fixed`/`bam`: a `Point`
(`Fixed` x/y), `point_on_side` (the sign of the cross product used
throughout Doom's collision and BSP code, e.g. `P_PointOnLineSide`), and
`point_to_octant` (a coarse, octant-granularity angle classification of the
vector between two points, in the spirit of Doom's `R_PointToAngle`, built
on `bam::Angle`).

**Does not**: know about sectors, linedefs, or any level-specific data
structure (that is `doom_map`); it does not implement segment/segment
intersection or distance-to-line yet — those are Phase 1 additions once the
budget-of-steps numbers from spike S1 are known (PLAN.md §3.1).

**Invariants**: `point_on_side` returns `0` only when the point is exactly
on the line (collinear), a positive value on one side and a negative value
on the other, consistently for a fixed line orientation (antisymmetric
under swapping the two line endpoints); `point_to_octant` returns a value
in `[0, 7]` for every pair of distinct points, and is invariant under
uniform positive scaling of the vector (only the direction matters).

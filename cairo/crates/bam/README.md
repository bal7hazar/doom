# bam

**Does**: represents angles as Doom-style Binary Angle Measurement (`Angle`,
a wrapping `u32` where the full `u32` range maps to one full turn), with
wrapping `add`/`sub`, and a coarse quadrant-based sine sign/magnitude lookup
(`sin_quadrant`) built on top of `fixed::Fixed`, standing in for the full
`finesine`/`tantoangle` tables planned for Phase 1 (PLAN.md §3.1, task 2).

**Does not**: perform any geometry (no points, no segments — that is
`geom2d`); it does not (yet) ship the full 8192-entry trigonometric tables
generated from the original `tantoangle`/`finesine` C tables — only a
4-point reference (0/90/180/270 degrees) sufficient to validate wrapping and
quadrant logic ahead of Phase 1's full table generation.

**Invariants**: `add`/`sub` always wrap modulo 2^32 (never panic on
overflow, matching the original C `unsigned` angle arithmetic); a full turn
(`add(a, ANGLE_MAX_PLUS_ONE_EQUIVALENT)` i.e. wrapping by the full range)
returns the original angle; `sin_quadrant` returns a value in `[-1.0, 1.0]`
(`Fixed`) for every input, with a sign that matches the standard sine sign
convention for each quadrant.

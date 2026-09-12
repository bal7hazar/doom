# doom_physics

**Does**: movement and collision against `doom_map` data: `can_move` checks
whether a straight step from one point to another crosses any blocking
line of the level (the core test `P_TryMove` performs before accepting a
move), built on `geom2d::point_on_side`. This is the seed `P_TryMove` /
`P_SlideMove` / `P_PathTraverse` / `P_CheckSight` will grow from in Phase 1
(PLAN.md §3.1, task 4) once real per-thing radii, sliding, and height
checks are added.

**Does not**: touch player or monster state (ammo, health, AI) — those are
`doom_player`/`doom_monsters`; it does not yet account for a mover's
radius (the current check is a zero-radius point movement, a deliberate
simplification until the blockmap-driven neighbourhood query from
`blockmap` is wired in).

**Invariants**: `can_move` is a pure function of the level and the two
endpoints (no hidden state); a move that does not cross any blocking line
is always allowed (`can_move` never rejects a move that does not intersect
any segment marked `blocking`); a move that exactly retraces a previous
move in reverse gives the same verdict (symmetry: `can_move(l, a, b) ==
can_move(l, b, a)`).

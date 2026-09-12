# bsp

**Does**: traverses a binary space partition tree to locate the subsector
containing a point (`point_in_subsector`), mirroring Doom's node traversal
using `geom2d::point_on_side` to pick the front or back child at each node,
down to a leaf (`Child::Subsector`).

**Does not**: build the BSP tree (it is generated offline by `tools/wad`
from the WAD's `NODES`/`SSECTORS` lattices and passed in as data); it does
not walk the tree for ray casting or sight checks yet (`P_CheckSight` /
`P_PathTraverse` traversal is a `doom_physics` concern that will reuse this
crate's node-walking primitive).

**Invariants**: traversal always terminates in at most `nodes.len() + 1`
steps (enforced by an assertion, so a malformed/cyclic tree aborts rather
than looping forever — required by the zero-panic-in-production policy's
"fail loud in tests" counterpart, RISKS.md R4); the subsector id returned
for a point exactly on a partition line is decided by the same
`point_on_side` sign convention used everywhere else (side `>= 0` picks the
front child), so it is consistent across the whole codebase.

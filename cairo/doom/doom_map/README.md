# doom_map

**Does**: owns the generated, typed level data (initially E1M1 from
Freedoom: vertices, linedefs, sidedefs, sectors, things, the blockmap, the
BSP nodes/subsectors, and the REJECT matrix) and typed accessors over it
(`sector_at`, `is_line_blocking`, …), generated offline by `tools/wad` from
`freedoom1.wad` (PLAN.md §3.1, task 1). This scaffold ships a small,
hand-written `Level` with one sector and one linedef so the crate compiles
and its accessor contract is exercised before the real WAD extraction
lands.

**Does not**: parse the WAD itself (that is TypeScript tooling in
`tools/wad`, outside the Cairo workspace, run entirely offline); it does
not implement any gameplay rule (movement, sight, damage) — those live in
`doom_physics`/`doom_player`/`doom_monsters`/`doom_specials`, which treat
`doom_map` as a read-only data source.

**Invariants**: every accessor is total and panic-free over the level's own
data range (`sector_at(id)` never panics for `id < level.sectors.len()`);
`is_line_blocking` is a pure function of the line's own flags, never of any
mutable game state (dynamic openness — e.g. an opened door — is tracked
elsewhere, in `doom_specials`/`doom_game`, not by mutating this crate's
static data).

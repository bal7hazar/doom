# doom_things

**Does**: a reduced `mobjinfo`-style catalogue: `MobjType` (Doom thing type
ids, a handful for now: player, zombieman, imp), `MobjInfo` (health, speed,
radius/height as `fixed::Fixed`, and the `fsm::StateDef` table id ranges for
its states), and `info_of(kind)` returning the static definition. Sprite
indices and the full `info.c` state tables are Phase 1 additions once the
exact roster is known from the WAD extraction (PLAN.md §3.1, task 5).

**Does not**: hold any per-instance/mutable data (position, current state,
health remaining) — that belongs to a `Mobj` value owned by `doom_game`'s
`GameState`; this crate only holds the immutable, shared-by-all-instances
catalogue, exactly like the original `mobjinfo_t` table.

**Invariants**: `info_of` is total over `MobjType` (every variant has an
entry, so it never panics); `radius >= 0` and `height >= 0` (as `Fixed`) for
every entry; the `state_table_first`/`state_table_len` range of every entry
is non-empty (every thing has at least a spawn state).

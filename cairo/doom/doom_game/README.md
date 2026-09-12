# doom_game

**Does**: assembles every other `doom/*` crate into one `GameState`
(currently `tic` + the player; monsters/specials are aggregated at the
call-site until the full roster from the WAD extraction lands) and the two
functions everything else is built from: `genesis` (initial state) and
`step_tic` (one tic of `doom_player::think`, the seed `run_segment` will
loop). `serialize`/`hash_of` turn a `GameState` into the canonical felts
`state_hash` hashes, and `run_segment_header` chains a batch of commands
via `segment::chain_commands` — the shape `doom_run::run_segment` wraps.

**Does not**: implement `run_segment`'s full public-output contract
(`status`, `kills`, `items`, `secrets` — PLAN.md §3.1, task 7) — that is
`doom_run`'s executable entry point, one layer above this crate; it does
not yet fold monster thinking or door thinking into `step_tic` (both exist
and are exercised here only to prove the aggregation wires together —
PLAN.md §3.1, task 3 folds them in for real once the monster/special
roster is fixed by the WAD extraction).

**Invariants**: `step_tic` never calls into any crate outside this
workspace's `doom/*` + generic dependency graph (this crate is the single
point where the whole graph meets, per A10's "`doom_game` aggregates"
rule); `hash_of` is a pure function of `serialize`'s output (delegates
entirely to `state_hash::hash_state`, so this crate owns *what* gets
hashed, never *how*).

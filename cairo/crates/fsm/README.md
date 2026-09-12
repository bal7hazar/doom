# fsm

**Does**: a generic finite-state-machine primitive in the spirit of Doom's
`info.c` state tables: a `StateDef { duration, next }` table and a `Timer
{ state, remaining }` instance that `tick` advances by one tic, following
`next` and reloading `duration` whenever `remaining` reaches zero. It is
domain-agnostic: it knows nothing about sprites, frames, or actions —
callers (`doom_things`, `doom_monsters`, `doom_specials`) attach that
meaning to state ids externally.

**Does not**: execute "action" callbacks on state entry — Cairo has no
function pointers, so invoking the right action per state is the caller's
responsibility (typically a `match` on the state id after `tick` reports a
transition). It does not own the state table's storage; `Span<StateDef>` is
passed in by the caller on every call.

**Invariants**: a state with `duration == 0` is static and `tick` never
advances it (mirrors Doom's permanent/terminal states); for `duration > 0`,
`tick` applied `duration` times from a freshly `start`-ed timer always
reaches the `next` state; `tick` never panics as long as every `next` id
in the table is a valid index into the same table (a caller invariant, not
checked here — enforcing it belongs to the table-construction step).

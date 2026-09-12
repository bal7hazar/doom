# doom_monsters

**Does**: the seed of the monster AI loop: `look` (`A_Look`) draws one
`prng` byte to decide whether a sleeping monster wakes up; `chase`
(`A_Chase`) takes one step toward a target through
`doom_physics::can_move`, only while awake; `advance_state` ticks the
monster's `fsm::Timer` by one tic. `spawn` builds the initial
`MonsterState` from `doom_things`'s catalogue.

**Does not**: implement attacks, damage output, death states, or
`P_CheckSight`/REJECT-based visibility yet (PLAN.md §3.1, task 5) — sight
is a `doom_physics`/`doom_map` addition (REJECT lookup) that `chase`/`look`
will call into once available; it does not implement `P_NewChaseDir`'s
real direction search — the current `chase` only steps along a single
caller-supplied delta.

**Invariants**: a monster that is not `awake` never moves (`chase` is a
no-op until `look` sets `awake`); `look` never wakes an already-awake
monster back to sleep (waking is one-directional in this scaffold, matching
the fact that Doom monsters do not "forget" a wake-up mid-fight); the
`rng_index` returned by `look` always advances by exactly one draw,
regardless of whether the monster actually wakes, so RNG consumption is
deterministic and replay-stable (PLAN.md C2).

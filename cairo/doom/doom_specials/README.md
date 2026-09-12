# doom_specials

**Does**: the seed of moving-sector specials: a `Door` (`doom_map::Sector`
plus a `DoorState` and a raw fixed-point speed) whose `think_door` moves
the sector's ceiling one tic toward `target_ceiling` and snaps into
`Open`/`Closed` once reached, the shared shape behind Doom's door,
platform, and elevator thinkers.

**Does not**: implement switches, remote line activation, or the exit
special yet (PLAN.md §3.1, task 6) — those need `doom_map`'s linedef
special-type data (from the WAD extraction) to dispatch on; it does not
implement an auto-close timer for `Open` doors (`Open` is currently a
stable state until an external event, e.g. a re-trigger, requests
`Closing` — timed auto-close is a Phase 1 addition).

**Invariants**: `think_door` moves the ceiling by at most `speed` raw units
per tic and never overshoots past `target_ceiling` (it clamps exactly at
the target rather than skipping over it, regardless of `speed`); once a
door reaches `DoorState::Open` or `DoorState::Closed` it stays there under
repeated `think_door` calls until externally set to `Opening`/`Closing`
again (no spontaneous state changes).

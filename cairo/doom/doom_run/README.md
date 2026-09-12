# doom_run

**Does**: the provable entry point: a `[[target.executable]]` compiled
with `enable-gas = false` (required by `cairo_execute`) that, for this
scaffold, runs `x` no-op tics of `doom_game::step_tic` from `genesis` and
returns the resulting tic count -- `#[executable] fn main(x: u32) -> u32`
is intentionally the minimal placeholder PLAN.md's roadmap (P0.1) asks
for; the real executables (`genesis`, `step_tic`, `run_segment` with their
full public-output contracts, PLAN.md §3.1 task 7) are Phase 1 additions
that will replace this `main` body without changing its role as the single
provable entry point of the workspace.

**Does not**: expose `step_tic`/`run_segment` as separate `[[target.
executable]]` entries yet (Scarb 2.16.0 supports only one executable
target's `main` being invoked by `scarb execute` at a time per package;
Phase 1 will decide whether that means multiple `doom_run`-like packages
or a single dispatching `main`); it does not read real `ticcmd` input from
the caller yet -- `x` only selects how many identical no-op tics to run,
enough to prove the `scarb execute` pipeline end-to-end.

**Invariants**: `main(x)` always returns exactly `x` (each tic advances
`GameState.tic` by exactly one, and no tic is ever skipped or duplicated,
matching `doom_game::step_tic`'s own invariant); running `main` never
panics for any `x: u32` on the fixture level (no blocking line lies on the
no-op path, by construction of the fixture).

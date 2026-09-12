# segment

**Does**: provides the generic chaining engine behind `run_segment`: given
an incoming state hash `h_in` and a batch of packed `ticcmd::TicCmd` felts,
`chain_commands` folds them into `h_out` via `state_hash::chain`, and
`SegmentOutput` bundles the public outputs (`h_in`, `h_out`, tic bounds)
that `doom_run::run_segment` will eventually attach real game semantics to
(status, kills, items, secrets — PLAN.md §3.1, task 7).

**Does not**: execute any game logic — it has no notion of a player, a
monster, or a map; it never depends on any `doom/*` crate (A10's dependency
rule). It does not decide segment length `K`; the caller passes in
whatever slice of commands it wants chained.

**Invariants**: `chain_commands(h, cmds).h_out` only depends on `h` and the
exact sequence of packed commands (order-sensitive, like `state_hash`);
`tic_end - tic_start == cmds.len()` always holds in the returned
`SegmentOutput`; chaining zero commands leaves `h_out == h_in` unchanged
(an empty batch is a no-op on the hash, even though `state_hash::chain`
itself would still mix in `h_in` alone — `chain_commands` special-cases the
empty span so composing segments of length zero is truly an identity).

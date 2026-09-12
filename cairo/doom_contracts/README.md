# doom_contracts

**Does**: a Starknet contract package skeleton — a trivial `Counter`
contract (`get`/`increment`) exercised by an `snforge` integration test —
standing in for `StwoFactRegistry` + `DoomRuns` (PLAN.md A3, §2) until
Phase 4 wires in real fact verification and run submission.

**Does not** (yet): verify any Stwo fact, store any `Run`, or expose a
leaderboard; it deliberately depends on nothing else in this workspace,
since the real `DoomRuns` will recompute facts from felts handed to it by
the prover wrapper (PLAN.md §4), not from any Cairo library crate here.

**Toolchain note**: this package is intentionally **not** a member of
`cairo/Scarb.toml`'s workspace. Scarb 2.16.0 only honors one `[cairo]`
table per workspace (a per-package `[cairo]` override is ignored with a
warning), and a `[[target.starknet-contract]]` hard-requires gas to stay
enabled while `doom_run`'s `[[target.executable]]` hard-requires
`enable-gas = false`. Since the main workspace needs the latter for
`doom_run`, this package stays a sibling standalone Scarb package (own
`Scarb.toml`, same `cairo/.tool-versions`), built/tested independently:
`scarb --manifest-path cairo/doom_contracts/Scarb.toml build|test`.
`snforge 0.57.0` was verified to work against `scarb 2.16.0`: with a plain
`[dev-dependencies] snforge_std = "0.57.0"` and no `[scripts]` override,
`scarb test` still runs the (deprecated) built-in `cairo-test` and silently
reports "0 tests" instead of erroring, because `cairo-test` does not
recognize `snforge_std`'s cheatcode imports as its own tests. The
`[scripts] test = "snforge test"` entry in this package's `Scarb.toml`
makes `scarb test` dispatch to the real `snforge test` runner, which finds
and passes the integration test in `tests/`.

# Vendored `stwo_cairo_verifier` (Apache-2.0)

| | |
|---|---|
| Upstream | https://github.com/starkware-libs/proving, directory `stwo_cairo_verifier/` |
| **Pinned commit** | **`cd7bc5f`** ("refactor: take the destination buffer in FieldExpOps::batch_inverse (#136)") — the same pin as `docs/spikes/S4.md` and RISKS.md R3-A1 |
| Crates | `bounded_int`, `circuit_air`, `circuit_verifier` (reference executable, not built here), `constraint_framework`, `verifier_core`, `verifier_utils` |
| License | Apache-2.0 (`LICENSE` copied from the monorepo root; the upstream sources carry no per-file headers) |
| Upstream toolchain | Scarb 2.18.0 (`.tool-versions` of the upstream workspace) |

## How it is built here

The upstream workspace compiles with `enable-gas = false` and (for proving) `qm31_opcode`.
The `cairo/doom_contracts` workspace pulls these crates by path and compiles them under **its**
`[cairo]` table: **gas enabled, no `qm31_opcode` feature** (the qm31 libfuncs are not in
`audited.json`, so contracts must use the naive `M31`/`CM31`/`QM31` arithmetic), no
`poseidon252_verifier` (the circuit verifier is blake2s-only). The `circuit_verifier` crate is
kept for reference only (it is an executable target and needs `cairo_execute`).

## Local modifications (`hellproof-visibility.patch`)

Visibility-only changes so that `crates/stwo_circuit_phases` can split `verify_circuit` into
phases without forking its logic (every change adds a `pub`; no expression is touched):

| File | Change |
|---|---|
| `verifier_core/src/lib.cairo` | `mod queries` → `pub mod queries` (checkpointed query positions rebuild a `Queries`) |
| `verifier_core/src/pcs.cairo` | `mod quotients` → `pub mod quotients` (`fri_answers` runs in its own phase) |
| `verifier_core/src/pcs/verifier.cairo` | `mix_sampled_values` → `pub` |
| `verifier_core/src/verifier.cairo` | `try_extract_composition_eval` → `pub` |
| `verifier_core/src/channel/blake2s.cairo` | `Blake2sChannel.digest` → `pub` (mid-transcript checkpoints) |
| `verifier_core/src/fri.cairo` | `FriVerifier`, `FriFirstLayerVerifier`, `FriInnerLayerVerifier`, `SparseEvaluation` fields and impls → `pub` (layer-chunked FRI decommit) |
| `circuit_air/src/lib.cairo` | `SECURITY_BITS`, `verify_claim` → `pub` |

Regenerate the patch after a bump: copy the pristine upstream `crates/` next to this one and run
`diff -ru <pristine>/crates crates > hellproof-visibility.patch`. Re-apply with
`patch -p1 < hellproof-visibility.patch` from this directory (paths are `crates/...`).
`crates/stwo_circuit_phases/tests/test_monolithic.cairo` and `test_phases.cairo` are the
conformance check after any bump (R3-A5): the phased verifier must accept the S4 fixture and
produce the same `output_hash` as the monolithic one.

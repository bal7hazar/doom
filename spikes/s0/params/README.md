# Prover parameters of reference — S0

All files are `stwo_cairo_common::prover_params::ProverParameters` (see
`crates/common/src/prover_params.rs` in `starkware-libs/proving`), passed with
`--prover_params_json` (`stwo-run-and-prove`) or `--params_json` (`run_and_prove`,
`prove`).

| file | preprocessed trace | channel | pow | blowup | queries | store poly | include all pp cols | lifting |
|---|---|---|---|---|---|---|---|---|
| `canonical_small.json` | `canonical_small` | `blake2s` | 26 | 1 | 70 | false | **false** | `auto` |
| `canonical_small_m31.json` | `canonical_small` | `blake2s_m31` | 26 | 1 | 70 | false | **false** | `auto` |
| `canonical.json` | `canonical` | `blake2s` | 26 | 1 | 70 | false | false | `auto` |
| `recursion_tree_reference.json` | `canonical_small` | `blake2s` | **16** | 1 | 70 | false | **true** | `at_least_preprocessed` |
| `levers/lv_*.json` | `canonical_small` | `blake2s` | 26 | 1 | 70 | — one knob varied per file (R1-A5) — |

## `canonical_small.json` — the reference for Hellproof (R1-A1)

* `preprocessed_trace = canonical_small`: 10 161 776 preprocessed cells against
  543 100 528 for `canonical` (53x), which is what brings the fixed memory cost from
  ~17 GB down to ~2.3 GB. Its ceiling is `max_log_trace_size = 20`, i.e. **2^20 steps
  including the bootloader** — the hard bound on a Hellproof segment.
* `include_all_preprocessed_columns = false`: only the preprocessed columns a component
  actually uses are sampled into the proof. Cheaper proof, and no effect on soundness.
  The recursion route sets this to `true` because the leaf circuit's verifier is
  compiled against a fixed column set — S4 must re-check this against its own registry.
* `pow_bits = 26`, `log_blowup_factor = 1`, `n_queries = 70`: the monorepo's production
  defaults, `security_bits = pow_bits + log_blowup_factor * n_queries` = 96 bits.
* `channel_hash = blake2s`: the fast default. **`blake2s_m31` also works** on this
  commit (`canonical_small_m31.json`, measured in `docs/spikes/S0.md`) and is what the
  privacy/leaf route uses (`crates/privacy_prove/src/consts.rs`:
  `ChannelHash::Blake2sM31`). Verify a `blake2s_m31` proof with
  `verify.sh <proof> blake2s_m31`; verifying it as `blake2s` fails.
* `lifting_size_policy = auto`: the right choice for a proof consumed by the Rust or
  Cairo *CPU-AIR* verifier. The circuit routes need the other two variants —
  `fixed(n)` for the 2-to-1 circuit verifier and `at_least_preprocessed` for the
  circuit-cairo verifier (see the doc comment on `LiftingSizePolicy`).

## What the recursion route actually pins

`recursion_tree_reference.json` is a byte copy of
`crates/stwo_run_and_prove_recursive_tree/test_data/cairo_prover_params.json`, the file
that `circuit_registry_definitions/canonical_small/definition.json` references. It is
kept here so S4 can diff against our own params. Two differences matter:

* `pow_bits = 16` instead of 26 — the leaf *circuit* re-derives security, so the inner
  Cairo proof is deliberately cheap to grind. Our 26 is the standalone-security choice;
  S4 must decide which applies to a segment that is always wrapped.
* `include_all_preprocessed_columns = true` and
  `lifting_size_policy = at_least_preprocessed`, both forced by the circuit verifier.

The *privacy* (leaf) route in `crates/privacy_prove/src/consts.rs` differs again —
`Blake2sM31`, `pow_bits 27`, `log_blowup_factor 3`, `n_queries 23`, `fold_step 4`,
`lifting_size_policy = Fixed(...)` — so "the params of the recursion route" is not one
answer. S0 fixes the *standalone segment* params; S4 fixes the wrapped ones.

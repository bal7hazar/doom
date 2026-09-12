# Circuit registry definitions (S4 + S4b)

One directory per registry definition, each generated with
`spikes/s4/scripts/gen_registry.sh <name>` (add `--report-only` for the cheap size report,
`--registry-only` to skip it). The definitions' paths are relative to the monorepo root, as
upstream's are; the script copies them into `$PROVING/circuit_registry_definitions/<name>/`.

`registry.json` is what `leaf-prover` and `stwo_run_and_prove_recursive_tree` consume; `report.txt`
is the per-component size report; `*.time` are `/usr/bin/time -l` traces of the generation.

| Definition | What it changes vs `doom` | Multiverifier hash | Verdict |
|---|---|---|---|
| `doom` | — (the S4 baseline: log 20, `canonical_small`, Blake2sM31, pow 26, padded to the production shape) | = production | **retained** |
| `doom_min` | no `pad_to`: minimal padding | different | leaf/tree prove, on-chain verifier rejects the root (hard-coded `COMPONENT_LOG_SIZES`); only 2 % of RSS saved |
| `doom_19_20` | trace range 19–20 | — | impossible: `canonical_small`'s sequence columns are at log 20 |
| `doom_fold4` | Cairo proof FRI `fold_step = 4` | = production | **accepted end to end**, but no RSS/time gain under production padding |
| `doom_fold4_min` | `fold_step = 4` **and** minimal padding | different | −33 % RSS, −41 % time per circuit proof; needs regenerated on-chain constants |
| `doom_noprep` | `include_all_preprocessed_columns = false` | = production | `circuit-params` accepts it and emits `doom`'s leaf hash, `leaf-prover` refuses it (`prove_leaf.rs:70`) |
| `doom_21`, `doom_22` | `min = max = 21` / `22` | = production | generated, but unreachable: no `canonical_small` proof can have `trace_log_size > 20` (`seq_21` missing) |
| `doom_21_canonical` | `preprocessed_trace = canonical`, log 21 | — | the leaf circuit does not build below log 23 (`canonical_sweep.sh`) |

Numbers and the reasoning behind each verdict: [`docs/spikes/S4b.md`](../../../docs/spikes/S4b.md).

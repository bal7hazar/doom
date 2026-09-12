# Rejected variants (S4b)

Exact stderr / verifier output of the runs the recursion route refuses, kept as evidence for
`docs/spikes/S4b.md`.

| File | Command | Verdict |
|---|---|---|
| `noprep.stderr.txt` | `run_pipeline.sh 1 doom_noprep` | `include_all_preprocessed_columns = false` is rejected by `leaf-prover` before the run starts (`prove_leaf.rs:70`), in 0.02 s. Note that `circuit-params` accepts the same definition and emits a registry whose leaf circuit hash is byte-identical to `doom`'s: the flag never reaches the circuit, so a wrong registry is only caught at proving time. |
| `minimal_padding_verifier.txt` | `run_pipeline.sh 2 doom_fold4_min` (same for `doom_min`) | Leaf and tree prove fine, but the **on-chain** `stwo_circuit_verifier` rejects the root: `COMPONENT_LOG_SIZES` is compiled into `circuit_air/src/multiverifier_consts.cairo`, so a registry that is not padded to the production shape needs `FIX=1 cargo test -p circuit-params --test cairo_consts_test` and a redeploy. |
| `seq21.txt` | `trace_log_probe.sh 92000` | A Cairo run whose largest AIR component crosses 2^20 needs `trace_log_size = 21`, which `canonical_small` cannot commit: it has no `seq_21` preprocessed column. The `doom_21` / `doom_22` registries are therefore unreachable with `canonical_small`. |

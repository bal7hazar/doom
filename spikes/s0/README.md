# S0 — reference proving pipeline

Findings and measurement tables: **[`docs/spikes/S0.md`](../../docs/spikes/S0.md)**.
This directory holds the code that produced them.

```
programs/   seven standalone Scarb #[executable] packages (see docs/spikes/S0.md §3.4)
params/     prover parameters — canonical_small.json is the reference (params/README.md)
args/       argument files: JSON arrays of hex felts, the format both `scarb execute
            --arguments-file` and the bootloader's `user_args_file` expect
scripts/    build.sh, prove.sh, verify.sh, resources.sh, bootloader_overhead.sh,
            measure.sh + the summarise.py / tables.py post-processing
results/    one directory per run: /usr/bin/time -l output, execution resources,
            prover-log tail, summary.json. No proofs (4-12 MB each).
```

Quick start (see `scripts/env.sh` for the paths and pinned versions):

```bash
export PROVING_DIR=~/git/proving      # clone of starkware-libs/proving @ cd7bc5f
./scripts/build.sh --prover           # Cairo programs + the Rust binaries
./scripts/prove.sh programs/steps_k/target/dev/steps_k.executable.json \
                   args/k19.json /tmp/out
```

`prove.sh` takes the shared `$SCRATCH/.proof-lock` for any trace above 2^19 steps, so it
is safe to run while another spike is proving on the same machine.

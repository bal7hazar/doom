# segment/bench — step-budget harness and the consumer-side model

Not part of the `cairo/` workspace: `Scarb.toml` here declares a standalone
throwaway executable package (`segment_bench`) that depends on the crate
above it.

| File | Role |
|---|---|
| `src/lib.cairo` | `main(op, n)`: one loop per measured operation |
| `budget.json` | the operations to measure and their step budgets |
| `measure.py` | the step-budget driver; exits non-zero over budget |
| `coverage.py` | line-coverage report; exits non-zero below 90 % |
| `reference.py` | the output layout and the run-level checks, in Python |

## Method

Differential step counting with `scarb execute --print-resource-usage`, as
in spike S1 (`spikes/s1/tools/measure.py`). Here `n` is the **number of
tics in the segment**, so the differential is the cost *per tic*.

Building the command span also scales with `n` and therefore does **not**
cancel against the bare loop, so op 1 builds the span and does nothing
else, and every other op is netted against it (`base_op` in
`budget.json`). The engine under measurement is deliberately trivial — one
felt addition per tic — so what remains is the runner's own overhead.

The decomposition ops are the point of the harness: op 5 is the span read
plus the engine dispatch, op 3 adds the terminal-status test, op 4 is the
input-log commitment on its own, and op 2 is the whole of `run_segment`.
Together they say exactly where the per-tic cost goes; see the crate
README.

## reference.py

Not a benchmark: the **consumer-side model**. It reads the ten public
felts, checks the rules `DoomRuns` will enforce over a whole run (genesis
hash, `h_out[i] == h_in[i+1]`, `tic_end[i] == tic_start[i+1]`, `EXIT` last)
and recomputes a segment's `inputs_commitment` from the packed log
published as an event, using `poseidon_py`. The nine-tic commitment it
prints is pinned in the crate's `test_inputs_commitment_reference_vector`,
so the Cairo and Python sides are checked against each other.

## Running

```sh
export ASDF_SCARB_VERSION=2.16.0
python3 cairo/crates/segment/bench/measure.py     # exit code is the verdict
python3 cairo/crates/segment/bench/coverage.py    # line coverage
python3 cairo/crates/segment/bench/reference.py   # layout + run-level checks
```

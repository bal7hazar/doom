# prng/bench — step-budget harness and reference vectors

Not part of the `cairo/` workspace: `Scarb.toml` here declares a standalone
throwaway executable package (`prng_bench`) that depends on the crate above
it. It is never built by `scarb build` at the workspace root.

## Files

| File | Role |
|---|---|
| `src/lib.cairo` | `main(op, n)`: one loop per measured operation |
| `budget.json` | the operations to measure and their step budgets |
| `measure.py` | the step-budget driver; exits non-zero over budget |
| `coverage.py` | line-coverage report; exits non-zero below 90 % |
| `reference.py` | independent Python model, source of the test vectors |

## Method

`scarb execute --print-resource-usage` reports the exact Cairo VM step count
of a run. A single run also contains fixed costs (bootstrap, table
construction, argument and return serialization), so the cost of one
operation is obtained *differentially*, exactly as in spike S1
(`spikes/s1/tools/measure.py`):

```
cost_per_iteration(op) = (steps(op, 2N) - steps(op, N)) / N
net(op)                = cost_per_iteration(op) - cost_per_iteration(0)
```

`op = 0` is the bare loop (counter + accumulator, 9 steps). Every fixed cost
cancels in the difference, and the step counter is exact — two runs of the
same binary always report the same number — so this is a deterministic CI
test, not a timing benchmark. Each operation has its own loop function so
that the `op` dispatch is never paid inside a measured body (measuring it
inside a shared loop inflated the baseline from 9 to 19 steps and made the
baseline depend on the op index).

Budgets in `budget.json` are the measured value rounded up by ~10 %, the
regression margin PLAN.md §3.1 rule 4 asks for.

## Running

```sh
export ASDF_SCARB_VERSION=2.16.0
python3 cairo/crates/prng/bench/measure.py          # exit code is the verdict
python3 cairo/crates/prng/bench/coverage.py    # line coverage
python3 cairo/crates/prng/bench/reference.py        # reference vectors
```

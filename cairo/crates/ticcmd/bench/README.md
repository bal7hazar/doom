# ticcmd/bench — step-budget harness and reference vectors

Not part of the `cairo/` workspace: `Scarb.toml` here declares a standalone
throwaway executable package (`ticcmd_bench`) that depends on the crate
above it.

| File | Role |
|---|---|
| `src/lib.cairo` | `main(op, n)`: one loop per measured operation |
| `budget.json` | the operations to measure and their step budgets |
| `measure.py` | the driver; exits non-zero when a budget is exceeded |
| `reference.py` | independent Python model of both wire formats |

## Method

Differential step counting with `scarb execute --print-resource-usage`, as
in spike S1 (`spikes/s1/tools/measure.py`):

```
cost_per_iteration(op) = (steps(op, 2N) - steps(op, N)) / N
net(op)                = cost_per_iteration(op) - cost_per_iteration(0)
```

Fixed costs (bootstrap, pool construction, serialization) cancel, and the
step counter is exact, so this is a deterministic CI test rather than a
timing benchmark.

Two traps this harness works around, both found by measuring:

1. **Loop-invariant hoisting.** `decode(word)` on a constant word measured
   *2 steps* — the compiler had lifted it out of the loop. Every loop here
   reads its input from an eight-entry pool through a cycling cursor, and
   the bare loop (op 0, 25.87 steps) does the same read, so the pool access
   cancels in the difference.
2. **Dispatch inside the measured body.** Selecting the operation with an
   `if` chain *inside* the loop makes the baseline depend on the op index
   (it inflated the bare loop from 9 to 19 steps). Each operation has its
   own loop function instead.

Budgets in `budget.json` are the measured value plus ~10 %, the regression
margin PLAN.md §3.1 rule 4 asks for.

## Running

```sh
export ASDF_SCARB_VERSION=2.16.0
python3 cairo/crates/ticcmd/bench/measure.py     # exit code is the verdict
python3 cairo/crates/ticcmd/bench/reference.py   # vectors + exhaustive checks
```

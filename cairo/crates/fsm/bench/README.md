# fsm/bench — step-budget harness and reference traces

Not part of the `cairo/` workspace: `Scarb.toml` here declares a standalone
throwaway executable package (`fsm_bench`) that depends on the crate above
it.

| File | Role |
|---|---|
| `src/lib.cairo` | `main(op, n)`: one loop per measured operation |
| `budget.json` | the operations to measure and their step budgets |
| `measure.py` | the driver; exits non-zero when a budget is exceeded |
| `reference.py` | independent Python model, written from Doom's own rule |

## Method

Differential step counting with `scarb execute --print-resource-usage`, as
in spike S1 (`spikes/s1/tools/measure.py`):

```
cost_per_iteration(op) = (steps(op, 2N) - steps(op, N)) / N
net(op)                = cost_per_iteration(op) - cost_per_iteration(base)
```

`base` is op 0 (the bare loop, 11 steps) unless the entry names another one
with `"base_op"`: `enter` and `row` are driven by a 4-state cursor that the
bare loop does not have, so they are measured against op 9, the cursor loop
on its own (6.75 steps).

Each operation has its own loop function — dispatching on `op` *inside* the
loop makes the baseline depend on the op index — and every loop threads the
machine's own state through its iterations, so nothing is loop-invariant
and nothing can be hoisted out.

Three ops are diagnostics rather than API calls, and they are what located
the crate's two big costs:

- **op 7**, a call with `advance`'s exact signature whose body ignores
  `tables`: 11 steps. The compiler drops the unused parameter, so this is
  *not* the cost of passing the table — it is the floor for a call.
- **op 8**, `advance`'s counting-down branch written out inline: 19 steps.
  Since the real `advance` measured 62, the call plumbing (five `Span`s in,
  three `u32`s out) was costing 43 steps — hence `#[inline(always)]`.
- **op 9**, the cursor-step baseline described above.

Two earlier versions are recorded in the crate README because the numbers
are the argument: `len()` scanning all five columns cost 40 steps per call
(it is one column now), and three equality tests in `advance` cost more
than the single ordered comparison that replaced them.

Budgets in `budget.json` are the measured value plus ~10 %, the regression
margin PLAN.md §3.1 rule 4 asks for.

## Running

```sh
export ASDF_SCARB_VERSION=2.16.0
python3 cairo/crates/fsm/bench/measure.py     # exit code is the verdict
python3 cairo/crates/fsm/bench/reference.py   # Doom-semantics cross-check
```

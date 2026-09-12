# state_hash/bench — step-budget harness and reference vectors

Not part of the `cairo/` workspace: `Scarb.toml` here declares a standalone
throwaway executable package (`state_hash_bench`) that depends on the crate
above it.

| File | Role |
|---|---|
| `src/lib.cairo` | `main(op, n)`: one loop per measured operation |
| `budget.json` | the operations to measure and their step budgets |
| `measure.py` | the driver; exits non-zero when a budget is exceeded |
| `reference.py` | the scheme reimplemented on `poseidon_py` |

## Method

Differential step counting with `scarb execute --print-resource-usage`, as
in spike S1 (`spikes/s1/tools/measure.py`):

```
cost_per_iteration(op) = (steps(op, 2N) - steps(op, N)) / N
net(op)                = cost_per_iteration(op) - cost_per_iteration(0)
```

Here `n` is the **number of felts in the state**, not a repetition count,
so the differential is the cost *per felt hashed* — except for
`commit_input`, which folds one felt per iteration and is therefore a
per-call number.

Two diagnostic ops decompose the bill and are what the crate's design rests
on:

- **op 1**, building the array without hashing it: **4 steps/felt**.
- **op 5**, building it *and* hashing it with bare `poseidon_hash_span`:
  **14.5 steps/felt**, so Poseidon itself is 10.5 — exactly the figure S1
  §5.8 reported, reproduced here on a different program.

Against those, `open` + append + `seal` measures 14.5 steps/felt: the
domain separation costs nothing, because the three header felts are
amortised over the whole record. `hash_tagged` measures 35.5, the extra 21
being the copy of the caller's span in behind the header.

A streaming `Digest` over `core`'s Poseidon `HashState` was also written
and measured, on the S1 §5.8 suggestion that avoiding the array should
halve the bill: **18.5 steps/felt**, i.e. worse than open/seal despite
never allocating. `HashState::update` absorbs one felt at a time with a
parity branch, while `poseidon_hash_span` absorbs two per permutation. The
code was deleted rather than kept as a trap.

## Reference vectors

`reference.py` reimplements the scheme on `poseidon_py` — the reference
Poseidon used by starknet.py, which this repository did not write — and
prints the three vectors pinned in `src/lib.cairo`
(`REFERENCE_TAGGED`, `REFERENCE_INPUTS_SEED`, `REFERENCE_COMMIT_111`) plus
the reserved tag values. If `poseidon_py` is not installed:
`pip install poseidon-py`.

## Running

```sh
export ASDF_SCARB_VERSION=2.16.0
python3 cairo/crates/state_hash/bench/measure.py     # exit code is the verdict
python3 cairo/crates/state_hash/bench/reference.py   # vectors
```

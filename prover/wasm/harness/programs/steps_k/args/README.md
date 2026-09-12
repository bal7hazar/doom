# steps_k arguments

`scarb execute --print-resource-usage` (scarb 2.16.0) gives `steps = 11 * n + 38` for `main(n)`
(builtins: 2 range_check, 1 output). `k<K>.json` = `[n]` with `n = floor((2^K - 38) / 11) - 10`,
i.e. a trace just under 2^K steps so that the largest opcode component stays at log size K:

| file | n | steps (scarb) |
|---|---|---|
| k14.json | 1476 | 16 274 |
| k16.json | 5944 | 65 422 |
| k18.json | 23817 | 262 025 |
| k19.json | 47649 | 524 177 |
| k20.json | 95311 | 1 048 459 |

The step count reported by the proof-mode runner in the harness (`n_steps`) may differ by a few
steps from `scarb execute` (validation-mode run). k20 is for the native reference only (the spike
rule caps browser runs at 2^19).

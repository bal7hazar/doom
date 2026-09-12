# steps_k arguments

`scarb execute --print-resource-usage` (scarb 2.16.0) gives `steps = 11 * n + 38` for `main(n)`
(builtins: 2 range_check, 1 output). Under the leaf simple bootloader (the route the harness and
the recursion use) this executable costs a further **4 881 steps** (measured: 21 155 total for
16 274 program steps; S0's formula 2 340 + 14.7 × 170 bytecode words ≈ 4 839).

`k<K>.json` = `[n]` with `n = floor((2^K - 38 - 4881) / 11) - 10`, i.e. a **total** trace just
under 2^K steps:

| file | n | program steps | total steps (with bootloader) |
|---|---|---|---|
| k14.json | 1032 | 11 390 | 16 271 |
| k16.json | 5500 | 60 538 | 65 419 |
| k18.json | 23374 | 257 152 | 262 033 |
| k19.json | 47205 | 519 293 | 524 174 |
| k20.json | 94867 | 1 043 575 | 1 048 456 |

`n_steps` reported by the harness is the total. 2^20 (bootloader included) is the ceiling of the
`canonical_small` preprocessed trace; k20 runs take the shared proof lock (ROADMAP §4).

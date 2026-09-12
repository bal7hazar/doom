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

`m<N>.json` = the same thing for round **millions** of total steps, used to size the game's
segments (S4b: a segment is not capped at 2^20 *steps*, only at 2^20 rows for the largest AIR
component — see `prover/wasm/README.md` §Segment sizing):

| file | n | program steps | total steps (with bootloader) |
|---|---|---|---|
| m2.json | 181 371 | 1 995 119 | 2 000 000 |
| m3.json | 272 280 | 2 995 118 | 2 999 999 |
| m4.json | 363 189 | 3 995 117 | 3 999 998 |

`n_steps` reported by the harness is the total. Runs above 2^19 total steps take the shared proof
lock (ROADMAP §4).

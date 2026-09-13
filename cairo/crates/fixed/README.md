# fixed

**Does**: 16.16 fixed-point arithmetic, felt-first. `Fixed` is a single
**non-negative** `felt252` in offset encoding (`enc = raw + 2^32`), with
`add`/`sub`/`neg`/`abs`/`magnitude`/`split`/`mul`/`div`, the comparison family
(`ge`/`gt`/`le`/`lt`/`min`/`max`/`is_neg`), the signed shift `shr8`,
operator sugar for all of them,
boundary conversions to and from raw `fixed_t` values and integer map units
(`from_raw`/`to_raw`/`from_units`/`to_units`/`from_int`), and the one
comparison primitive the whole geometry stack is built on, `felt_ge`.
`mul` reproduces Doom's `FixedMul` (arithmetic shift, rounds toward minus
infinity) and `div` reproduces `FixedDiv` including its overflow guard
(`|a| >> 14 >= |b|` saturates to `MAXINT`/`MININT`), so a division by zero
saturates instead of panicking.

**Does not**: know about angles or trigonometry (`bam`), geometry (`geom2d`)
or anything Doom-specific; it has no dependency at all, not even on another
crate of this workspace. It provides no `sqrt` and no rounding modes other
than Doom's.

**Invariants**:

* `enc` is always `raw + BIAS` with `BIAS = 2^32`, so a well-formed value
  satisfies `0 < enc < 2^33` and **every value written to memory stays below
  2^72** — the threshold above which S0 measured +33 % on the
  `range_check_9_9` component. A unit test checks the extremes and the Serde
  round trip.
* Domain: `raw` in `(-2^32, 2^32)`, i.e. twice Doom's `int32` `fixed_t`
  range, which leaves one bit of headroom for intermediate sums. `add`/`sub`
  do not check it (1 step each); `mul` is only defined when the exact product
  stays in the domain, and the reference vectors that would leave it are
  tested through `div` only.
* `felt_ge(a, b)` is exact for `a, b` in `[0, 2^71)` and panics (rather than
  answering wrongly) outside it. `felt_ge_narrow(a, b)` is exact for
  `|a - b| < 2^64` and **never panics** (one `u64` conversion is the whole
  test); `to_u128` is the panic-free `felt252 -> u128` (an out-of-domain
  value reads as 0). The `Fixed` comparisons, `split`/`abs`/`magnitude`,
  `shr8`, `to_units`, `mul` and `div` are built on them, so none of them has
  a panic path any more: a panic site costs the *enclosing* function its
  whole return width in bytecode at every inlined use, and a function
  without any is compiled without the `PanicResult` wrapper (S7 §2). The
  price is a merge instead of a diverging arm: **+3 steps** on `mul`,
  `to_units`, `shr8` and on a comparison of two variables, −3 on a
  comparison against a constant (`is_neg`, `magnitude`, `split`, `abs`); in
  situ (docs/spikes/S7.md, A/B on `P_TryMove`) the narrow comparison is
  the cheaper one in steps as well, because its `bool` merges into a
  branch rather than into a value.
* No `/` on `felt252` anywhere: that operator is a *field* division and is
  silently wrong. Cairo 2.16 has no `Div<felt252>` impl at all, so the rule is
  enforced by the compiler; every shift or division goes through `u128`.

## Measured step costs

Measured with `bench/measure.py` (differential method of S1 §3.1: a
representative operation is run `n` and `2n` times and the difference is
divided by `n`, which cancels bootstrap and serialization). Numbers are
**net of the baseline op that builds the same operands** (op 0 is the bare
loop at 8 steps/iteration), on Scarb 2.16.0, `enable-gas = false`. `bench/budgets.json` holds the same numbers as budgets; the script
exits non-zero if any operation regresses by more than 10 %, which is this
crate's step-budget test (PLAN §3.1 rule 4):

```sh
cd bench && python3 measure.py          # measure + check budgets
python3 measure.py --update             # re-baseline after an intentional change
```

| Operation | steps (net) | range checks | note |
|---|---:|---:|---|
| `felt_ge` | 11 | 2 | the floor for a signed comparison; S1 §5.1 quotes 17 for a variable-bias form |
| `felt_ge_narrow` | 14 | 3 | panic-free, `|a - b| < 2^64`; 38 words per inlined site against 57 (S7) |
| `add` / `sub` | 1 | 0 | pure field arithmetic |
| `neg` | 2 | 0 | |
| `from_units` | 3 | 0 | |
| `ge` / `gt` / `le` / `lt` | 14 | 3 | one `felt_ge_narrow` (11 with `felt_ge` before S7) |
| `min` + `max` (both) | 29 | 6 | 15 each |
| `abs` | 11 | 2 | |
| `magnitude` / `is_neg` | 12 | 2 | a comparison against the constant bias: cheaper on the narrow form |
| `to_units` | 18 | 5 | one `u128` division (floor); +3 for the panic-free conversion |
| `shr8` | 19 | 5 | C's `>> 8` on a signed value (Doom pre-shifts in `P_InterceptVector`) |
| `split` (sign + magnitude) | 13 | 2 | one sign test instead of two |
| `mul` | 21 | 5 | S1 §5.1's 18 for bare magnitudes plus the panic-free conversion's merge |
| `div` | 78 | 13 | S1 quotes 55 for bare magnitudes; +22 for the two sign tests and Doom's overflow guard |
| `add(x, mul(v, c))` (momentum step) | 25 | 5 | representative composite |

Bytecode: **2 826 words** for the benchmark executable, crate included
(S1 §5.9: the bootloader re-hashes the program every segment at
`2340 + 14.7 x words`, so program size is a budget too; `measure.py` prints
and checks it).

Two measured findings worth carrying to the consumers:

* **`div` is 5x a `mul` and 7x a comparison.** Use it only where Doom does
  (intercept fractions, slide slopes). To *order* two fractions, compare
  cross products instead (S1 §7).
* **Keeping the overflow guard in the field is worth 9 to 24 steps.**
  Measured three ways (same bench, same baseline): Doom's
  `(|a| >> 14) >= |b|` written as a `u128` division makes `div` cost **86**
  steps, as a checked `u128` multiplication **101**, and as
  `felt_ge(|a|, |b| * 16384)` **77**. In Cairo a `u128` multiplication is
  *not* a cheap instruction — only `felt252` multiplication is (2 steps).
* **Benchmark operands must vary with the loop counter.** With
  loop-invariant operands Cairo hoists the call out of the loop and the
  measurement reads 1 step for anything; each operation here is measured
  against the baseline op that builds the same operands (`base` in
  `budgets.json`).

## Tests

`scarb test -p fixed` — 28 unit tests (`src/tests.cairo`) plus 2 integration
tests (`tests/lib.cairo`):

* **reference values**: 157 `mul` and 160 `div` vectors generated by
  `scripts/gen_vectors.py` from Python arbitrary-precision integers with
  Doom's exact `FixedMul`/`FixedDiv` semantics (regenerate with
  `python3 scripts/gen_vectors.py --write`; the generated file is committed);
* **properties** with deterministic generators: commutativity and
  associativity of `add`, `sub` inverts `add`, `mul` commutes, order is
  translation-invariant and reversed by negation, raw round trips;
* **edge cases**: zero, `±1` ulp, `MAXINT`/`MININT`, division by zero and the
  overflow guard, floor vs truncation on negative operands, `felt_ge` outside
  its domain (must panic), `to_units` and `shr8` flooring on negatives;
* **provability**: every encoded value and every reference vector is asserted
  non-negative and below 2^33.

Note for anyone adding tests here: the **integration** target
(`tests/lib.cairo`) must stay loop-free. `scarb test` computes gas for it even
though the workspace sets `enable-gas = false`, and Cairo lowers `while` into
recursive functions, which makes that computation fail with "found an
unexpected cycle during cost computation" (the same Scarb 2.16 quirk S1 §2
hit with `cairo-profiler` 0.9). Everything that iterates belongs in the
unit-test target.

## Coverage

`python3 bench/coverage.py` measures line coverage with `cairo-coverage`
0.5.0. The script copies the crate and its siblings to a temporary
directory and patches the manifests there (`snforge_std` instead of
`cairo_test`, gas back on, the three debug-info/inlining flags coverage
requires), because `cairo-coverage` only reads `snforge` traces and
`snforge` cannot compile this workspace as it stands -- `cairo/Scarb.toml`
sets `enable-gas = false` for `doom_run`'s executable target. Lines at or
below a file's `#[cfg(test)]` marker are excluded, so the figure is the
coverage of the code that ships. `cairo-coverage` 0.5.0 emits no `BRF`/`BRH`
records, so **branch** coverage cannot be reported by the tool; line
coverage is the proxy, and since `scarb fmt` puts every branch arm on its
own line a missed arm shows up as a missed line. The script exits non-zero
below 90 % (C7).

Measured: **28 tests, 350/354 production lines = 98.9 %**. The four
misses are inside `div`'s saturation branch, which the tests do reach
(`test_div_overflow_guard_matches_doom`); with `inlining-strategy = "avoid"`
the tool attributes those instructions to the caller.

Coverage is argued on top of the figure: every public function is called by
at least one test, and every `if` branch in `div`, `abs`, `magnitude`,
`split`, `min`/`max` is reached by an explicit edge case (positive, negative,
zero, and both saturation signs).


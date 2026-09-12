# fixed

**Does**: implements 16.16 fixed-point arithmetic (`Fixed`, backed by a signed
`i64` raw value: 16 integer bits, 16 fractional bits, matching Doom's
`fixed_t`) with `add`, `sub`, `mul`, `div`, `abs`, `neg`, `from_int`/`to_int`
and comparison, felt-first at the boundaries (conversion to/from `felt252`
is checked and never produces a value that would not round-trip).

**Does not**: know about angles, geometry, or any Doom-specific concept; it
never depends on any other crate in this workspace. It does not implement a
full transcendental library (`sqrt`, trig) — that belongs to `bam`.

**Invariants**: `mul`/`div` round toward zero exactly like Doom's
`FixedMul`/`FixedDiv` (64-bit intermediate product, no silent overflow —
`div` by zero panics rather than returning a poisoned value); `to_int`
truncates toward zero; `from_int(n).to_int() == n` for every representable
`n`; `abs(x) >= 0` for every `x` except `i64::MIN`, which is out of the
representable range of a Doom-scale coordinate and is therefore excluded by
convention (documented, not enforced by an assertion, to keep the crate
panic-free on the happy path).

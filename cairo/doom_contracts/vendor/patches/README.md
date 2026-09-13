# Hellproof patch series over `stwo_cairo_verifier@cd7bc5f`

`vendor/stwo_cairo_verifier/crates` = upstream `proving@cd7bc5f` + this series, applied in order
(`apply.sh`). `vendor/stwo_cairo_verifier_ref/crates` = upstream + patch 0001 only, under
renamed package names (`*_ref`, `tools/vendor_ref.sh`): the **unmodified reference** the
optimized code is compared against
(`crates/stwo_circuit_phases/tests/test_equivalence.cairo`: same `fri_answers` row by row,
same accepted proofs with the same output hash, same rejections of tampered proofs, on the real
root proofs).

Rule of the series (P4.1, `docs/design/onchain-verifier.md` §8): every patch is a refactor of
arithmetic or data movement — **what is verified does not change**: same transcript, same
Merkle checks, same quotients, same folds, same final equalities. The invariant each patch
preserves and why the new code is equivalent are stated below; the patch headers repeat them.

Why they exist: Starknet bills these classes by their **range-check builtin count** (1 600 gas
each; the fee is the maximum over VM resources and range checks dominate steps 2:1 in the
vendored verifier), so the levers are "fewer reduced field operations" (a reduced M31 product
costs 3 range checks, an inversion 136, the packed `fri_fold` 28) rather than fewer steps.

| # | file | title | gas effect (S4 fixture, snforge cairo-steps) |
|---|---|---|---|
| 0001 | `hellproof-visibility.patch` (in `..`) | visibility-only changes so the phases can call into the verifier | none |
| 0002 | `0002-fri-lazy-folds.patch` | FRI folds on unreduced limbs, one batch inversion per layer, hoisted per-layer constants, table bit reversal, arithmetic Merkle positions | FRI walk 1 884 M → 487 M (−74 %) |
| 0003 | `0003-fri-answers-lazy.patch` | `fri_answers`: lazy numerators per sample point, one batch inversion of all denominators, one reduction per row | `answers` 676 M → 383 M (−43 %, now steps-bound) |

## 0002 — FRI folds (`verifier_core/src/{fri.cairo, fri/lazy.cairo, utils.cairo}`)

Invariant: for every query subset of every layer, the folded value is the tree of
`fri_fold(v0, v1, 1/x, alpha^(2^l))` over the subset's evaluations that `fold_coset` /
`fold_circle` computed, with the same twiddles in the same order; the Merkle decommitment is
checked at the same positions against the same leaf values.

1. `bit_reverse_index(index, n)`: the 32-bit reversal assembled from four byte reversals and
   shifted right by `32 - n` keeps exactly the reversed low `n` bits of `index` — the value the
   bit-by-bit loop returned — for every `u32` input (the high bits of `index` land in the shifted-
   out low bits). ~19 range checks instead of ~6 per bit.
2. Twiddles. The fold domain of a subset is `p0 + <G>` (`G` the generator of order `2^fold_step`,
   or of the half coset for the circle layer). Instead of `to_point` per point, `p0 = to_point(
   initial index)` once and `x(p0 + kG) = x0·X_k − y0·Y_k`, `y(p0 + kG) = x0·Y_k + y0·X_k` with the
   per-layer constants `(X_k, Y_k) = kG`: `to_point` is a group homomorphism from indices to points
   (`to_point(a + b) = to_point(a) + to_point(b)`), so these are the same field elements; each is
   one `felt252` expression offset by `P^2` and reduced once. The doubled twiddles are `2x^2 − 1`
   (`double_x`) computed the same way. The order (`bit_reverse_index(j, fold_step)`, `j` even, then
   every other one doubled, level by level) is the one `fold_coset` consumed.
3. Inverses: all the layer's twiddles are inverted with one Montgomery batch inversion
   (`fields::BatchInvertible`, the vendored routine already used by the quotients) instead of one
   exponentiation each: the same inverses (a zero twiddle makes both versions panic).
4. Folds (`fri/lazy.cairo`): every node computes `(v0 + v1) + alpha · itwid · (v0 − v1)` — the
   ibutterfly and linear combination of `poly::utils::fri_fold` — with `felt252` arithmetic on
   unreduced limbs. Each limb stays a non-negative integer congruent to the vendored coordinate
   modulo P: subtractions are offset by a multiple of P (`OFF_SUB_r`), the product by alpha
   (expanded exactly as `qm31::naive::unreduced::mul_qm_unreduced`, `u^2 = 2 + i`) by
   `OFF_MUL_r ≥` its negative part. One level multiplies the bound by at most `2^70`; three levels
   from reduced inputs end below `2^241 < PRIME`, so the integers are exact and a reduction
   (`u256` split, `2^128 ≡ 16 (mod P)`, or a single `u128` division for limbs below `2^128`)
   returns the vendored field element. The alpha powers `alpha, alpha^2, ...` are the
   per-level squarings the loop performed, computed once per layer.
5. `merkle_positions_of_subsets`: the flat decommitment positions are the runs
   `[f·2^fold_step, (f+1)·2^fold_step)` of the folded positions `f`; shifted by `leaf_log_size` and
   deduplicated they are exactly `f·(2^fold_step / leaf_size) + m`, in the same ascending order
   (identity when `leaf_size = 1`). The decommitment positions themselves are generated from a
   per-layer offset span (one range check each instead of two).

## 0003 — `fri_answers` (`verifier_core/src/pcs/quotients.cairo`)

Invariant: for every query row, `answer = −Σ_batches reduce(a_b·y + b_b − Σ_cols c_{b,col}·v_col)
· den_b^{-1}` with the batches, coefficients (`QuotientConstantsImpl::gen`) and denominators
(`fused_quotient_denominator`) of the original code.

1. `gen` stores its sums and coefficients reduced; the packed sums are offset by `large_zero()`
   before their single reduction (a packed lane of `mul_cm31` may be negative — the original
   absorbed it by adding the offset `alpha_mul_b_sum` before reducing).
2. Numerators are accumulated per **sample point** on four unreduced `felt252` limbs (one
   multiplication and one addition per limb and column, no lookup, no reduction), with one
   offset `P·2^41 ≥ Σ c·v` per class; batches of different degree-bound groups sampled at the
   same point (the OODS point, the previous point; and the periodicity batch of the largest
   columns, sampled at the OODS point itself) are summed before the multiplication by their
   common inverse denominator — a reassociation of a ring sum.
3. Denominators: the same formula; inverted through the norm (`(a + bi)^{-1} = (a − bi)/(a^2 +
   b^2)`, what the vendored `CM31` inverse computes) with one batch inversion of all the proof's
   norms.
4. The row is `Σ_classes class_sum · den^{-1}` on unreduced limbs (products below `2^135`,
   offset `P·2^105`, sum below `2^141`), reduced once (`u256` split) and negated.

## Regenerating / applying

```bash
tools/vendor_patches.sh <commit-before-p4.1>     # rewrites 0002..000N from git (paths a/crates/…)
cd vendor/stwo_cairo_verifier && sh ../patches/apply.sh   # pristine crates/ + 0001 → current tree
```

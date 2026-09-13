// SPDX-License-Identifier: GPL-2.0-only
//! The crate's panic-free scalar arithmetic and table reads (S7 §8 rule 1).
//!
//! In Cairo 2.16 **a panic site costs its enclosing function the whole width
//! of that function's return**: the `Err` variant of the `PanicResult` enum
//! is zero-padded up to the `Ok` variant and stored in full at every panic
//! site, and the quality "may panic" propagates to every caller, each of
//! which then carries a propagation path of *its* return width. On a
//! `Player` (36 felts) + `Mobj` (27) chain that is ~72 felts per site: one
//! `+= 1` on a counter is 72 words of zeroes.
//!
//! So no operator that can trap is used on the proving path: `+`/`-` on
//! `u32` become [`inc`]/[`dec`]/[`add32`]/[`sub32`], `*` becomes [`mul32`],
//! `/` and `%` go through a `NonZero` literal (the operator keeps a
//! "division by zero" arm the compiler does not fold away), a `Span` read
//! goes through [`rd32`] (`get` + `match`), and a comparison of two encoded
//! felts through `fixed::felt_ge_narrow`.
//!
//! Most of these are `doom_physics::maputl`'s, re-exported here so that a
//! reader of this crate finds them in one place; the two that are not are
//! below. Nothing here changes a result: every operation is exact on the
//! domain the caller already guarantees.

pub use doom_physics::maputl::{add32, dec, inc, low32, opaque_zero, rd32, sub32};

/// `a * b` on `u32` without the overflow panic.
///
/// The products this crate takes are damage rolls and clip counts, all far
/// below `2^32`; the multiplication is done in the field, where it cannot
/// overflow, and narrowed back.
#[inline(always)]
pub fn mul32(a: u32, b: u32) -> u32 {
    let p: felt252 = a.into() * b.into();
    low32(fixed::to_u128(p))
}

/// `a / d` on `u32` for a divisor the caller writes as a literal, without
/// the "division by zero" arm `/` keeps.
#[inline(always)]
pub fn div32(a: u32, d: NonZero<u32>) -> u32 {
    let (q, _) = DivRem::div_rem(a, d);
    q
}

/// Doom's `(m * leveltime) & 8191`, the fine-table index of a bob.
///
/// `m * tic` is computed in the field, so it is exact where C's `int`
/// multiply wraps at `2^32` — and `8192` divides `2^32`, so the remainder is
/// the same one. (The `u32` product would both trap and *change* the answer
/// past `leveltime = 10 501 000`.)
#[inline(always)]
pub fn fine_of(m: felt252, tic: u32) -> u32 {
    let n: NonZero<u128> = 8192;
    let (_, r) = DivRem::div_rem(fixed::to_u128(m * tic.into()), n);
    low32(r)
}

/// `idx % 4096` for an `idx` in `[0, 8192)`: `finesine`'s index of the
/// second quarter wave.
#[inline(always)]
pub fn half_fine(idx: u32) -> u32 {
    let n: NonZero<u32> = 4096;
    let (_, r) = DivRem::div_rem(idx, n);
    r
}
